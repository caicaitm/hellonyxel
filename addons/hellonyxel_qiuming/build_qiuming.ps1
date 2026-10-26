# build_qiuming.ps1 -- rebuild QiumingProc.exe from QiumingProc.cs.
#
# Mirrors addons/hellonyxel_sysinfo/build_sysinfo.ps1. QiumingProc.exe wraps
# qiumingdll.dll (process detection) and is invoked from Godot via OS.execute,
# exactly like SysInfo.exe.
#
# Build:
#   powershell -NoProfile -ExecutionPolicy Bypass -File build_qiuming.ps1
# Output: QiumingProc.exe next to this script (keep it beside qiumingdll.dll).
#
# NOTE: ASCII-only -- PowerShell 5.1 reads a BOM-less UTF-8 script as ANSI,
#       and any non-ASCII byte corrupts the syntax.
param(
  [string]$CsPath = '',
  [string]$OutPath = ''
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($CsPath))  { $CsPath  = Join-Path $PSScriptRoot 'QiumingProc.cs' }
if ([string]::IsNullOrEmpty($OutPath)) { $OutPath = Join-Path $PSScriptRoot 'QiumingProc.exe' }

Write-Host "compiling $CsPath"
Write-Host "        -> $OutPath"

$t0 = Get-Date
if (Test-Path $OutPath) { Remove-Item $OutPath -Force }
Add-Type -Path $CsPath -OutputAssembly $OutPath -OutputType WindowsApplication `
  -ErrorAction Stop
$ms = [int]((Get-Date) - $t0).TotalMilliseconds

$fi = Get-Item $OutPath
Write-Host ("OK {0} bytes  ({1} ms)" -f $fi.Length, $ms)
Write-Host "verify: drop qiumingdll.dll (x64) beside this exe, then run the game -- process detection uses QiumingDLL when available"
