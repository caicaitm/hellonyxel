# pin_topmost.ps1 —— 确保指定 HWND 处于置顶层（WS_EX_TOPMOST）。
# 由 DesktopShell 在窗口几何稳定后调用（后台线程），确保游戏覆盖层按「Win+D」也不被最小化。
# ★ 条件化：已经置顶时**不再**重复 SetWindowPos —— 对已置顶窗口再钉唯一效果是抢
#   「置顶层 band」的最上面，会跟截图软件等同样置顶的覆盖窗打架（z 序拉锯）。
#   我们只需要标志在位，不在位才补钉。
# 入参：-Hwnd <long>（来自 DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)）
param([long]$Hwnd = 0)

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'SysInfo.cs'
Add-Type -Path $src -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -ErrorAction Stop
if (-not [SysInfo]::isTopmost($Hwnd)) {
    [SysInfo]::PinTopmost($Hwnd)
}
# 读回扩展样式验证置顶是否真正落进系统；打印结果供 Godot 侧捕获判断
# ★★ 必须用 [Console]::Out.WriteLine，**不能**用 Write-Output：
#    `powershell.exe -File <脚本>` 且 stdout 被重定向成管道时（Godot 的 OS.execute 正是这样），
#    Write-Output 写的「成功流」到不了进程 stdout → Godot 侧读到空 → 验证位恒 false。
#    同目录 enumerate_scene.ps1 一直用 [Console]::Out.Write 才没踩到。2026-10-02 实测确认。
if ([SysInfo]::isTopmost($Hwnd)) { [Console]::Out.WriteLine('TOPMOST_OK') } else { [Console]::Out.WriteLine('TOPMOST_FAIL') }