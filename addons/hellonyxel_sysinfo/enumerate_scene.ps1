# 实时枚举「各程序窗口矩形 + 桌面图标位置/大小」，把结果打到 stdout，供 Godot 内存解析。
# 不写入任何文件（区别于 gather_sysinfo.ps1 的 sysinfo.json）。
#   Godot 侧：OS.execute 调用本脚本 → 拿到 stdout 的 JSON → JSON.parse_string 直接用。
#
# 用法约定：必须用 -NoProfile -ExecutionPolicy Bypass 调用（不含 profile 加载，省启动时间）。
# 性能：每次调用会 Add-Type 编译同目录下的 SysInfo.cs（约几十到一两百毫秒），
#       因此由 desktop.gd 在**后台线程**里定时调用，避免卡 UI 主循环。
$ErrorActionPreference = 'Stop'
param(
    # 游戏进程的真实 PID（来自 Godot 的 OS.get_process_id()），兜底用于让枚举跳过游戏自己的透明覆盖窗口。
    # 不传（默认 0）则不做 PID 豁免（仅用于调试/独立运行本脚本的场景）。
    [Parameter(Mandatory = $false)]
    [long]$GamePid = 0,
    # 游戏主窗口的精确 HWND（来自 Godot 的 DisplayServer.window_get_native_handle(0)），
    # 优先用于精确跳过游戏自身窗口——比 PID 更可靠（脚本跑在独立 PowerShell 进程，PID 可能不一致）。
    [Parameter(Mandatory = $false)]
    [long]$GameHwnd = 0
)
try {
    $src = Join-Path $PSScriptRoot 'SysInfo.cs'
    Add-Type -Path $src -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::Out.Write([SysInfo]::BuildSceneJson($GamePid, $GameHwnd))
} catch {
    # 出错也要给 Godot 一个可解析的 JSON，避免主流程被一块坏数据卡死
    $msg = $_.Exception.ToString().Replace('"', "'")
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::Out.Write("{`"error`":`"$msg`"}")
}