# 收集设备系统信息并写入 %Documents%\HelloNyxel\Temp\sysinfo.json
# 通过 Add-Type 在运行时编译同目录下的 SysInfo.cs（纯 C# + Windows 官方 P/Invoke API）。
$ErrorActionPreference = 'Stop'
try {
    $src = Join-Path $PSScriptRoot 'SysInfo.cs'
    Add-Type -Path $src -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop
    # ★ SysInfo 的入口已统一为 Main(string[] args)（编译成 EXE 后由参数分发）。
    #   无参调用必须显式传空数组：PowerShell 写 `[SysInfo]::Main()` 会因找不到无参重载报错。
    [SysInfo]::Main(@())
} catch {
    # 任何编译/运行错误都写入 error JSON，确保 Godot 侧始终能读到文件
    try {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        $dir = Join-Path $docs 'HelloNyxel\Temp'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $msg = $_.Exception.ToString().Replace('"', "'")
        $json = "{`"error`":`"$msg`"}"
        [System.IO.File]::WriteAllText((Join-Path $dir 'sysinfo.json'), $json, (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}
