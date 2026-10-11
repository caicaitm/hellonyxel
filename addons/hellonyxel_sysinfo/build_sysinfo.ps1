# build_sysinfo.ps1 -- rebuild SysInfo.exe from SysInfo.cs (run this after editing SysInfo.cs).
#
# Why this file exists
# --------------------
# desktop.gd polls the desktop every ENUM_INTERVAL_SEC. The old path was
#     powershell.exe -File enumerate_scene.ps1
# and enumerate_scene.ps1 ran `Add-Type -Path SysInfo.cs` on EVERY call, i.e. it
# recompiled ~30 KB of C# once per second (~0.64 s of the ~1.05 s single-call cost).
# That produced a ~0.28 core floor that was completely independent of the frame rate.
#
# Precompiling SysInfo.cs into SysInfo.exe removes BOTH costs: the C# compile and the
# PowerShell host startup. At the same time the console subsystem is dropped
# (-OutputType WindowsApplication), so no conhost.exe is spawned either.
#
# Build
# -----
#   powershell -NoProfile -ExecutionPolicy Bypass -File build_sysinfo.ps1
# Output: SysInfo.exe next to this script. Commit it so a fresh checkout runs without
#         a build step; re-run this script whenever SysInfo.cs changes.
#
# Fallback
# --------
# If SysInfo.exe is missing, desktop.gd falls back to enumerate_scene.ps1 (the old,
# slow, per-call-compile path) and pushes a warning. The game keeps working.
#
# NOTE: this file must stay ASCII-only -- PowerShell 5.1 reads a BOM-less UTF-8
#       script as ANSI, and any non-ASCII byte corrupts the syntax.
param(
  [string]$CsPath = '',
  [string]$OutPath = ''
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($CsPath))  { $CsPath  = Join-Path $PSScriptRoot 'SysInfo.cs' }
if ([string]::IsNullOrEmpty($OutPath)) { $OutPath = Join-Path $PSScriptRoot 'SysInfo.exe' }

Write-Host "compiling $CsPath"
Write-Host "        -> $OutPath"

$t0 = Get-Date
if (Test-Path $OutPath) { Remove-Item $OutPath -Force }
Add-Type -Path $CsPath -OutputAssembly $OutPath -OutputType WindowsApplication `
  -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop
$ms = [int]((Get-Date) - $t0).TotalMilliseconds

$fi = Get-Item $OutPath
Write-Host ("OK {0} bytes  ({1} ms)" -f $fi.Length, $ms)

# Do NOT try to capture the exe's stdout from here: a WindowsApplication (GUI subsystem)
# process is not reliably captured by PowerShell's native-command pipeline. Redirect it
# yourself if you want to eyeball the payload:
#   & $OutPath scene 0 0 > $env:TEMP\scene.json 2>&1   (from cmd.exe, or from bash)
Write-Host "verify: open the game -- it must still detect the desktop icons (384 boundary blocks)"
