using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// HelloNyxel —— Windows 系统托盘（任务栏右下角「通知区域」）小图标。
//
// 为什么需要一个独立进程：
//   Godot 没有任何系统托盘 API，托盘图标只能由 Windows 本身提供（Shell_NotifyIcon），
//   于是沿用本项目既有的原生调用约定（见 addons/hellonyxel_sysinfo）：
//   由 tray_icon.ps1 通过 Add-Type 运行时编译本文件，再调用 TrayIcon.Run()。
//   本文件只用 .NET 官方类型（System.Windows.Forms / System.Drawing），
//   ★ 例外：图标尺寸那两处必须 P/Invoke user32（见 TrayIconSize），与 SysInfo.exe 的窗口样式同理。
//
// ★★ 托盘图标必须「按通知区域真正要画的像素尺寸」交出去（见 MakeTrayIcon）：
//   本进程是 DPI-unaware，Explorer 在 150% 缩放下会用 24×24 画托盘图标，
//   如果我们交一张 256×256 的 HICON，就变成「由 Explorer 自己做 256→24 的缩放」——
//   它的缩放质量很差（实测换高清源反而不清晰）。正确做法是自己缩到 24×24 再交，让 Explorer 1:1 画。
//
// 「退出游戏」不是直接杀进程：
//   菜单点击 → 写一个「退出请求文件」→ 游戏侧 TrayRunner.gd 轮询到 → 走正常退出流程
//   （get_tree().quit()，保留后续"退出前存档"等钩子）。托盘自身随后由游戏侧 OS.kill 结束。
public static class TrayIcon
{
    private const string QuitLabel = "退出游戏";
    private const string OpenSettingsLabel = "打开设置";
    private const string OpenSavesLabel = "打开存档列表";
    private const string ModListLabel = "打开MOD列表";
    private const string WeatherLabel = "配置天气";
    private const string AILabel = "配置人工智能";
    private const string CalendarLabel = "打开日历";
    private const string PassthroughOffLabel = "关闭桌面穿透";
    private const string PerfBusyLabel = "性能忙闲判断";
    private const string BusyNowLabel = "现在在忙";
    private const string IdleNowLabel = "现在空闲";
    // 「进入调试模式 / 退出调试模式」：同一项的两种文案，随当前调试状态切换（见 RefreshDebugItem）。
    private const string DebugEnterLabel = "进入调试模式";
    private const string DebugExitLabel = "退出调试模式";

    private static NotifyIcon _notifier;
    private static string _requestPath = "";
    private static string _settingsRequestPath = "";
    private static string _savesRequestPath = "";
    private static string _modListRequestPath = "";
    private static string _perfBusyRequestPath = "";
    private static string _weatherRequestPath = "";
    private static string _aiRequestPath = "";
    private static string _calendarRequestPath = "";
    private static string _passthroughRequestPath = "";
    private static string _debugRequestPath = "";      // 「进入/退出调试模式」要写出的请求文件
    private static string _busyStatePath = "";        // 游戏侧写来的忙闲状态（"busy|locked" / "idle|unlocked"）
    private static string _debugStatePath = "";       // 游戏侧写来的调试状态（"on" / "off"）
    private static string _debugVisiblePath = "";     // 游戏侧写来的「是否显示调试项」（"1" / "0"）
    private static bool _showDebugItem = true;        // 是否显示「进入/退出调试模式」项（启动参数，文件缺失时兜底）
    private static string _busyNowRequestPath = "";   // 「现在在忙」要写出的请求文件
    private static string _idleNowRequestPath = "";   // 「现在空闲」要写出的请求文件
    private static int _gamePid = 0;

    // ---- 忙闲 → 托盘图标（批次 62）----
    // 空闲 = -IconPath（icon.ico），在忙 = -BusyIconPath（icon_zzz.ico）。
    // ★ 为什么由本进程换图标：托盘图标只能由持有 NotifyIcon 的进程改（Godot 没有这个 API），
    //   所以游戏侧只写 busyStatePath，本进程用 iconWatch 定时轮询并切换。
    private static string _busyIconPath = "";
    private static Icon _idleIcon;                 // 空态图标（缓存，避免每次 GetHicon 泄漏句柄）
    private static Icon _busyIcon;                 // 忙态图标（缓存；加载失败为 null）
    private static bool _iconIsBusy = false;       // 当前挂在托盘上的是哪一个（false = 空态）
    private const int IconWatchInterval = 400;     // 忙闲轮询周期（ms）
    // ★ 自己缩图时 HICON 依赖它背后的 Bitmap 存活 → 存成静态引用，绝不让 GC 回收
    private static readonly List<Bitmap> _iconKeepAlive = new List<Bitmap>();

    // 「现在在忙 / 现在空闲」两项同时只显示一项（与当前状态相反的那项），随菜单展开刷新。
    private static ToolStripMenuItem _busyNowItem;
    private static ToolStripMenuItem _idleNowItem;

    // 「进入/退出调试模式」项：显示与否由设置页开关决定；文案随当前调试状态切换。
    private static ToolStripMenuItem _debugItem;

    // 入口：建立托盘图标 + 右键菜单，然后进入消息循环（阻塞，直到退出）。
    //   iconPath            —— 托盘图标用的 PNG（游戏生成，失败则退回系统默认图标）
    //   requestPath         —— 「退出游戏」要写出的请求文件
    //   settingsRequestPath —— 「打开设置」要写出的请求文件
    //   savesRequestPath    —— 「打开存档列表」要写出的请求文件
    //   modListRequestPath  —— 「打开MOD列表」要写出的请求文件
    //   passthroughRequestPath —— 「关闭桌面穿透」要写出的请求文件
    //   perfBusyRequestPath —— 「性能忙闲判断」要写出的请求文件
    //   weatherRequestPath  —— 「配置天气」要写出的请求文件（预留，以后接 API）
    //   aiRequestPath       —— 「配置人工智能」要写出的请求文件（预留，以后接 API）
    //   calendarRequestPath —— 「打开日历」要写出的请求文件（右键 → 打开日历/日记/备忘录单页）
    //   debugRequestPath    —— 「进入/退出调试模式」要写出的请求文件
    //   busyStatePath       —— 游戏侧写来的忙闲状态文件（"busy|locked" / "idle|unlocked"）
    //   debugStatePath      —— 游戏侧写来的调试状态文件（"on" / "off"，决定那项的文案）
    //   debugVisiblePath    —— 游戏侧写来的「是否显示调试项」文件（"1" / "0"，设置页开关随时改）
    //   showDebugItem       —— 启动参数兜底（文件缺失时用它；0=隐藏）
    //   busyNowRequestPath  —— 「现在在忙」要写出的请求文件
    //   idleNowRequestPath  —— 「现在空闲」要写出的请求文件
    //   gamePid             —— 游戏进程 PID；为 0 表示不监视（监视用于游戏崩溃时自动收掉托盘）
    //   autoClickSeconds    —— >0 时 N 秒后自动点一次「退出游戏」（端到端自测钩子，正常为 0）
    //   busyIconPath        —— 「在忙」时用的 .ico（icon_zzz.ico）；空则忙闲不换图标
    public static void Run(string iconPath, string requestPath, string settingsRequestPath, string savesRequestPath, string modListRequestPath, string passthroughRequestPath, string perfBusyRequestPath, string weatherRequestPath, string aiRequestPath, string calendarRequestPath, string debugRequestPath, string busyStatePath, string debugStatePath, string debugVisiblePath, int showDebugItem, string busyNowRequestPath, string idleNowRequestPath, int gamePid, int autoClickSeconds, string busyIconPath)
    {
        _requestPath = requestPath;
        _settingsRequestPath = settingsRequestPath;
        _savesRequestPath = savesRequestPath;
        _modListRequestPath = modListRequestPath;
        _passthroughRequestPath = passthroughRequestPath;
        _perfBusyRequestPath = perfBusyRequestPath;
        _weatherRequestPath = weatherRequestPath;
        _aiRequestPath = aiRequestPath;
        _calendarRequestPath = calendarRequestPath;
        _debugRequestPath = debugRequestPath;
        _busyStatePath = busyStatePath;
        _debugStatePath = debugStatePath;
        _debugVisiblePath = debugVisiblePath;
        _showDebugItem = showDebugItem != 0;
        _busyNowRequestPath = busyNowRequestPath;
        _idleNowRequestPath = idleNowRequestPath;
        _gamePid = gamePid;
        _busyIconPath = busyIconPath;

        ToolStripMenuItem quitItem;
        _notifier = BuildNotifier(iconPath, out quitItem);
        if (_notifier == null)
        {
            return;
        }
        _notifier.Visible = true;
        Log("READY");   // 托盘已在通知区域出现（此文件即诊断日志，见 TrayRunner.gd）

        // 忙闲 → 图标：先按状态文件当前的忙闲套一次，之后由 iconWatch 轮询切换。
        // ★ 游戏侧 BusyState 在启动时就会写好 busyStatePath，所以这里一般能拿到正确初值。
        ApplyBusyIcon(ReadBusyFlag(), true);
        System.Windows.Forms.Timer iconWatch = new System.Windows.Forms.Timer();
        iconWatch.Interval = IconWatchInterval;
        iconWatch.Tick += delegate { ApplyBusyIcon(ReadBusyFlag(), false); };
        iconWatch.Start();

        // 看门狗：游戏进程先没了（崩溃 / 被强杀）→ 托盘自行退出，避免通知区域残留图标。
        System.Windows.Forms.Timer watchdog = new System.Windows.Forms.Timer();
        watchdog.Interval = 1000;
        watchdog.Tick += delegate { if (!GameAlive()) Application.Exit(); };
        watchdog.Start();

        if (autoClickSeconds > 0)
        {
            System.Windows.Forms.Timer auto = new System.Windows.Forms.Timer();
            auto.Interval = Math.Max(autoClickSeconds, 1) * 1000;
            auto.Tick += delegate { auto.Stop(); quitItem.PerformClick(); };
            auto.Start();
        }

        Application.Run();   // 消息循环：托盘的右键菜单、点击事件都在这里派发

        // 走到这里说明消息循环结束（正常退出，或看门狗判定游戏已死）。
        // 托盘是独立进程，Godot 侧拿不到它的 stdout，日志是唯一的退出证据。
        Log("EXIT");
        watchdog.Stop();
        iconWatch.Stop();
        _notifier.Visible = false;   // 必须先隐藏再 Dispose，否则通知区域会残留幽灵图标
        _notifier.Dispose();
        _notifier = null;
    }

    // ---------------- 独立 EXE 入口（批次 5 / P0-C / C1） ----------------
    //
    // 为什么要有这个入口：原先托盘是靠 `powershell.exe -STA -File tray_icon.ps1` 起的，
    // 而一个常驻 PowerShell 宿主本身就要吃 ~103 MB（System.Management.Automation + CLR +
    // WinForms + Drawing），托盘真正需要的却只是 WinForms 的消息循环。
    // 把本文件预编译成**独立 EXE** 后：没有 PS 宿主、没有每次现编译本文件、也没有 conhost。
    //
    // ★ 参数与 tray_icon.ps1 **完全同名**，Godot 侧（TrayRunner._launch_tray）两条路径
    //   共用同一套参数拼装 —— 具名传参的约定不变。
    // ★ 必须 [STAThread]：NotifyIcon 及其消息循环要求单线程单元（与 PS 侧的 -STA 等价）。
    // ★ 入口唯一：本文件只有一个 Main。tray_icon.ps1 走的是 Add-Type 后直调
    //   TrayIcon.Run()/SelfTest()，不受影响，继续作为 EXE 缺失/失败时的兜底。
    // ★ 语言级别只有 C# 5（Add-Type 的 CodeDomProvider 用旧编译器）→ 不用局部函数、
    //   字符串插值、?. 之类语法，参数解析写成下面几个静态小助手。
    [STAThread]
    public static void Main(string[] args)
    {
        string requestPath = Arg(args, "-RequestPath");
        if (HasArg(args, "-SelfTest"))
        {
            string r = SelfTest(Arg(args, "-IconPath"), requestPath);
            try { Console.Out.Write("SELFTEST:" + r + Environment.NewLine); }
            catch { }
            return;
        }
        try
        {
            Run(
                Arg(args, "-IconPath"),
                requestPath,
                Arg(args, "-SettingsRequestPath"),
                Arg(args, "-SavesRequestPath"),
                Arg(args, "-ModListRequestPath"),
                Arg(args, "-PassthroughRequestPath"),
                Arg(args, "-PerfBusyRequestPath"),
                Arg(args, "-WeatherRequestPath"),
                Arg(args, "-AIRequestPath"),
                Arg(args, "-CalendarRequestPath"),
                Arg(args, "-DebugRequestPath"),
                Arg(args, "-BusyStatePath"),
                Arg(args, "-DebugStatePath"),
                Arg(args, "-DebugVisiblePath"),
                ArgInt(args, "-ShowDebugItem"),
                Arg(args, "-BusyNowRequestPath"),
                Arg(args, "-IdleNowRequestPath"),
                ArgInt(args, "-GamePid"),
                ArgInt(args, "-AutoClickSeconds"),
                Arg(args, "-BusyIconPath"));
        }
        catch (Exception ex)
        {
            // 与 tray_icon.ps1 的 catch 分支保持同样的落盘格式，便于同一套排查手法。
            string msg = ex.ToString().Replace("\r", " ").Replace("\n", " ");
            try { File.AppendAllText(requestPath + ".log", "ERROR: " + msg + Environment.NewLine); }
            catch { }
            try { Console.Out.Write("TRAY_ERROR:" + msg + Environment.NewLine); }
            catch { }
        }
    }

    // 取具名参数的值；参数名大小写不敏感，找不到返回 ""。
    private static string Arg(string[] args, string name)
    {
        if (args == null)
        {
            return "";
        }
        for (int i = 0; i + 1 < args.Length; i++)
        {
            if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }
        return "";
    }

    // 是否存在某个开关参数（如 -SelfTest）
    private static bool HasArg(string[] args, string name)
    {
        if (args == null)
        {
            return false;
        }
        for (int i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    private static int ArgInt(string[] args, string name)
    {
        int v = 0;
        int.TryParse(Arg(args, name), out v);
        return v;
    }

    // 自测：构建托盘与右键菜单，以编程方式触发一次「退出游戏」，
    // 检查请求文件是否被写出。返回 "ok" 或失败说明。
    public static string SelfTest(string iconPath, string requestPath)
    {
        _requestPath = requestPath;
        try { if (File.Exists(requestPath)) { File.Delete(requestPath); } }
        catch { }

        ToolStripMenuItem quitItem;
        NotifyIcon ni = BuildNotifier(iconPath, out quitItem);
        if (ni == null || quitItem == null)
        {
            return "构建托盘失败";
        }

        ni.Visible = true;          // 真正建一次图标，确认 PNG 能被读成 Icon
        quitItem.PerformClick();    // 走与真实点击完全相同的处理链路
        bool written = File.Exists(requestPath);
        ni.Visible = false;
        ni.Dispose();
        Log(written ? "SELFTEST_OK" : "SELFTEST_FAIL");
        return written ? "ok" : "点击「退出游戏」后未生成请求文件";
    }

    // ---------------- 内部 ----------------

    // 追加一行诊断日志到 `<requestPath>.log`（托盘是独立进程，Godot 侧拿不到它的 stdout）。
    private static void Log(string line)
    {
        try
        {
            File.AppendAllText(_requestPath + ".log", line + Environment.NewLine);
        }
        catch { }
    }

    private static NotifyIcon BuildNotifier(string iconPath, out ToolStripMenuItem quitItem)
    {
        quitItem = new ToolStripMenuItem(QuitLabel);
        quitItem.Click += delegate { RequestQuit(); };

        // 打开设置（顶层，不再做次级菜单）：右键托盘 → 打开设置
        ToolStripMenuItem openSettingsItem = new ToolStripMenuItem(OpenSettingsLabel);
        openSettingsItem.Click += delegate { RequestSettings(); };

        // 打开存档列表（顶层，不再做次级菜单）：右键托盘 → 打开存档列表
        ToolStripMenuItem openSavesItem = new ToolStripMenuItem(OpenSavesLabel);
        openSavesItem.Click += delegate { RequestSaves(); };

        // 打开MOD列表（顶层）：右键托盘 → 打开MOD列表
        ToolStripMenuItem modListItem = new ToolStripMenuItem(ModListLabel);
        modListItem.Click += delegate { RequestModList(); };

        // 配置天气（预留，以后接 API）：右键托盘 → 配置天气
        // 打开天气配置占位页面（仅容器，业务未接入）
        ToolStripMenuItem weatherItem = new ToolStripMenuItem(WeatherLabel);
        weatherItem.Click += delegate { RequestWeather(); };

        // 配置人工智能（预留，以后接 API）：右键托盘 → 配置人工智能
        // 打开人工智能配置占位页面（仅容器，业务未接入）
        ToolStripMenuItem aiItem = new ToolStripMenuItem(AILabel);
        aiItem.Click += delegate { RequestAI(); };

        // 打开日历（与设置/存档/天气/AI 同级的独立项）：右键托盘 → 打开日历/日记/备忘录单页
        ToolStripMenuItem calendarItem = new ToolStripMenuItem(CalendarLabel);
        calendarItem.Click += delegate { RequestCalendar(); };

        // 进入/退出调试模式：显隐由设置页开关（_showDebugItem）决定，
        // 文案随当前调试状态切换、状态由游戏侧写进 debugStatePath（菜单展开时刷新）。
        _debugItem = new ToolStripMenuItem(DebugEnterLabel);
        _debugItem.Click += delegate { RequestToggleDebug(); };

        // 性能忙闲判断（与设置/存档/天气/AI 同级的独立项）：右键托盘 → 性能忙闲判断
        // 打开加权分数判断面板（CPU/内存/显存 判断线 + 权重 → 总分 → 判定在忙）
        ToolStripMenuItem perfBusyItem = new ToolStripMenuItem(PerfBusyLabel);
        perfBusyItem.Click += delegate { RequestPerfBusy(); };

        // 「现在在忙 / 现在空闲」：手动切换忙闲，忽略分数与阈值。
        // ★ 两项**同时只显示一项**——与当前状态相反的那项（在忙 → 显示「现在空闲」）。
        //   当前状态由游戏侧写进 busyStatePath，菜单**展开时**读它并刷新（见 RefreshBusyItems）。
        _busyNowItem = new ToolStripMenuItem(BusyNowLabel);
        _busyNowItem.Click += delegate { RequestBusyNow(); };
        _idleNowItem = new ToolStripMenuItem(IdleNowLabel);
        _idleNowItem.Click += delegate { RequestIdleNow(); };

        // 关闭桌面穿透（与「退出游戏」同级，位于其上方）：右键托盘 → 关闭桌面穿透
        // （开启穿透用 Tab 键；关闭统一走这里，避免与输入法 Ctrl/Shift 组合冲突）
        ToolStripMenuItem passthroughItem = new ToolStripMenuItem(PassthroughOffLabel);
        passthroughItem.Click += delegate { RequestPassthroughOff(); };

        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add(openSettingsItem);
        menu.Items.Add(openSavesItem);
        menu.Items.Add(modListItem);
        menu.Items.Add(weatherItem);
        menu.Items.Add(aiItem);
        menu.Items.Add(calendarItem);
        menu.Items.Add(perfBusyItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_debugItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_busyNowItem);
        menu.Items.Add(_idleNowItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(passthroughItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(quitItem);

        // 每次展开菜单都刷新调试项显隐/文案 + 忙闲两项（状态可能刚被改过）
        menu.Opening += delegate { RefreshDebugItem(); RefreshBusyItems(); };

        NotifyIcon ni = new NotifyIcon();
        // 双图标：空闲 = iconPath（icon.ico），在忙 = busyIconPath（icon_zzz.ico）。
        // ★ 两张都**按托盘真正要画的像素尺寸**做好并缓存（见 MakeTrayIcon），
        //   之后只做指针替换（换图标不重新解码/缩放文件）。
        int tray_size = TrayIconSize();
        Log("ICONSIZE tray=" + tray_size + "x" + tray_size);
        _idleIcon = MakeTrayIcon(iconPath, tray_size, "idle");
        _busyIcon = string.IsNullOrEmpty(_busyIconPath) ? null : MakeTrayIcon(_busyIconPath, tray_size, "busy");
        ni.Icon = _idleIcon != null ? _idleIcon : SystemIcons.Application;
        ni.Text = "HelloNyxel";     // 悬停提示（Windows 上限 63 字符）；随后由 ApplyBusyIcon 带状态刷新
        ni.ContextMenuStrip = menu;
        return ni;
    }

    // ---------------- 图标尺寸 / 缩放（批次 63） ----------------
    //
    // ★★ 为什么不能把源图直接交给 Explorer：
    //    通知区域里图标是按「小图标尺寸」画的（100% DPI = 16、125% = 20、150% = 24、200% = 32）。
    //    如果交一张 256×256，就变成 Explorer 自己去做 256→24 的缩放，它的缩放质量很差
    //    → 换更高分辨率的源图**完全看不出变清晰**（这正是本批次要修的问题）。
    //    正确做法：我们自己缩到托盘真正要画的那个尺寸，Explorer 于是 1:1 绘制。
    //
    // ★ 本进程是 DPI-unaware（Add-Type 编出来的 EXE 没有 DPI 清单），
    //   直接查 SM_CXSMICON 永远得到 16（DPI 虚拟化）。所以查之前**临时**把本线程
    //   切到 SYSTEM_AWARE，查完立刻切回去 —— 只影响这一瞬间，之后的窗口/菜单仍是原来的 unaware 行为。
    private const int SM_CXSMICON = 49;

    [DllImport("user32.dll")]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    private static readonly IntPtr DPI_AWARENESS_CONTEXT_SYSTEM_AWARE = new IntPtr(-2);

    // 通知区域图标的真实像素尺寸。查询链：线程 DPI 上下文 → 注册表 AppliedDPI → 16。
    private static int TrayIconSize()
    {
        int size = 0;
        try
        {
            IntPtr prev = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_SYSTEM_AWARE);
            try { size = GetSystemMetrics(SM_CXSMICON); }
            finally { SetThreadDpiAwarenessContext(prev); }
        }
        catch { }
        if (size <= 0)
        {
            int dpi = 96;
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop\WindowMetrics"))
                {
                    if (k != null)
                    {
                        object v = k.GetValue("AppliedDPI");
                        if (v != null) { dpi = Convert.ToInt32(v); }
                    }
                }
            }
            catch { }
            size = (int)Math.Round(16.0 * dpi / 96.0);
        }
        if (size < 16) { size = 16; }
        if (size > 256) { size = 256; }
        return size;
    }

    // .ico 目录里的一个图层（只读文件头，不做任何解码）。
    private class IcoLayer
    {
        public int Size;      // 边长（ICO 目录里 0 表示 256）
        public int Bytes;     // 该层数据字节数
        public int Offset;    // 该层数据在文件里的偏移
        public bool Png;      // 该层是 PNG 压缩（首批 256×256 高清图标都是这种）
    }

    // 读 .ico 目录。
    // ★ 必须自己解：.NET 的 Icon.ToBitmap() 会把每个图层**当 DIB** 去解析，
    //   遇到 PNG 压缩层直接抛 ArgumentOutOfRangeException（"请求的范围扩展超过了数组的结尾"）
    //   —— 这正是批次 63「换高清图标反而全挂」的真凶。失败返回 null。
    private static List<IcoLayer> IcoLayers(string path)
    {
        try
        {
            byte[] b = File.ReadAllBytes(path);
            if (b.Length < 6 || b[0] != 0 || b[1] != 0 || b[2] != 1 || b[3] != 0) { return null; }
            int n = b[4] | (b[5] << 8);
            if (n <= 0 || n > 256) { return null; }
            List<IcoLayer> list = new List<IcoLayer>();
            for (int i = 0; i < n; i++)
            {
                int off = 6 + i * 16;
                if (off + 16 > b.Length) { break; }
                int w = b[off];
                int bytes = b[off + 8] | (b[off + 9] << 8) | (b[off + 10] << 16) | (b[off + 11] << 24);
                int dataOff = b[off + 12] | (b[off + 13] << 8) | (b[off + 14] << 16) | (b[off + 15] << 24);
                if (bytes <= 0 || dataOff < 0 || dataOff + bytes > b.Length) { continue; }
                IcoLayer e = new IcoLayer();
                e.Size = (w == 0) ? 256 : w;
                e.Bytes = bytes;
                e.Offset = dataOff;
                e.Png = (b[dataOff] == 0x89 && b[dataOff + 1] == 0x50 && b[dataOff + 2] == 0x4E && b[dataOff + 3] == 0x47);
                list.Add(e);
            }
            return list.Count > 0 ? list : null;
        }
        catch { return null; }
    }

    // 把某一层解成位图。
    //   PNG 层 → 直接交给 GDI+ 解 PNG（★ 绝不能走 Icon.ToBitmap()，见 IcoLayers 注释）
    //   DIB 层 → 包成单图层 .ico 再走 Icon.ToBitmap()（.NET 对 DIB 的解析是正常的）
    // ★ 返回值是**独立位图**（不依赖任何流/临时文件的生命期）。
    private static Bitmap DecodeLayer(string path, IcoLayer e)
    {
        if (e.Png)
        {
            using (MemoryStream ms = new MemoryStream(File.ReadAllBytes(path), e.Offset, e.Bytes, false))
            using (Bitmap tmp = new Bitmap(ms))
            {
                return tmp.Clone(new Rectangle(0, 0, tmp.Width, tmp.Height), PixelFormat.Format32bppArgb);
            }
        }
        byte[] b = File.ReadAllBytes(path);
        byte[] chunk = new byte[e.Bytes];
        Array.Copy(b, e.Offset, chunk, 0, e.Bytes);
        using (MemoryStream one = new MemoryStream(BuildSingleLayerIco(e.Size, chunk)))
        using (Icon ic = new Icon(one))
        {
            return ic.ToBitmap();
        }
    }

    // 用一层数据拼一个「只有一个图层」的最小 .ico（给 DecodeLayer 的 DIB 分支用）。
    private static byte[] BuildSingleLayerIco(int size, byte[] data)
    {
        MemoryStream ms = new MemoryStream();
        int wh = (size >= 256) ? 0 : size;
        ms.Write(new byte[] { 0, 0, 1, 0, 1, 0 }, 0, 6);   // 保留×2 + 类型(1=图标) + 图层数(1)
        ms.WriteByte((byte)wh);          // 宽
        ms.WriteByte((byte)wh);          // 高
        ms.WriteByte(0);                 // 调色板数
        ms.WriteByte(0);                 // 保留
        ms.WriteByte(0); ms.WriteByte(1);    // 色彩平面
        ms.WriteByte(32); ms.WriteByte(0);   // 位深
        WriteI32(ms, data.Length);       // bytesInRes
        WriteI32(ms, 22);                // 数据偏移（6 + 16）
        ms.Write(data, 0, data.Length);
        return ms.ToArray();
    }

    private static void WriteI32(Stream s, int v)
    {
        s.WriteByte((byte)(v & 0xFF));
        s.WriteByte((byte)((v >> 8) & 0xFF));
        s.WriteByte((byte)((v >> 16) & 0xFF));
        s.WriteByte((byte)((v >> 24) & 0xFF));
    }

    private static string Msg(Exception ex)
    {
        return (ex.Message == null ? "" : ex.Message).Replace("\r", " ").Replace("\n", " ");
    }

    // 造一个「恰好是托盘要画尺寸」的 HICON：
    //   ① 源层本来就是目标尺寸 → 原样搬（零重采样，最锐）
    //   ② 否则自己用 GDI+ HighQualityBicubic 缩到目标尺寸（远好于把大图丢给 Explorer 缩）
    //   ③ 多层 .ico 里优先挑「不小于目标的最小层」（缩放比最小、最锐）
    // 任何失败返回 null（调用方兜底到系统默认图标）。
    private static Icon MakeTrayIcon(string iconPath, int size, string tag)
    {
        if (string.IsNullOrEmpty(iconPath) || !File.Exists(iconPath))
        {
            Log("ICONFIT " + tag + " fail (path missing)");
            return null;
        }
        try
        {
            // 非 .ico（TrayRunner 的兜底 PNG）→ GDI+ 直接读
            if (!iconPath.EndsWith(".ico", StringComparison.OrdinalIgnoreCase))
            {
                using (Bitmap plain = new Bitmap(iconPath))
                {
                    return ToIcon(plain, size, tag, "png");
                }
            }

            List<IcoLayer> layers = IcoLayers(iconPath);
            if (layers != null)
            {
                IcoLayer pick = null;
                foreach (IcoLayer e in layers)
                {
                    if (e.Size >= size && (pick == null || e.Size < pick.Size)) { pick = e; }
                }
                if (pick == null)
                {
                    foreach (IcoLayer e in layers)
                    {
                        if (pick == null || e.Size > pick.Size) { pick = e; }
                    }
                }
                if (pick != null)
                {
                    using (Bitmap src = DecodeLayer(iconPath, pick))
                    {
                        return ToIcon(src, size, tag, pick.Png ? "ico-png" : "ico-dib");
                    }
                }
            }

            // 目录读不出（畸形 ico）→ 老办法交给 GDI 自带的 Icon 解析（仅 DIB 层有效）
            using (Icon master = new Icon(iconPath))
            using (Bitmap big = master.ToBitmap())
            {
                return ToIcon(big, size, tag, "ico-fallback");
            }
        }
        catch (Exception ex)
        {
            Log("ICONFIT " + tag + " fail " + Msg(ex));
            return null;
        }
    }

    // 把任意位图转成「目标尺寸」的 HICON。
    //   ★ 大比例缩小时**先逐次减半**：256→24 一次 bicubic 会丢细节+出锯齿，逐次减半后明显更锐
    //   ★ SourceCopy + TileFlipXY：正确保留 alpha，且不会因边缘透明像素在采样时把颜色拖暗
    //   ★ 结果存进静态表，保证 HICON 背后的 Bitmap 不被 GC 回收
    private static Icon ToIcon(Bitmap src, int size, string tag, string how)
    {
        Bitmap work = src;
        bool workIsTemp = false;
        while (work.Width >= size * 2 && work.Height >= size * 2 && work.Width > 2 && work.Height > 2)
        {
            int nw = work.Width / 2;
            int nh = work.Height / 2;
            Bitmap step = new Bitmap(nw, nh, PixelFormat.Format32bppArgb);
            Draw(work, step, nw, nh, false);
            if (workIsTemp) { work.Dispose(); }
            work = step;
            workIsTemp = true;
        }
        bool same = (work.Width == size && work.Height == size);
        Bitmap outb = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        Draw(work, outb, size, size, same);
        if (workIsTemp) { work.Dispose(); }
        _iconKeepAlive.Add(outb);
        Log("ICONFIT " + tag + " src=" + src.Width + "x" + src.Height + " -> " + size + "x" + size + " " + how + (same ? " exact" : " bicubic"));
        return Icon.FromHandle(outb.GetHicon());
    }

    // 把 src 画进 dst（dst 尺寸已定）。same=true → 原样搬（SourceCopy，零重采样）；否则高质量重采样。
    private static void Draw(Bitmap src, Bitmap dst, int w, int h, bool same)
    {
        using (Graphics g = Graphics.FromImage(dst))
        {
            g.CompositingMode = CompositingMode.SourceCopy;
            if (same)
            {
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
            }
            else
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.SmoothingMode = SmoothingMode.HighQuality;
                g.CompositingQuality = CompositingQuality.HighQuality;
            }
            ImageAttributes ia = new ImageAttributes();
            ia.SetWrapMode(WrapMode.TileFlipXY);
            g.DrawImage(src, new Rectangle(0, 0, w, h), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel, ia);
        }
    }

    // 读游戏侧写的忙闲状态文件（busyStatePath），只取「是否在忙」这一位。
    // 文件格式："busy|locked" / "idle|unlocked"；缺失或损坏 → 空闲（保守，不误报在忙）。
    private static bool ReadBusyFlag()
    {
        try
        {
            if (!string.IsNullOrEmpty(_busyStatePath) && File.Exists(_busyStatePath))
            {
                string text = File.ReadAllText(_busyStatePath).Trim();
                string[] parts = text.Split('|');
                if (parts.Length >= 1 && parts[0].Trim().Length > 0)
                {
                    return parts[0].Trim().Equals("busy", StringComparison.OrdinalIgnoreCase);
                }
            }
        }
        catch { }
        return false;
    }

    // 按忙闲切托盘图标（+ 悬停提示）。
    // ★ force=true 时无条件套用一次（启动用）；之后每次 tick 只在状态真翻面时才换
    //   ——换图标会让通知区域闪一下，不该每秒无脑刷。
    // ★ 忙态图标加载失败 → 退回空态图标（绝不给 NotifyIcon 设 null，否则通知区域会空一块）。
    private static void ApplyBusyIcon(bool busy, bool force)
    {
        if (_notifier == null)
        {
            return;
        }
        if (!force && busy == _iconIsBusy)
        {
            return;
        }
        Icon want = busy ? _busyIcon : _idleIcon;
        if (want == null)
        {
            want = _idleIcon;
            busy = false;
        }
        if (want == null)
        {
            return;   // 连空态图标都没有 → 保持系统默认图标不动
        }
        _notifier.Icon = want;
        _notifier.Text = busy ? "HelloNyxel（在忙）" : "HelloNyxel（空闲）";
        _iconIsBusy = busy;
        Log(busy ? "ICON busy" : "ICON idle");
    }

    // 写出退出请求文件（内容不重要，存在即代表"请求退出"）。
    private static void RequestQuit()
    {
        try
        {
            string dir = Path.GetDirectoryName(_requestPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(_requestPath, "quit");
        }
        catch { }
    }

    // 写出「打开设置」请求文件（存在即代表"请求打开设置页面"）。
    private static void RequestSettings()
    {
        try
        {
            string dir = Path.GetDirectoryName(_settingsRequestPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(_settingsRequestPath, "settings");
        }
        catch { }
    }

    // 写出「打开存档列表」请求文件（存在即代表"请求打开存档列表页面"）。
    private static void RequestSaves()
    {
        try
        {
            string dir = Path.GetDirectoryName(_savesRequestPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(_savesRequestPath, "saves");
        }
        catch { }
    }

    // 写出「打开MOD列表」请求文件（存在即代表"请求打开MOD列表页面"）。
    private static void RequestModList()
    {
        try
        {
            string dir = Path.GetDirectoryName(_modListRequestPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(_modListRequestPath, "mod_list");
        }
        catch { }
    }

    // 写出「关闭桌面穿透」请求文件（存在即代表"请求关闭桌面穿透"）。
    private static void RequestPassthroughOff()
    {
        try
        {
            string dir = Path.GetDirectoryName(_passthroughRequestPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(_passthroughRequestPath, "passthrough_off");
        }
        catch { }
    }

    // 写出「性能忙闲判断」请求文件（存在即代表"请求打开性能忙闲判断面板"）。
    private static void RequestPerfBusy()
    {
        try
        {
            string dir = Path.GetDirectoryName(_perfBusyRequestPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(_perfBusyRequestPath, "perf_busy");
        }
        catch { }
    }

    // 刷新「进入/退出调试模式」项：显隐由设置页开关决定，文案由游戏侧写来的调试状态决定。
    // 状态文件格式："on" / "off"；文件缺失或损坏 → 当作「未调试」（显示「进入调试模式」）。
    // 显隐文件格式："1" / "0"；文件缺失 → 退回启动参数（_showDebugItem）。
    // ★ 每次展开菜单都重读，所以设置页开关**当场生效**，无需重启托盘进程。
    private static void RefreshDebugItem()
    {
        if (_debugItem == null)
        {
            return;
        }
        // 显隐：优先读状态文件（设置页可随时改），文件缺失时退回启动参数
        bool visible = _showDebugItem;
        try
        {
            if (!string.IsNullOrEmpty(_debugVisiblePath) && File.Exists(_debugVisiblePath))
            {
                visible = File.ReadAllText(_debugVisiblePath).Trim() != "0";
            }
        }
        catch { }
        _debugItem.Visible = visible;
        if (!visible)
        {
            return;
        }
        bool on = false;
        try
        {
            if (!string.IsNullOrEmpty(_debugStatePath) && File.Exists(_debugStatePath))
            {
                string text = File.ReadAllText(_debugStatePath).Trim();
                on = text.Equals("on", StringComparison.OrdinalIgnoreCase);
            }
        }
        catch { }
        // 当前在调试 → 提供「退出调试模式」；否则提供「进入调试模式」
        _debugItem.Text = on ? DebugExitLabel : DebugEnterLabel;
        _debugItem.ToolTipText = on ? "退出调试模式（隐藏调试面板与调试专用操作）" : "进入调试模式（显示调试面板与调试专用操作）";
    }

    // 写出「进入/退出调试模式」请求文件（存在即代表"请求切换调试模式"，切换方向由游戏侧当前状态决定）。
    private static void RequestToggleDebug()
    {
        WriteFlag(_debugRequestPath, "toggle_debug");
    }

    // 读游戏侧写的忙闲状态文件，据此决定「现在在忙 / 现在空闲」显示哪一项、是否可点。
    // 文件格式："busy|locked" / "idle|unlocked"；文件缺失或损坏 → 当作「空闲、未锁定」。
    // locked = 定时时段内已手动切换过一次 → 本时段剩余时间禁止再切（两项都置灰）。
    private static void RefreshBusyItems()
    {
        if (_busyNowItem == null || _idleNowItem == null)
        {
            return;
        }
        bool busy = false;
        bool locked = false;
        try
        {
            if (!string.IsNullOrEmpty(_busyStatePath) && File.Exists(_busyStatePath))
            {
                string text = File.ReadAllText(_busyStatePath).Trim();
                string[] parts = text.Split('|');
                if (parts.Length >= 1)
                {
                    busy = parts[0].Trim().Equals("busy", StringComparison.OrdinalIgnoreCase);
                }
                if (parts.Length >= 2)
                {
                    locked = parts[1].Trim().Equals("locked", StringComparison.OrdinalIgnoreCase);
                }
            }
        }
        catch { }

        // 只显示与当前状态相反的那一项（当前在忙 → 只能点「现在空闲」）
        _busyNowItem.Visible = !busy;
        _idleNowItem.Visible = busy;
        _busyNowItem.Enabled = !locked;
        _idleNowItem.Enabled = !locked;
        _busyNowItem.ToolTipText = locked ? "本时段已切换过，时段结束前不可再切" : "忽略分数与阈值，直接切为在忙";
        _idleNowItem.ToolTipText = locked ? "本时段已切换过，时段结束前不可再切" : "忽略分数与阈值，直接切为空闲";
    }

    // 写出「现在在忙」请求文件（存在即代表"请求切为在忙"，忽略分数与阈值）。
    private static void RequestBusyNow()
    {
        WriteFlag(_busyNowRequestPath, "busy_now");
    }

    // 写出「现在空闲」请求文件（存在即代表"请求切为空闲"，忽略分数与阈值）。
    private static void RequestIdleNow()
    {
        WriteFlag(_idleNowRequestPath, "idle_now");
    }

    // 写一个「存在即请求」的旗标文件（各请求文件约定一致：内容不重要）。
    private static void WriteFlag(string path, string content)
    {
        try
        {
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(path, content);
        }
        catch { }
    }

    // 写出「配置天气」请求文件（存在即代表"请求打开配置天气页面"，业务预留）。
    private static void RequestWeather()
    {
        try
        {
            string dir = Path.GetDirectoryName(_weatherRequestPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(_weatherRequestPath, "weather");
        }
        catch { }
    }

    // 写出「配置人工智能」请求文件（存在即代表"请求打开配置人工智能页面"，业务预留）。
    private static void RequestAI()
    {
        try
        {
            string dir = Path.GetDirectoryName(_aiRequestPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(_aiRequestPath, "ai");
        }
        catch { }
    }

    // 写出「打开日历」请求文件（存在即代表"请求打开日历/日记/备忘录单页"）。
    private static void RequestCalendar()
    {
        try
        {
            string dir = Path.GetDirectoryName(_calendarRequestPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            File.WriteAllText(_calendarRequestPath, "calendar");
        }
        catch { }
    }

    private static bool GameAlive()
    {
        if (_gamePid <= 0)
        {
            return true;    // 未提供 PID → 不监视，托盘一直存活
        }
        try
        {
            using (Process p = Process.GetProcessById(_gamePid))
            {
                return !p.HasExited;
            }
        }
        catch
        {
            return false;   // 进程已不存在
        }
    }
}
