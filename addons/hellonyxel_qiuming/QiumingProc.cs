// QiumingProc.cs -- thin CLI wrapper around qiumingdll.dll for HelloNyxel.
//
// Purpose: expose QiumingDLL's process-detection (procdetect) module to GDScript
// via OS.execute, exactly like the existing SysInfo.exe pattern. This takes over
// the "which software is running" part of player-info reading (QiumingDLL procdetect
// replaces the old PowerShell Get-Process enumeration).
//
// Build:  powershell -NoProfile -ExecutionPolicy Bypass -File build_qiuming.ps1
// Output: QiumingProc.exe  (keep it in the SAME folder as qiumingdll.dll)
//
// CLI:
//   init            -> warm-up qiumingdll_init() (idempotent; non-fatal)
//   free            -> free DLL (best-effort)
//   version         -> print DLL version (used by qiuming_link.gd to probe availability)
//   proc <name>     -> RUNNING / NOTRUNNING / ERR:proc=<rc>
//   procs a|b|c     -> one "name:1"/"name:0" line per name
//
// procdetect notes (from https://qiumingdll.genouka.top/):
//   * "进程检测 procdetect ... 无需初始化" -- NO module-specific init() is needed,
//     unlike winsplit/volume/webview. So we do NOT call a qiumingdll_procdetect_init().
//   * qiumingdll_init() is the global one-time function binder (idempotent, safe to
//     repeat). We attempt it in EnsureInit() but treat a non-zero result as non-fatal,
//     because the docs say procdetect works without init.
//   * The "detect arbitrary process by name" export name is INFERRED from the
//     documented qiumingdll_procdetect_cheatengine() convention as
//     qiumingdll_procdetect_exe(string) -> 1 running / 0 not. CONFIRM this from the
//     shipped Godot C# binding (QiumingDLL.cs in the package) and fix the EntryPoint
//     below if different. If the name is wrong, the P/Invoke throws
//     EntryPointNotFoundException -> Safe() catches it -> returns -1 -> GDScript
//     falls back to the existing PowerShell process enumeration. So a wrong guess is
//     safe (worst case: no QiumingDLL speedup), never a crash.

using System;
using System.Runtime.InteropServices;
using System.Text;

public class QiumingProc
{
    // ---- DLL imports (names per QiumingDLL GML API) ----
    [DllImport("qiumingdll", CharSet = CharSet.Ansi)]
    static extern int qiumingdll_init();

    [DllImport("qiumingdll", CharSet = CharSet.Ansi)]
    static extern int qiumingdll_free();

    [DllImport("qiumingdll", CharSet = CharSet.Ansi)]
    static extern int qiumingdll_get_version(StringBuilder outBuf, int bufLen);

    [DllImport("qiumingdll", CharSet = CharSet.Ansi)]
    static extern int qiumingdll_procdetect_cheatengine();

    // Detect arbitrary process by name. INFERRED name -- confirm from shipped binding.
    [DllImport("qiumingdll", CharSet = CharSet.Ansi, EntryPoint = "qiumingdll_procdetect_exe")]
    static extern int qiumingdll_procdetect_exe([MarshalAs(UnmanagedType.LPStr)] string exeName);

    // Run fn(); any native/DLL failure is caught so the CLI reports ERR instead of crashing.
    static int Safe(Func<int> fn)
    {
        try { return fn(); }
        catch (Exception e)
        {
            Console.WriteLine("ERR:" + e.GetType().Name + ":" + e.Message);
            return -1;
        }
    }

    // Global function binder (idempotent per docs). Non-fatal for procdetect.
    static int EnsureInit()
    {
        return Safe(() => qiumingdll_init());
    }

    // The actual procdetect probe. Returns 1=running / 0=not / -1=error.
    static int Probe(string name)
    {
        return Safe(() => qiumingdll_procdetect_exe(name));
    }

    static int Main(string[] args)
    {
        if (args.Length == 0) { Console.WriteLine("ERR:noargs"); return 2; }
        string cmd = args[0].ToLowerInvariant();

        if (cmd == "init")
        {
            int r = EnsureInit();
            Console.WriteLine(r == 0 ? "OK" : "ERR:init=" + r);
            return 0; // init is best-effort / non-fatal
        }
        if (cmd == "free")
        {
            int r = Safe(() => qiumingdll_free());
            Console.WriteLine(r == 0 ? "OK" : "ERR:free=" + r);
            return 0; // free is best-effort
        }
        if (cmd == "version")
        {
            var sb = new StringBuilder(64);
            int r = Safe(() => qiumingdll_get_version(sb, sb.Capacity));
            Console.WriteLine(r == 0 ? sb.ToString() : "ERR:version=" + r);
            return r == 0 ? 0 : 1;
        }
        if (cmd == "proc")
        {
            if (args.Length < 2) { Console.WriteLine("ERR:noproc"); return 2; }
            EnsureInit();
            int r = Probe(args[1]);
            Safe(() => qiumingdll_free());
            Console.WriteLine(r == 1 ? "RUNNING" : (r == 0 ? "NOTRUNNING" : "ERR:proc=" + r));
            return 0;
        }
        if (cmd == "procs")
        {
            if (args.Length < 2) { Console.WriteLine("ERR:nolist"); return 2; }
            var names = args[1].Split('|');
            bool any = false;
            EnsureInit();
            foreach (var raw in names)
            {
                var n = raw.Trim();
                if (n.Length == 0) continue;
                int r = Probe(n);
                if (r >= 0) any = true;
                Console.WriteLine(n.ToLowerInvariant() + ":" + (r == 1 ? "1" : "0"));
            }
            Safe(() => qiumingdll_free());
            if (!any) { Console.WriteLine("ERR:procs"); }
            return 0;
        }
        Console.WriteLine("ERR:unknown:" + cmd);
        return 2;
    }
}
