# HelloNyxel system-tray (notification area) icon helper process.
#
# Launched by the Godot autoload `TrayRunner.gd` via OS.create_process:
#   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tray_icon.ps1
#       -IconPath <icon.png> -RequestPath <quitRequestFile> -SettingsRequestPath <settingsRequestFile>
#       -SavesRequestPath <savesRequestFile> -BusyStatePath <busyStateFile>
#       -BusyNowRequestPath <busyNowFile> -IdleNowRequestPath <idleNowFile>
#       -DebugRequestPath <debugRequestFile> -DebugStatePath <debugStateFile> -DebugVisiblePath <debugVisibleFile>
#       -ShowDebugItem <0|1>
#       -GamePid <pid> -AutoClickSeconds <n> -BusyIconPath <icon_zzz.ico>
# -IconPath is the idle tray icon (icon.ico), -BusyIconPath the busy one (icon_zzz.ico);
# the helper polls -BusyStatePath and swaps the tray icon when the busy flag flips.
# Compiles TrayIcon.cs (same folder) at runtime with Add-Type; pure .NET types, no P/Invoke.
# -STA is required: the tray icon and its message loop need a single-threaded apartment.
#
# IMPORTANT: keep this file ASCII-only. Windows PowerShell 5.1 reads a BOM-less .ps1
# using the system ANSI code page, and non-ASCII text above `param()` makes the whole
# param block fail to parse ("assignment expression is not valid").
param(
    [string]$IconPath = '',
    [string]$RequestPath = '',
    [string]$SettingsRequestPath = '',
    [string]$SavesRequestPath = '',
    [string]$ModListRequestPath = '',
    [string]$PassthroughRequestPath = '',
    [string]$PerfBusyRequestPath = '',
    [string]$WeatherRequestPath = '',
    [string]$AIRequestPath = '',
    [string]$CalendarRequestPath = '',
    [string]$DebugRequestPath = '',
    [string]$BusyStatePath = '',
    [string]$DebugStatePath = '',
    [string]$DebugVisiblePath = '',
    [int]$ShowDebugItem = 1,
    [string]$BusyNowRequestPath = '',
    [string]$IdleNowRequestPath = '',
    [int]$GamePid = 0,
    [int]$AutoClickSeconds = 0,
    [string]$BusyIconPath = '',
    [string]$VersionRequestPath = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# Diagnostics go to "<RequestPath>.log": the tray is a separate process, so Godot
# cannot capture its stdout. READY / EXIT / ERROR markers are written by TrayIcon.cs.
function Write-Log([string]$line) {
    if ([string]::IsNullOrEmpty($RequestPath)) { return }
    try { [System.IO.File]::AppendAllText($RequestPath + '.log', $line + [Environment]::NewLine) } catch { }
}

try {
    $src = Join-Path $PSScriptRoot 'TrayIcon.cs'
    Add-Type -Path $src -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop
    Write-Log 'COMPILED'

    if ($SelfTest) {
        $r = [TrayIcon]::SelfTest($IconPath, $RequestPath)
        Write-Output "SELFTEST:$r"
        exit 0
    }

    [TrayIcon]::Run($IconPath, $RequestPath, $SettingsRequestPath, $SavesRequestPath, $ModListRequestPath, $PassthroughRequestPath, $PerfBusyRequestPath, $WeatherRequestPath, $AIRequestPath, $CalendarRequestPath, $DebugRequestPath, $BusyStatePath, $DebugStatePath, $DebugVisiblePath, $ShowDebugItem, $BusyNowRequestPath, $IdleNowRequestPath, $GamePid, $AutoClickSeconds, $BusyIconPath, $VersionRequestPath)
    exit 0
} catch {
    $msg = $_.Exception.ToString().Replace("`r", ' ').Replace("`n", ' ')
    Write-Log ("ERROR: " + $msg)
    Write-Output "TRAY_ERROR:$msg"
    exit 1
}
