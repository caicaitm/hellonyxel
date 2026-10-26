using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Globalization;
using System.Windows.Forms;   // Screen, SystemInformation, InputLanguage
using System.Drawing;        // Rectangle, Point
using Microsoft.Win32;       // Registry

// 收集设备系统信息：屏幕分辨率、桌面图标大小/位置、时间、时区、语言。
// 纯 Windows 官方 API（P/Invoke user32/kernel32/comctl32 + .NET Registry/CultureInfo/TimeZoneInfo）。
// 通过 Add-Type 运行时编译（public 以允许 PowerShell 调用），输出 JSON 到 %Documents%\HelloNyxel\Temp\sysinfo.json
public class SysInfo
{
    // ---------- P/Invoke ----------
    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);

    [DllImport("user32.dll")]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern int GetWindowLongW(IntPtr hWnd, int nIndex);   // GWL_EXSTYLE = -20

    // DWM 伪装（cloaked）窗口检测：UWP 挂起/后台窗口（如「Windows 输入体验」TextInputHost）
    // IsWindowVisible=true 但屏幕上并不渲染，若不给它建页面覆盖就会把低层积木永久洞穿。
    [DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("kernel32.dll")]
    static extern uint GetCurrentProcessId();

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    // 读取"桌面图标网格间距"（UI 设置项，DPI 无关的"单元格间距"，单位 px）
    const uint SPI_GETICONHORIZONTALSPACING = 0x0D;
    const uint SPI_GETICONVERTICALSPACING = 0x0E;
    [DllImport("user32.dll")]
    static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref uint pvParam, uint fWinIni);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("kernel32.dll")]
    static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [DllImport("kernel32.dll")]
    static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, uint dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32.dll")]
    static extern bool VirtualFreeEx(IntPtr hProcess, IntPtr lpAddress, uint dwSize, uint dwFreeType);

    [DllImport("kernel32.dll")]
    static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out uint lpNumberOfBytesWritten);

    [DllImport("kernel32.dll")]
    static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out uint lpNumberOfBytesRead);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr hObject);

    [DllImport("user32.dll")]
    static extern uint GetDpiForSystem();

    [DllImport("kernel32.dll")]
    static extern ushort GetUserDefaultUILanguage();

    [DllImport("kernel32.dll")]
    static extern ushort GetSystemDefaultUILanguage();

    [DllImport("comctl32.dll")]
    static extern bool ImageList_GetIconSize(IntPtr himl, out int cx, out int cy);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    // 写窗口样式 / 扩展样式。★ 64 位下必须用 xxxLongPtr：窗口样式是 LONG_PTR 宽度，
    // 用 32 位的 SetWindowLong 会截断/失败（本 EXE 是 AnyCPU，实际以 64 位运行）。
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);

    // 读窗口样式 / 扩展样式（LONG_PTR 宽度；GetWindowLong/GetWindowLongPtr 按位数分发）
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

    // 统一入口：按进程位数分派 32/64 位 API（避免在 64 位进程里误用 32 位版本）
    static IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong)
    {
        if (IntPtr.Size == 8)
        {
            return SetWindowLongPtr64(hWnd, nIndex, dwNewLong);
        }
        return (IntPtr)SetWindowLong32(hWnd, nIndex, dwNewLong.ToInt32());
    }

    // ---- 进程树枚举（自测量面板：「本进程树子进程数 + 内存合计」）----
    // ★ 为什么放进这个预编译 EXE：面板要 ~1s 刷一次；若走 PowerShell 则每次都要起宿主
    //   （~100 MB + conhost）并重新编译 C#。EXE 一次调用只是个进程启动（~10 ms），
    //   且是 GUI 子系统 → 连 conhost 都不新建。
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32W
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool Process32FirstW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool Process32NextW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);

    const uint TH32CS_SNAPPROCESS = 0x00000002;
    static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    // ---------- 单实例仲裁（命名互斥体 + 独占锁文件 + PID 存活校验）----------
    //
    // ★★ 关键约束（踩过一次才知道）：**命名 mutex 与文件句柄都是"进程级"内核对象**，
    //    创建它们的进程一退出，内核立刻回收。所以"让 SysInfo.exe 试着 CreateMutex 再退出"
    //    是**无效**的 —— 每次调用都是新进程，每次都会拿到"我是首个"（实测确认）。
    //    因此持锁者必须是**长生命周期**的进程。
    //
    // 形态：主进程启动早期 fork 出一个 `single-instance hold` 子进程持锁，
    // 它轮询 ownerPid 存活；主进程退出 → 它自动退出 → 内核回收锁。
    // 与托盘看门狗（GameAlive 轮询）同一套生命周期论证，不新增常驻进程种类。
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateMutex(IntPtr lpMutexAttributes, bool bInitialOwner, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint GetLastError();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    // CreateFile 失败返回 INVALID_HANDLE_VALUE（**不是** NULL）。只判 `== IntPtr.Zero`
    // 会把失败当成成功 → 以为拿到了锁 / 以为没被锁，两头都错。
    // ★ 这是踩过的第三个坑：只判 Zero 时，持锁者的独占句柄"失败"被当成"成功"，
    //   而探测方的 `== Zero` 判断把同一个失败当成"没被锁" → 第二个实例照样抢锁。
    static bool FileOk(IntPtr h) { return h != IntPtr.Zero && h != INVALID_HANDLE_VALUE; }


    const uint GENERIC_READ = 0x80000000;
    const uint OPEN_ALWAYS = 4;
    const uint OPEN_EXISTING = 3;
    const uint CREATE_NEW = 1;
    const uint FILE_ATTRIBUTE_NORMAL = 0x80;
    const uint ERROR_ALREADY_EXISTS = 183;
    const int SW_RESTORE = 9;

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hWnd);

    // 找到属于指定 PID 的第一个可见、未最小化的顶层窗口（用于把老实例顶到前台）
    static IntPtr FindWindowOfPid(uint pid)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint p = 0;
            GetWindowThreadProcessId(hWnd, out p);
            if (p != pid) return true;
            if (!IsWindowVisible(hWnd)) return true;
            found = hWnd;
            return false;   // 命中即停
        }, IntPtr.Zero);
        return found;
    }

    // 试抢锁。参数：single-instance <mutexName> <lockPath> <infoPath> <ownerPid>
    //   抢到   → 独占打开 lockPath 并**保持句柄**，把 "<pid> <hwnd>" 写进 infoPath，打印 FIRST
    //   已有活实例 → 恢复并前置它的窗口，打印 SECOND <pid> <hwnd>
    //
    // ★★ 这里用**两个文件**，原因是踩过一次坑：
    //   持锁者把 lockPath 以 dwShareMode=0 **独占**打开，而"独占"在 Windows 上意味着
    //   **连读也不允许** —— 后来者读不到 lockPath 的内容 → 误判"陈旧锁" → 抢夺。
    //   （实测：持锁者活着，第二个仍报 FIRST。）
    //   所以：lockPath 只承担"锁"（探测它的**共享冲突**），infoPath 承担"内容"（可正常读）。
    //
    // ★ 本函数只在 `hold`（长生命周期）里跑；一次性调用持不住锁，见文件头注释。
    static void SingleInstance(string mutexName, string lockPath, string infoPath, long ownerPid)
    {
        // ---- 判定"是否已有活实例" ----
        // 判据 1：能否独占打开 lockPath。持锁者正占着它 → CreateFile 失败（ERROR_SHARING_VIOLATION）
        bool locked = !CanOpenExclusive(lockPath);
        long alivePid = 0;
        long aliveHwnd = 0;
        bool haveInfo = TryReadLockFile(infoPath, out alivePid, out aliveHwnd);

        if (locked && haveInfo && IsProcessAlive((uint)alivePid))
        {
            // 已有活实例：恢复并前置它的窗口，让"第二次点击"看起来像"回到已有游戏"
            ActivateExisting(aliveHwnd);
            Console.Out.Write("SECOND " + alivePid + " " + aliveHwnd);
            return;
        }
        // locked == false → 没人持锁（首次 / 陈旧）
        // locked == true 但没读到 info 或进程已死 → 陈旧锁，抢过来

        // ---- 成为首个：独占打开并**保持句柄不关** ----
        // ★★ 持锁句柄：`GENERIC_READ` + `dwShareMode=0` + **OPEN_ALWAYS**。
        //
        // 访问掩码必须与探测方**一致**（都是 GENERIC_READ）：Windows 的共享检查是
        // "双方都满意才通过"，持锁者只读打开时，一个带 GENERIC_WRITE 的请求**也满足**
        // 它的条件（读与读兼容）→ 探测误报"没被锁"（这个坑踩过）。
        //
        // ★ 这里**必须用 OPEN_ALWAYS 而不是 CREATE_NEW**（两者都试过）：
        //   CREATE_NEW 在"文件已存在"时必然失败（ERROR_ALREADY_EXISTS）。而正常流程是
        //   先跑一次 `single-instance` 判定（它会创建这个文件），再拉起持锁者
        //   → 持锁者永远撞上一个已存在的空文件 → 拿不到句柄 → 锁等于没上，
        //   第二个实例照旧抢进来（Godot 侧实测：持锁者活着、锁文件在、探测却 UNLOCKED）。
        IntPtr h = CreateFile(lockPath, GENERIC_READ, 0, IntPtr.Zero,
            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        long myHwnd = 0;
        IntPtr self = FindWindowOfPid((uint)ownerPid);
        if (self != IntPtr.Zero) myHwnd = self.ToInt64();

        // 内容写进**另一个**文件（可被后来者正常读）
        try
        {
            // ★ 必须用 **UTF8Encoding(false)**：默认的 Encoding.UTF8 会写 BOM，
            //   而带 BOM 的文件让 TryReadLockFile 里的 long.TryParse 失败 →
            //   alivePid 变 0 → 后来者误判"陈旧锁" → 抢锁（实测踩过）。
            using (FileStream fs = new FileStream(infoPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
            using (StreamWriter sw = new StreamWriter(fs, new UTF8Encoding(false)))
            {
                sw.Write(ownerPid + " " + myHwnd);
            }
        }
        catch { }

        if (FileOk(h))
        {
            _lockHandle = h;   // 挂到静态字段，活到进程结束（内核在进程退出时自动关）
        }
        Console.Out.Write("FIRST");
    }

    // ★★★ 持锁句柄必须挂在**静态字段**上，不能只用局部变量。
    //   踩过的第三个坑：局部 `IntPtr h` 虽然"故意不 CloseHandle"，但 .NET 侧没有任何
    //   终结器接管它，JIT/GC 可以在函数返回后把它当死对象处理（实测：另一个进程
    //   立刻就能独占打开同一文件 ⇒ 锁等于没上）。挂到 static 就没有这个疑问了。
    static IntPtr _lockHandle = IntPtr.Zero;

    // 试一下能不能独占打开（能 = 当前无人持锁）。
    // 试一下能不能打开锁文件（能 = 当前无人持锁）。
    //
    // ★★★ 这里踩了三个坑才做对，两个都关乎 **Windows 共享检查的语义**：
    //   ① 访问掩码必须与持锁者**一致**（都是 GENERIC_READ）。共享检查是"双方都满意才通过"：
    //      持锁者以 GENERIC_READ + share=0 打开时，一个 GENERIC_READ|GENERIC_WRITE 的请求
    //      **也满足**它的条件（读与读兼容）→ 探测误报"没被锁"。实测：持锁者 handle=652 正常，
    //      探测却返回 opened，第二个实例直接抢进来。
    //   ② 失败判定必须用 `FileOk()`（`!= NULL && != INVALID_HANDLE_VALUE`）。
    //      只判 `== IntPtr.Zero` 会把 INVALID_HANDLE_VALUE(-1) 当成有效句柄。
    //   ③ 持锁端用 **CREATE_NEW** 而不是 OPEN_ALWAYS：后者在"文件已存在"时直接返回
    //      ERROR_ALREADY_EXISTS(183)，持锁者拿不到句柄（实测 handle=-1），锁等于没上。
    static bool CanOpenExclusive(string path)
    {
        try
        {
            if (!File.Exists(path)) return true;
            IntPtr h = CreateFile(path, GENERIC_READ, 0, IntPtr.Zero,
                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
            if (!FileOk(h)) return false;   // 共享冲突 → 有人持锁
            CloseHandle(h);
            return true;
        }
        catch { return false; }
    }

    // `lock-probe <lockPath>`：**只探测，不抢锁**。打印 LOCKED / UNLOCKED。
    // Godot 侧拿不到可靠的独占判据（FileAccess 在 Windows 上不独占，实测），
    // 所以启动持锁者后要确认"锁真的就位"，只能来这里问。
    // ★ 关键：必须与持锁者**同一访问掩码**（GENERIC_READ）+ 同样的 share=0，
    //   否则读/写掩码不一致会让读-vs-读兼容，探测误报 UNLOCKED（踩过）。
    static void LockProbe(string lockPath)
    {
        if (string.IsNullOrEmpty(lockPath) || !File.Exists(lockPath))
        {
            Console.Out.Write("UNLOCKED");
            return;
        }
        Console.Out.Write(CanOpenExclusive(lockPath) ? "UNLOCKED" : "LOCKED");
    }

    static void HoldSingleInstance(string mutexName, string lockPath, string infoPath, long ownerPid)
    {
        SingleInstance(mutexName, lockPath, infoPath, ownerPid);
        Console.Out.Flush();
        while (IsProcessAlive((uint)ownerPid))
        {
            System.Threading.Thread.Sleep(500);
        }
    }

    static void ActivateExisting(long hwnd)
    {
        if (hwnd == 0) return;
        IntPtr h = new IntPtr(hwnd);
        if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
        SetForegroundWindow(h);
    }

    static bool TryReadLockFile(string path, out long pid, out long hwnd)
    {
        pid = 0; hwnd = 0;
        try
        {
            if (!File.Exists(path)) return false;
            string s = File.ReadAllText(path).Trim();
            if (s.Length > 0 && s[0] == '\uFEFF') s = s.Substring(1).Trim();   // 去 UTF-8 BOM
            string[] parts = s.Split(' ');
            if (parts.Length < 1) return false;
            long.TryParse(parts[0], out pid);
            if (parts.Length > 1) long.TryParse(parts[1], out hwnd);
            return pid > 0;
        }
        catch { return false; }
    }

    static bool IsProcessAlive(uint pid)
    {
        if (pid == 0) return false;
        try
        {
            using (System.Diagnostics.Process p = System.Diagnostics.Process.GetProcessById((int)pid)) return !p.HasExited;
        }
        catch { return false; }
    }

    const uint PROCESS_VM_OPERATION = 0x0008;
    const uint PROCESS_VM_READ = 0x0010;
    const uint PROCESS_VM_WRITE = 0x0020;
    const uint MEM_COMMIT = 0x1000;
    const uint PAGE_READWRITE = 0x04;
    const uint MEM_RELEASE = 0x8000;
    const uint LVM_GETITEMCOUNT = 0x1000 + 4;     // 0x1004
    const uint LVM_GETITEMW = 0x1000 + 75;        // 0x104B (桌面 ListView 用 GETITEM 取文字，GETITEMTEXT 返回 0)
    const uint LVM_GETITEMPOSITION = 0x1000 + 16; // 0x1010
    const uint LVM_GETIMAGELIST = 0x1000 + 2;     // 0x1002
    const uint LVM_GETITEMRECT = 0x1000 + 14;     // 0x100E 取整项矩形（含图标+文字标签），LVIR_BOUNDS
    const int LVSIL_NORMAL = 0;
    const uint LVIF_TEXT = 0x0001;

    // ---- 强制置顶（争对 Godot 透明窗口上 WS_EX_TOPMOST 被后续窗口操作降级的兜底）----
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_NOMOVE = 0x0002;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint SWP_SHOWWINDOW = 0x0040;
    const int GWL_EXSTYLE = -20;
    const int WS_EX_TOPMOST = 0x00000008;
    // WS_EX_TOOLWINDOW：把窗口标记为工具窗口 → 不出现在任务栏、也不出现在 Alt+Tab 列表里。
    const int WS_EX_TOOLWINDOW = 0x00000080;
    // WS_EX_APPWINDOW：强制普通程序出现在任务栏。置工具窗时必须一并清掉它，否则二者冲突。
    const int WS_EX_APPWINDOW = 0x00040000;

    // 把指定窗口钉到置顶层（HWND_TOPMOST）。游戏窗口是覆盖整个屏幕的透明层，
    // 用原生 SetWindowPos 强制置顶后，按 Win+D（显示桌面）也不会把它最小化（= 加速球行为）。
    // hwnd 来自 DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)。
    public static void PinTopmost(long hwnd)
    {
        if (hwnd == 0) return;
        SetWindowPos((IntPtr)hwnd, HWND_TOPMOST, 0, 0, 0, 0,
            SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }

    // 读取窗口扩展样式，返回是否带 WS_EX_TOPMOST（用于验证"置顶真的落进了系统"）
    public static bool isTopmost(long hwnd)
    {
        if (hwnd == 0) return false;
        return (GetWindowLong((IntPtr)hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
    }

    // 把窗口标记为「工具窗口」：从任务栏 + Alt+Tab 列表里隐藏（本游戏是铺满全屏的桌面覆盖层，
    // 常驻任务栏会挤占一格并干扰玩家）。on=true 加 WS_EX_TOOLWINDOW 并清 WS_EX_APPWINDOW；
    // on=false 反向恢复（把游戏变回普通任务栏窗口）。
    // ★ 必须一并清 WS_EX_APPWINDOW：它和 TOOLWINDOW 同时存在时 Windows 按"显示在任务栏"处理。
    public static bool SetToolWindow(long hwnd, bool on)
    {
        if (hwnd == 0) return false;
        int ex = GetWindowLong((IntPtr)hwnd, GWL_EXSTYLE);
        if (on)
        {
            ex |= WS_EX_TOOLWINDOW;
            ex &= ~WS_EX_APPWINDOW;
        }
        else
        {
            ex &= ~WS_EX_TOOLWINDOW;
            ex |= WS_EX_APPWINDOW;
        }
        SetWindowLongPtr((IntPtr)hwnd, GWL_EXSTYLE, (IntPtr)ex);
        return isToolWindow(hwnd) == on;
    }

    // 读回：窗口当前是否带 WS_EX_TOOLWINDOW（验证"从任务栏隐藏"真的落进了系统）
    public static bool isToolWindow(long hwnd)
    {
        if (hwnd == 0) return false;
        return (GetWindowLong((IntPtr)hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0;
    }

    // 统一入口。编译成独立 EXE 后由命令行参数分发；无参行为与旧版 `Main()` 完全一致，
    // 因此 gather_sysinfo.ps1 只需改成 `[SysInfo]::Main(@())` 即可继续工作。
    //   （无参）             → 采集整机信息写入 %Documents%\HelloNyxel\Temp\sysinfo.json（原行为）
    //   scene <pid> <hwnd>   → 把「各窗口矩形 + 桌面图标」JSON 打到 stdout（Godot 每秒轮询用）
    //   topmost <hwnd>       → 置顶位不在就补钉，打印 TOPMOST_OK / TOPMOST_FAIL
    //   topmost-check <hwnd> → 只读回状态打印，不改动任何窗口
    //   toolwindow <hwnd> <0|1> → 加/清 WS_EX_TOOLWINDOW（从任务栏+Alt+Tab 隐藏），打印 TOOLWIN_OK / FAIL
    //   window-style <hwnd> <pin> <hideTaskbar> → 一次做「置顶 + 任务栏隐藏」并各自回读验证
    //   subtree <pid>        → 打印该进程树的子进程数 + 内存合计 JSON（自测量面板用）
    //   single-instance <mutexName> <lockFile> <myPid>
    //                        → 单实例仲裁。输出 FIRST（我是首个，继续启动）或
    //                          SECOND <既有pid> <既有hwnd>（已有实例，调用方应立刻退出）
    // ★★ 为什么要 EXE：旧路径每次都要 `powershell.exe -File enumerate_scene.ps1`，
    //    而脚本每次都 `Add-Type -Path SysInfo.cs` **现编译 30 KB C#**（实测单次 1.0~1.1 s，
    //    其中约 0.64 s 花在编译上）。每秒一次 ⇒ 一个 PowerShell 几乎从不空闲，构成与帧率
    //    无关的 ~0.28 核固定底噪。预编译成 EXE 后这两段开销都不再存在。
    // ★ 必须保持 `[STAThread]`：BuildDesktopIcons 走 Shell/注册表，需要 STA 单元。
    // ★ 入口唯一：C# 不允许同一编译单元存在两个 Main，故只保留这一个带参数版本。
    [STAThread]
    public static void Main(string[] args)
    {
        string cmd = (args != null && args.Length > 0) ? args[0] : "";
        switch (cmd)
        {
            case "scene":
                WriteSceneJson(ArgLong(args, 1), ArgLong(args, 2));
                return;
            case "topmost":
                Console.Out.Write(PinIfNeeded(ArgLong(args, 1), true));
                return;
            case "topmost-check":
                Console.Out.Write(PinIfNeeded(ArgLong(args, 1), false));
                return;
            case "toolwindow":
                // toolwindow <hwnd> <0|1> → 加/清 WS_EX_TOOLWINDOW，打印 TOOLWIN_OK / TOOLWIN_FAIL
                Console.Out.Write(SetToolWindowVerb(ArgLong(args, 1), args.Length > 2 && args[2] == "1"));
                return;
            case "window-style":
                // window-style <hwnd> <pin:0|1> <hideTaskbar:0|1>
                //   → 一次调用同时处理「置顶」与「任务栏隐藏」，打印 "STYLE=<sep> TOPMOST_OK|FAIL TOOLWIN_OK|FAIL"。
                //   为什么要合并：DesktopShell 的兜底守护（周期/句柄变化/失焦）本来就要钉一次置顶，
                //   顺手把任务栏样式也补上，只需一次子进程 —— 单独再起一条线程/进程去设工具窗是纯浪费。
                Console.Out.Write(ApplyWindowStyle(ArgLong(args, 1),
                    args.Length > 2 && args[2] == "1",
                    args.Length > 3 && args[3] == "1"));
                return;
            case "subtree":
                Console.Out.Write(BuildSubtreeJson(ArgLong(args, 1)));
                return;
            case "lock-probe":
                LockProbe(args.Length > 1 ? args[1] : "");
                return;
            case "single-instance":
                SingleInstance(args.Length > 1 ? args[1] : "HelloNyxel.SingleInstance",
                    args.Length > 2 ? args[2] : "",
                    args.Length > 3 ? args[3] : "",
                    ArgLong(args, 4));
                return;
            case "single-instance-hold":
                HoldSingleInstance(args.Length > 1 ? args[1] : "HelloNyxel.SingleInstance",
                    args.Length > 2 ? args[2] : "",
                    args.Length > 3 ? args[3] : "",
                    ArgLong(args, 4));
                return;
            default:
                WriteSysInfoJson();
                return;
        }
    }

    static long ArgLong(string[] args, int index)
    {
        long v = 0;
        if (args != null && args.Length > index) long.TryParse(args[index], out v);
        return v;
    }

    // Godot 每秒轮询用：直接写 stdout，不落盘。
    // ★ 用**不带 BOM** 的 UTF8：管道里多一个 BOM 会让 JSON.parse_string 解析失败。
    static void WriteSceneJson(long gamePid, long gameHwnd)
    {
        try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }
        Console.Out.Write(BuildSceneJson(gamePid, gameHwnd));
    }

    // 置顶：只在"不在位"时才补钉 —— 对已置顶窗口重复 SetWindowPos 的唯一效果是抢
    // 「置顶层 band」最上面，会跟截图软件等同样置顶的覆盖窗打架（z 序拉锯）。见 pin_topmost.ps1。
    static string PinIfNeeded(long hwnd, bool pin)
    {
        if (pin && hwnd != 0 && !isTopmost(hwnd)) PinTopmost(hwnd);
        return isTopmost(hwnd) ? "TOPMOST_OK" : "TOPMOST_FAIL";
    }

    // 命令行版「设置工具窗口样式」：改完回读，打印 TOOLWIN_OK / TOOLWIN_FAIL（供 DesktopShell 验证）。
    static string SetToolWindowVerb(long hwnd, bool on)
    {
        bool ok = SetToolWindow(hwnd, on);
        return ok ? "TOOLWIN_OK" : "TOOLWIN_FAIL";
    }

    // 一次调用同时处理「置顶」与「任务栏隐藏」，各自回读验证后合并输出。
    // 输出格式（单行）："STYLE TOPMOST_OK|TOPMOST_FAIL TOOLWIN_OK|TOOLWIN_FAIL"
    // 任一为空 hwnd → 两项都判 FAIL（调用方据此报错）。
    static string ApplyWindowStyle(long hwnd, bool pin, bool hideTaskbar)
    {
        if (hwnd == 0)
        {
            return "STYLE TOPMOST_FAIL TOOLWIN_FAIL";
        }
        string top = pin ? PinIfNeeded(hwnd, true) : (isTopmost(hwnd) ? "TOPMOST_OK" : "TOPMOST_FAIL");
        bool twOk = SetToolWindow(hwnd, hideTaskbar);
        return "STYLE " + top + " " + (twOk ? "TOOLWIN_OK" : "TOOLWIN_FAIL");
    }

    static void WriteSysInfoJson()
    {
        string json = "{}";
        try
        {
            SetProcessDPIAware();
            StringBuilder j = new StringBuilder();
            j.Append("{\n");

            F(j, "", "generated_at", S(DateTimeOffset.Now.ToString("yyyy-MM-ddTHH:mm:sszzz")), false);

            StringBuilder m = new StringBuilder();
            F(m, "  ", "computer_name", S(Environment.MachineName), false);
            F(m, "  ", "user_name", S(Environment.UserName), true);
            j.Append("  \"machine\": {\n").Append(m.ToString()).Append("  },\n");

            j.Append("  \"screen\": ");
            j.Append(BuildScreen());
            j.Append(",\n");

            j.Append("  \"taskbar\": ");
            j.Append(BuildTaskbar());
            j.Append(",\n");

            // 桌面图标（含新增的 icon_cell_spacing 图标网格间距）：随 sysinfo.json 一起落盘，供启动读取
            j.Append("  \"desktop_icons\": ");
            j.Append(BuildDesktopIcons());
            j.Append(",\n");

            // 系统常量段（consts）：把设备相关数值以「具名常量」落盘，供 Godot SystemConst
            // autoload 按名快速调用（积木宽高等可写常量名，跨设备解析成不同实际尺寸）。
            j.Append("  \"consts\": ");
            j.Append(BuildConsts());
            j.Append(",\n");

            StringBuilder t = new StringBuilder();
            F(t, "  ", "local", S(DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss")), false);
            F(t, "  ", "utc", S(DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss")), false);
            F(t, "  ", "offset", S(DateTimeOffset.Now.Offset.ToString()), true);
            j.Append("  \"time\": {\n").Append(t.ToString()).Append("  },\n");

            j.Append("  \"timezone\": ");
            j.Append(BuildTimeZone());
            j.Append(",\n");

            j.Append("  \"language\": ");
            j.Append(BuildLanguage());
            j.Append("\n");

            j.Append("}\n");
            json = j.ToString();
        }
        catch (Exception ex)
        {
            json = "{\"error\":\"" + Esc(ex.ToString()) + "\"}";
        }

        try
        {
            string docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            string dir = Path.Combine(docs, "HelloNyxel", "Temp");
            Directory.CreateDirectory(dir);
            string file = Path.Combine(dir, "sysinfo.json");
            File.WriteAllText(file, json, new UTF8Encoding(false));
        }
        catch { }
    }

    // ---------- screen ----------
    static string BuildScreen()
    {
        StringBuilder s = new StringBuilder();
        s.Append("{\n");
        Rectangle pb = Screen.PrimaryScreen.Bounds;
        F(s, "    ", "primary_resolution", "{\"width\":" + pb.Width + ",\"height\":" + pb.Height + "}", false);
        Rectangle vs = SystemInformation.VirtualScreen;
        F(s, "    ", "virtual_screen", "{\"x\":" + vs.X + ",\"y\":" + vs.Y + ",\"width\":" + vs.Width + ",\"height\":" + vs.Height + "}", false);
        int dpi = 96;
        try { dpi = (int)GetDpiForSystem(); } catch { }
        F(s, "    ", "system_dpi", dpi.ToString(), false);

        StringBuilder mon = new StringBuilder();
        mon.Append("[\n");
        Screen[] screens = Screen.AllScreens;
        for (int i = 0; i < screens.Length; i++)
        {
            Screen sc = screens[i];
            Rectangle b = sc.Bounds;
            Rectangle wa = sc.WorkingArea;
            StringBuilder one = new StringBuilder();
            one.Append("{\"device\":" + S(sc.DeviceName));
            one.Append(",\"is_primary\":" + (sc.Primary ? "true" : "false"));
            one.Append(",\"bounds\":{\"x\":" + b.X + ",\"y\":" + b.Y + ",\"width\":" + b.Width + ",\"height\":" + b.Height + "}");
            one.Append(",\"working_area\":{\"x\":" + wa.X + ",\"y\":" + wa.Y + ",\"width\":" + wa.Width + ",\"height\":" + wa.Height + "}");
            one.Append(",\"bits_per_pixel\":" + sc.BitsPerPixel + "}");
            mon.Append("      " + one.ToString());
            mon.Append(i < screens.Length - 1 ? ",\n" : "\n");
        }
        mon.Append("    ]");
        F(s, "    ", "monitors", mon.ToString(), true);
        s.Append("  }");
        return s.ToString();
    }

    // ---------- taskbar ----------
    // 记录任务栏贴在桌面哪条边（edge）及其"厚度"（沿该边的垂直像素高度 / 水平像素宽度）。
    // 对常见的底部任务栏：height_px = 屏幕高 - 工作区高（如 1600-1528=72）。
    // Godot 侧据此在任务栏上表面（或侧边内沿）生成 1px 阻挡积木，防止积木落入任务栏。
    static string BuildTaskbar()
    {
        try
        {
            Rectangle pb = Screen.PrimaryScreen.Bounds;
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            string edge;
            int h;
            if (wa.Width == pb.Width)
            {
                // 顶/底任务栏：厚度 = 竖直方向被占用的像素
                h = pb.Height - wa.Height;
                edge = (wa.Top == pb.Top) ? "bottom" : "top";
            }
            else
            {
                // 左/右任务栏：厚度 = 水平方向被占用的像素
                h = pb.Width - wa.Width;
                edge = (wa.Left == pb.Left) ? "right" : "left";
            }
            return "{\"edge\":" + S(edge) + ",\"height_px\":" + h + "}";
        }
        catch
        {
            return "{\"edge\":\"bottom\",\"height_px\":0}";
        }
    }

    // ---------- consts ----------
    // 系统常量段：只做轻量采集（注册表 / SPI / Screen / GetDpiForSystem），
    // 不重复 desktop_icons 的重量级图标枚举。各键与原始段的对应：
    //   icon_size         <-> desktop_icons.icon_size_px
    //   icon_cell_spacing <-> desktop_icons.icon_cell_spacing
    //   taskbar_height    <-> taskbar.height_px
    //   screen_width/height <-> screen.primary_resolution.width/height
    //   system_dpi        <-> screen.system_dpi
    // Godot SystemConst 读 consts 优先，缺失时回退原始段（兼容旧 EXE 写出的文件）。
    static string BuildConsts()
    {
        StringBuilder s = new StringBuilder();
        s.Append("{\n");

        int iconSizePx = 0;
        try
        {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\Shell\Bags\1\Desktop"))
            {
                if (k != null)
                {
                    object o = k.GetValue("IconSize");
                    if (o != null) iconSizePx = Convert.ToInt32(o);
                }
            }
        }
        catch { }
        if (iconSizePx <= 0) iconSizePx = 48;

        int cellSpacing = 0;
        try
        {
            uint hsp = 0, vsp = 0;
            if (SystemParametersInfo(SPI_GETICONHORIZONTALSPACING, 0, ref hsp, 0)) cellSpacing = (int)hsp;
            if (cellSpacing <= 0 && SystemParametersInfo(SPI_GETICONVERTICALSPACING, 0, ref vsp, 0)) cellSpacing = (int)vsp;
        }
        catch { }
        if (cellSpacing <= 0) cellSpacing = iconSizePx * 2;

        Rectangle pb = Screen.PrimaryScreen.Bounds;
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        // 任务栏厚度：顶/底贴边 = 竖直差；左/右贴边 = 水平差
        int taskbarH = (wa.Width == pb.Width) ? pb.Height - wa.Height : pb.Width - wa.Width;
        if (taskbarH < 0) taskbarH = 0;

        int dpi = 96;
        try { dpi = (int)GetDpiForSystem(); } catch { }

        F(s, "    ", "icon_size", iconSizePx.ToString(), false);
        F(s, "    ", "icon_cell_spacing", cellSpacing.ToString(), false);
        F(s, "    ", "taskbar_height", taskbarH.ToString(), false);
        F(s, "    ", "screen_width", pb.Width.ToString(), false);
        F(s, "    ", "screen_height", pb.Height.ToString(), false);
        F(s, "    ", "system_dpi", dpi.ToString(), true);
        s.Append("  }");
        return s.ToString();
    }

    // ---------- desktop icons ----------
    static string BuildDesktopIcons()
    {
        StringBuilder s = new StringBuilder();
        s.Append("{\n");

        int iconSizePx = 0;
        try
        {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\Shell\Bags\1\Desktop"))
            {
                if (k != null)
                {
                    object o = k.GetValue("IconSize");
                    if (o != null) iconSizePx = Convert.ToInt32(o);
                }
            }
        }
        catch { }

        string viewMode = "Unknown";
        if (iconSizePx > 0)
        {
            if (iconSizePx <= 32) viewMode = "Small";
            else if (iconSizePx <= 64) viewMode = "Medium";
            else viewMode = "Large";
        }
        F(s, "    ", "view_mode", S(viewMode), false);
        F(s, "    ", "icon_size_px", iconSizePx.ToString(), false);

        // 图标单元格间距（新字段）：桌面图标网格间距，作为图标边界/占位几何的基准。
        // 取 SPI 的水平间距；拿不到就退回 iconSizePx 的 2 倍；仍拿不到用 96。
        int cellSpacing = 0;
        try
        {
            uint hsp = 0, vsp = 0;
            if (SystemParametersInfo(SPI_GETICONHORIZONTALSPACING, 0, ref hsp, 0)) cellSpacing = (int)hsp;
            if (cellSpacing <= 0 && SystemParametersInfo(SPI_GETICONVERTICALSPACING, 0, ref vsp, 0)) cellSpacing = (int)vsp;
        }
        catch { }
        if (cellSpacing <= 0) cellSpacing = (iconSizePx > 0) ? iconSizePx * 2 : 96;
        F(s, "    ", "icon_cell_spacing", cellSpacing.ToString(), false);

        List<string> names = new List<string>();
        List<int> xs = new List<int>();
        List<int> ys = new List<int>();
        List<int> ws = new List<int>();
        List<int> hs = new List<int>();
        int lvIconSize = 0;
        try
        {
            IntPtr lv = FindDesktopListView();
            if (lv != IntPtr.Zero)
            {
                try
                {
                    IntPtr himl = SendMessage(lv, LVM_GETIMAGELIST, (IntPtr)LVSIL_NORMAL, IntPtr.Zero);
                    int cx = 0, cy = 0;
                    if (himl != IntPtr.Zero && ImageList_GetIconSize(himl, out cx, out cy)) lvIconSize = cx;
                }
                catch { }

                int count = (int)SendMessage(lv, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero);
                uint pid = 0;
                GetWindowThreadProcessId(lv, out pid);
                IntPtr hProc = OpenProcess(PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE, false, pid);
                if (hProc != IntPtr.Zero)
                {
                    int ptrSize = IntPtr.Size;
                    int lvItemSize = (ptrSize == 8) ? 96 : 64;
                    int offPszText = (ptrSize == 8) ? 24 : 20;
                    int offCchTextMax = (ptrSize == 8) ? 32 : 24;
                    IntPtr pLVITEM = VirtualAllocEx(hProc, IntPtr.Zero, (uint)lvItemSize, MEM_COMMIT, PAGE_READWRITE);
                    IntPtr pText = VirtualAllocEx(hProc, IntPtr.Zero, 520, MEM_COMMIT, PAGE_READWRITE);
                    IntPtr pPoint = VirtualAllocEx(hProc, IntPtr.Zero, 8, MEM_COMMIT, PAGE_READWRITE);
                    IntPtr pRect = VirtualAllocEx(hProc, IntPtr.Zero, 16, MEM_COMMIT, PAGE_READWRITE);
                    if (pLVITEM != IntPtr.Zero && pText != IntPtr.Zero && pPoint != IntPtr.Zero)
                    {
                        byte[] lvBuf = new byte[lvItemSize];
                        for (int i = 0; i < count; i++)
                        {
                            SetI32(lvBuf, 0, (int)LVIF_TEXT);
                            SetI32(lvBuf, 4, i);
                            SetI32(lvBuf, 8, 0);
                            SetI64(lvBuf, offPszText, (long)pText.ToInt64());
                            SetI32(lvBuf, offCchTextMax, 260);
                            uint w = 0;
                            WriteProcessMemory(hProc, pLVITEM, lvBuf, (uint)lvItemSize, out w);
                            SendMessage(lv, LVM_GETITEMW, (IntPtr)i, pLVITEM);
                            byte[] txt = new byte[520];
                            uint r = 0;
                            ReadProcessMemory(hProc, pText, txt, 520, out r);
                            string name = Encoding.Unicode.GetString(txt);
                            int nz = name.IndexOf('\0');
                            if (nz >= 0) name = name.Substring(0, nz);
                            names.Add(name);
                            SendMessage(lv, LVM_GETITEMPOSITION, (IntPtr)i, pPoint);
                            byte[] pt = new byte[8];
                            ReadProcessMemory(hProc, pPoint, pt, 8, out r);
                            int px = BitConverter.ToInt32(pt, 0);
                            int py = BitConverter.ToInt32(pt, 4);
                            // 优先取整项矩形（含图标+文字标签），否则退回「位置 + 图标尺寸」
                            int rw = 0, rh = 0;
                            if (pRect != IntPtr.Zero)
                            {
                                byte[] zr = new byte[16];
                                WriteProcessMemory(hProc, pRect, zr, 16, out w);
                                SendMessage(lv, LVM_GETITEMRECT, (IntPtr)i, pRect);
                                byte[] rr = new byte[16];
                                ReadProcessMemory(hProc, pRect, rr, 16, out r);
                                int L = BitConverter.ToInt32(rr, 0);
                                int T = BitConverter.ToInt32(rr, 4);
                                int Rg = BitConverter.ToInt32(rr, 8);
                                int Bm = BitConverter.ToInt32(rr, 12);
                                if (Rg > L && Bm > T)
                                {
                                    px = L; py = T; rw = Rg - L; rh = Bm - T;
                                }
                            }
                            int fb = (lvIconSize > 0) ? lvIconSize : iconSizePx;
                            if (rw <= 0 || rh <= 0) { rw = fb; rh = fb; }
                            xs.Add(px); ys.Add(py); ws.Add(rw); hs.Add(rh);
                        }
                    }
                    if (pLVITEM != IntPtr.Zero) VirtualFreeEx(hProc, pLVITEM, 0, MEM_RELEASE);
                    if (pText != IntPtr.Zero) VirtualFreeEx(hProc, pText, 0, MEM_RELEASE);
                    if (pPoint != IntPtr.Zero) VirtualFreeEx(hProc, pPoint, 0, MEM_RELEASE);
                    if (pRect != IntPtr.Zero) VirtualFreeEx(hProc, pRect, 0, MEM_RELEASE);
                    CloseHandle(hProc);
                }
            }
        }
        catch (Exception ex)
        {
            F(s, "    ", "enum_error", S(ex.Message), false);
        }
        F(s, "    ", "listview_icon_size", lvIconSize.ToString(), false);
        F(s, "    ", "count", names.Count.ToString(), false);

        StringBuilder items = new StringBuilder();
        items.Append("[\n");
        for (int i = 0; i < names.Count; i++)
        {
            StringBuilder it = new StringBuilder();
            it.Append("{\"name\":" + S(names[i]));
            it.Append(",\"x\":" + xs[i]);
            it.Append(",\"y\":" + ys[i]);
            it.Append(",\"w\":" + ws[i]);
            it.Append(",\"h\":" + hs[i] + "}");
            items.Append("      " + it.ToString());
            items.Append(i < names.Count - 1 ? ",\n" : "\n");
        }
        items.Append("    ]");
        F(s, "    ", "items", items.ToString(), true);

        s.Append("  }");
        return s.ToString();
    }

    // ---------- subtree（进程树快照，不落盘）----------
    // 给「自测量面板（批次 1）」用：返回本游戏进程树的「子进程个数 + 内存合计」。
    //   {"root_pid":N,"self_mb":x,"child_count":N,"child_mb":x,"tree_mb":x,
    //    "names":[{"name":"TrayIcon.exe","count":1,"mb":29.3}, ...]}
    // ★ 内存走 .NET 的 Process.WorkingSet64（= 任务管理器「内存」列），不再拉一份 psapi
    //   P/Invoke + 结构体；单个进程读不到（已退出 / 受保护）返 0，不影响整体。
    // ★ 父子关系只能靠 Toolhelp 快照（.NET 的 Process 不带父 PID）。
    public static string BuildSubtreeJson(long rootPid)
    {
        try
        {
            Dictionary<uint, List<uint>> kids = new Dictionary<uint, List<uint>>();
            Dictionary<uint, string> names = new Dictionary<uint, string>();
            IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snap != INVALID_HANDLE_VALUE)
            {
                PROCESSENTRY32W pe = new PROCESSENTRY32W();
                pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                if (Process32FirstW(snap, ref pe))
                {
                    do
                    {
                        uint p = pe.th32ProcessID;
                        names[p] = pe.szExeFile;
                        if (!kids.ContainsKey(pe.th32ParentProcessID))
                            kids[pe.th32ParentProcessID] = new List<uint>();
                        kids[pe.th32ParentProcessID].Add(p);
                    } while (Process32NextW(snap, ref pe));
                }
                CloseHandle(snap);
            }
            // BFS 出全部后代；visited 兜住 PID 复用可能造成的环
            List<uint> desc = new List<uint>();
            Dictionary<uint, bool> seen = new Dictionary<uint, bool>();
            uint root = (uint)rootPid;
            seen[root] = true;
            List<uint> queue = new List<uint>();
            queue.Add(root);
            while (queue.Count > 0)
            {
                uint cur = queue[0];
                queue.RemoveAt(0);
                List<uint> cs;
                if (!kids.TryGetValue(cur, out cs)) continue;
                foreach (uint c in cs)
                {
                    if (seen.ContainsKey(c)) continue;
                    seen[c] = true;
                    desc.Add(c);
                    queue.Add(c);
                }
            }
            double selfMb = WorkingSetMb(root);
            double childMb = 0.0;
            Dictionary<string, int> byName = new Dictionary<string, int>();
            Dictionary<string, double> mbByName = new Dictionary<string, double>();
            foreach (uint c in desc)
            {
                double mb = WorkingSetMb(c);
                childMb += mb;
                string nm = names.ContainsKey(c) ? names[c] : ("pid" + c.ToString(CultureInfo.InvariantCulture));
                if (!byName.ContainsKey(nm))
                {
                    byName[nm] = 0;
                    mbByName[nm] = 0.0;
                }
                byName[nm] = byName[nm] + 1;
                mbByName[nm] = mbByName[nm] + mb;
            }
            StringBuilder j = new StringBuilder();
            j.Append("{");
            j.Append("\"root_pid\":").Append(root.ToString(CultureInfo.InvariantCulture));
            j.Append(",\"self_mb\":").Append(Round1(selfMb));
            j.Append(",\"child_count\":").Append(desc.Count.ToString(CultureInfo.InvariantCulture));
            j.Append(",\"child_mb\":").Append(Round1(childMb));
            j.Append(",\"tree_mb\":").Append(Round1(selfMb + childMb));
            j.Append(",\"names\":[");
            bool first = true;
            foreach (KeyValuePair<string, int> kv in byName)
            {
                if (!first) j.Append(",");
                first = false;
                j.Append("{\"name\":\"").Append(Esc(kv.Key)).Append("\",\"count\":")
                 .Append(kv.Value.ToString(CultureInfo.InvariantCulture))
                 .Append(",\"mb\":").Append(Round1(mbByName[kv.Key])).Append("}");
            }
            j.Append("]}");
            return j.ToString();
        }
        catch (Exception ex)
        {
            return "{\"error\":\"" + Esc(ex.ToString()) + "\"}";
        }
    }

    // 单个进程的 WorkingSet（MB）；读不到（已退出 / 受保护）返 0。
    static double WorkingSetMb(uint pid)
    {
        try
        {
            System.Diagnostics.Process p = System.Diagnostics.Process.GetProcessById((int)pid);
            return p.WorkingSet64 / 1048576.0;
        }
        catch { return 0.0; }
    }

    // 固定 1 位小数的 JSON 数字（用 InvariantCulture，避免区域小数分隔符变成逗号）
    static string Round1(double v)
    {
        return Math.Round(v, 1).ToString("0.0", CultureInfo.InvariantCulture);
    }

    // ---------- scene（内存枚举，不落盘）----------
    // 给 Godot 定时轮询用：一次性返回「各程序窗口矩形 + 桌面图标」，直接进内存解析，
    // 不写任何文件。窗口含普通程序与各种悬浮窗（含 WS_EX_TOOLWINDOW），跳过隐藏/最小化/零尺寸
    // 的系统窗口与桌面外壳（Progman/WorkerW/任务栏）。hwnd 作稳定身份键供 Godot 差量同步。
    public static string BuildSceneJson(long gamePid, long gameHwnd)
    {
        try
        {
            SetProcessDPIAware();   // 确保与 Screen/GetWindowRect 走同一套物理像素
            StringBuilder j = new StringBuilder();
            j.Append("{\n");
            j.Append("  \"windows\": ");
            j.Append(BuildWindows(gamePid, gameHwnd));
            j.Append(",\n");
            j.Append("  \"desktop_icons\": ");
            j.Append(BuildDesktopIcons());
            j.Append("\n");
            j.Append("}\n");
            return j.ToString();
        }
        catch (Exception ex)
        {
            return "{\"error\":\"" + Esc(ex.ToString()) + "\"}";
        }
    }

    static string GetClass(IntPtr hwnd) { StringBuilder sb = new StringBuilder(256); GetClassName(hwnd, sb, 256); return sb.ToString(); }
    static string GetText(IntPtr hwnd) { StringBuilder sb = new StringBuilder(512); GetWindowText(hwnd, sb, 512); return sb.ToString(); }

    static string BuildWindows(long gamePid, long gameHwnd)
    {
        // gamePid / gameHwnd 由 desktop.gd 传入，用于跳过游戏自己的透明覆盖窗口：
        // 本脚本跑在独立的 PowerShell 进程里，GetCurrentProcessId() 拿到的是 PowerShell 的 PID，
        // 与游戏进程不同，用它豁免完全无效。因此优先用「游戏窗口精确 HWND」排除（最可靠），
        // gamePid 作为兜底（headless / 取不到句柄时仍可按进程跳过）。
        uint ownPid = (uint)gamePid;
        long ownHwnd = gameHwnd;
        List<string> list = new List<string>();
        int z = 0;
        EnumWindows(delegate(IntPtr hwnd, IntPtr lparam)
        {
            try
            {
                uint pid = 0;
                GetWindowThreadProcessId(hwnd, out pid);
                if (pid == ownPid) return true;            // 兜底：跳过游戏进程
                if (ownHwnd != 0 && hwnd.ToInt64() == ownHwnd) return true; // 精确跳过游戏自身窗口
                if (!IsWindowVisible(hwnd)) return true;   // 跳过隐藏窗口
                if (IsIconic(hwnd)) return true;           // 跳过最小化窗口
                try
                {
                    int cloaked;
                    DwmGetWindowAttribute(hwnd, 14, out cloaked, 4);   // DWMWA_CLOAKED = 14
                    if (cloaked != 0) return true;         // 跳过 DWM 伪装窗口（屏幕上不可见）
                }
                catch { }                                  // dwmapi 不可用时不影响枚举
                // 跳过「透明悬浮层」：TOOLWINDOW+LAYERED+NOACTIVATE 的全屏窗口（如 NVIDIA GeForce
                // Overlay，2559x1600 全屏透明却一直存在）。它们肉眼不可见却会盖住整个桌面，
                // 若为其建页面覆盖，低层积木会被全屏 cutout 洞永久洞穿（虚视跳转器消失的根因）。
                int ex = GetWindowLongW(hwnd, -20);        // GWL_EXSTYLE
                const int WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x8000000;
                if ((ex & WS_EX_TOOLWINDOW) != 0 && (ex & WS_EX_LAYERED) != 0 && (ex & WS_EX_NOACTIVATE) != 0)
                    return true;
                RECT r;
                if (!GetWindowRect(hwnd, out r)) return true;
                int w = r.Right - r.Left;
                int h = r.Bottom - r.Top;
                if (w <= 0 || h <= 0) return true;         // 跳过零尺寸窗口
                string cls = GetClass(hwnd);
                if (cls == "Progman" || cls == "WorkerW"
                    || cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd"
                    || cls == "ApplicationManager_DesktopShellWindow") return true;
                string title = GetText(hwnd);
                list.Add("{\"hwnd\":" + hwnd.ToInt64()
                    + ",\"pid\":" + pid
                    + ",\"z\":" + z
                    + ",\"title\":" + S(title)
                    + ",\"cls\":" + S(cls)
                    + ",\"x\":" + r.Left + ",\"y\":" + r.Top
                    + ",\"w\":" + w + ",\"h\":" + h + "}");
                z++;
            }
            catch { }
            return true;
        }, IntPtr.Zero);

        StringBuilder s = new StringBuilder();
        s.Append("[\n");
        for (int i = 0; i < list.Count; i++)
        {
            s.Append("      " + list[i]);
            s.Append(i < list.Count - 1 ? ",\n" : "\n");
        }
        s.Append("    ]");
        return s.ToString();
    }

    static IntPtr FindDesktopListView()
    {
        IntPtr progman = FindWindow("Progman", null);
        if (progman != IntPtr.Zero)
            SendMessage(progman, 0x052C, IntPtr.Zero, IntPtr.Zero);
        IntPtr def = IntPtr.Zero;
        if (progman != IntPtr.Zero)
            def = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (def != IntPtr.Zero)
        {
            IntPtr l = FindWindowEx(def, IntPtr.Zero, "SysListView32", null);
            if (l != IntPtr.Zero) return l;
        }
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr lparam)
        {
            StringBuilder sb = new StringBuilder(256);
            GetClassName(hwnd, sb, 256);
            if (sb.ToString() == "WorkerW")
            {
                IntPtr dv = FindWindowEx(hwnd, IntPtr.Zero, "SHELLDLL_DefView", null);
                if (dv != IntPtr.Zero)
                {
                    IntPtr l = FindWindowEx(dv, IntPtr.Zero, "SysListView32", null);
                    if (l != IntPtr.Zero) { found = l; return false; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // ---------- timezone ----------
    static string BuildTimeZone()
    {
        StringBuilder s = new StringBuilder();
        s.Append("{\n");
        try
        {
            TimeZoneInfo tz = TimeZoneInfo.Local;
            F(s, "    ", "id", S(tz.Id), false);
            F(s, "    ", "display_name", S(tz.DisplayName), false);
            F(s, "    ", "standard_name", S(tz.StandardName), false);
            F(s, "    ", "daylight_name", S(tz.DaylightName), false);
            F(s, "    ", "base_utc_offset", S(tz.BaseUtcOffset.ToString()), false);
            F(s, "    ", "supports_daylight_saving", tz.SupportsDaylightSavingTime ? "true" : "false", true);
        }
        catch (Exception ex)
        {
            F(s, "    ", "error", S(ex.Message), true);
        }
        s.Append("  }");
        return s.ToString();
    }

    // ---------- language ----------
    static string BuildLanguage()
    {
        StringBuilder s = new StringBuilder();
        s.Append("{\n");
        try
        {
            CultureInfo ui = CultureInfo.CurrentUICulture;
            CultureInfo cu = CultureInfo.CurrentCulture;
            CultureInfo ins = CultureInfo.InstalledUICulture;
            F(s, "    ", "ui_culture_name", S(ui.Name), false);
            F(s, "    ", "ui_culture_display", S(ui.DisplayName), false);
            F(s, "    ", "culture_name", S(cu.Name), false);
            F(s, "    ", "culture_display", S(cu.DisplayName), false);
            F(s, "    ", "installed_ui_culture", S(ins.Name), false);
            F(s, "    ", "user_default_ui_lcid", GetUserDefaultUILanguage().ToString(), false);
            F(s, "    ", "system_default_ui_lcid", GetSystemDefaultUILanguage().ToString(), false);
            string cur = (InputLanguage.CurrentInputLanguage != null)
                ? (InputLanguage.CurrentInputLanguage.Culture.Name + " (" + InputLanguage.CurrentInputLanguage.LayoutName + ")")
                : "";
            F(s, "    ", "current_input_language", S(cur), false);

            StringBuilder inp = new StringBuilder();
            inp.Append("[\n");
            InputLanguageCollection ilc = InputLanguage.InstalledInputLanguages;
            bool first = true;
            foreach (InputLanguage il in ilc)
            {
                if (!first) inp.Append(",\n");
                first = false;
                inp.Append("      " + S(il.Culture.Name + " (" + il.LayoutName + ")"));
            }
            inp.Append("\n    ]");
            F(s, "    ", "input_languages", inp.ToString(), true);
        }
        catch (Exception ex)
        {
            F(s, "    ", "error", S(ex.Message), true);
        }
        s.Append("  }");
        return s.ToString();
    }

    // ---------- helpers ----------
    static string S(string v) { return "\"" + Esc(v) + "\""; }
    static void F(StringBuilder s, string indent, string key, string val, bool last)
    {
        s.Append(indent + "\"" + key + "\": " + val + (last ? "\n" : ",\n"));
    }
    static void SetI32(byte[] b, int off, int v) { byte[] t = BitConverter.GetBytes(v); for (int i = 0; i < 4; i++) b[off + i] = t[i]; }
    static void SetI64(byte[] b, int off, long v) { byte[] t = BitConverter.GetBytes(v); for (int i = 0; i < 8; i++) b[off + i] = t[i]; }
    static string Esc(string s)
    {
        if (s == null) return "";
        StringBuilder r = new StringBuilder();
        foreach (char c in s)
        {
            if (c == '\\') r.Append("\\\\");
            else if (c == '"') r.Append("\\\"");
            else if (c == '\n') r.Append("\\n");
            else if (c == '\r') r.Append("\\r");
            else if (c == '\t') r.Append("\\t");
            else if (c < 0x20) r.Append("\\u" + ((int)c).ToString("x4"));
            // 非 ASCII（中文标题/图标名）一律 \u 转义 → 整段 JSON 保持纯 ASCII，
            // 避免 Godot 的 OS.execute 按本机代码页(GBK)解码 stdout 时把 UTF-8 中文打乱而破坏 JSON。
            else if (c > 0x7E) r.Append("\\u" + ((int)c).ToString("x4"));
            else r.Append(c);
        }
        return r.ToString();
    }
}
