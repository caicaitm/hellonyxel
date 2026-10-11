param([string]$CsPath = '', [string]$OutPath = '')
# Build a standalone TrayIcon.exe from TrayIcon.cs.
#
# WHY THIS FILE EXISTS
#   The system tray used to be started as
#       powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tray_icon.ps1
#   and tray_icon.ps1 did `Add-Type -Path TrayIcon.cs` at runtime. That means every
#   session paid for a full PowerShell host (System.Management.Automation + CLR +
#   WinForms + Drawing, ~103 MB resident) plus a runtime C# compile, just to run a
#   WinForms message loop. Precompiling the same source into a standalone EXE removes
#   the PowerShell host, the compile and (being a GUI-subsystem binary) the conhost.
#
# HOW TO BUILD
#   powershell -NoProfile -ExecutionPolicy Bypass -File build_tray.ps1
#   (Add-Type -OutputAssembly works with the in-box compiler; no SDK needed.)
#
# AFTER EDITING TrayIcon.cs YOU MUST RE-RUN THIS, otherwise the shipped EXE is stale.
#   The runtime falls back to tray_icon.ps1 (old, slower path) if the EXE is missing.
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads a BOM-less .ps1 using
#       the system ANSI code page; non-ASCII text here would corrupt the script.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($CsPath)) { $CsPath = Join-Path $PSScriptRoot 'TrayIcon.cs' }
if ([string]::IsNullOrEmpty($OutPath)) { $OutPath = Join-Path $PSScriptRoot 'TrayIcon.exe' }

Write-Host "compiling $CsPath"
Write-Host "        -> $OutPath"
$t0 = Get-Date
Add-Type -Path $CsPath -OutputAssembly $OutPath -OutputType WindowsApplication `
    -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop
$ms = [int]((Get-Date) - $t0).TotalMilliseconds
$len = (Get-Item $OutPath).Length
Write-Host ("OK {0} bytes  ({1} ms)" -f $len, $ms)
Write-Host "verify: start the game -- the tray icon must appear, and"
Write-Host "        %APPDATA%\Godot\app_userdata\HelloNyxel\tray_quit_<pid>.log must contain READY"
