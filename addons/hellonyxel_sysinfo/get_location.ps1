# get_location.ps1
# ---------------------------------------------------------------------------
# Read this PC's location and write it as JSON for the game (weather panel).
#
# Two independent sources are collected:
#   (1) device  -- latitude / longitude from the Windows Location Service
#                  (System.Device.Location.GeoCoordinateWatcher, best effort;
#                   unavailable when location services are off or denied)
#   (2) ip      -- country / province / city / isp resolved from the public IP
#
# The "location_text" field is built from the IP result (the IP result is the
# authoritative source, as requested). It is what the weather panel writes into
# its location field.
#
# Output file (UTF-8, no BOM, written atomically via a .tmp + Move-Item):
#   %Documents%\HelloNyxel\settings\location.json
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads a .ps1 that has
# no BOM as ANSI, so any non-ASCII byte here would be garbled into syntax
# errors. All non-ASCII text (Chinese place names) comes from the web service
# responses, which are decoded as UTF-8 at runtime.
#
# Usage:
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File get_location.ps1 \
#       -OutPath "D:\Documents\HelloNyxel\settings\location.json"
# ---------------------------------------------------------------------------
param(
    [Parameter(Mandatory = $true)][string]$OutPath,
    [int]$DeviceTimeoutSec = 5,
    [int]$HttpTimeoutSec = 5
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$result = @{
    source        = 'none'
    updated_at    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    device        = @{
        available = $false
        latitude  = $null
        longitude = $null
        accuracy  = $null
        status    = ''
        error     = ''
    }
    ip            = @{
        address      = ''
        country      = ''
        country_code = ''
        province     = ''
        city         = ''
        district     = ''
        isp          = ''
        source       = ''
    }
    local_ips     = @()
    location_text = ''
    error         = ''
    # Timing breakdown (ms) -- handy when the panel seems to take long.
    timings       = @{
        device_ms = 0
        ip_ms     = 0
        total_ms  = 0
    }
}

$scriptStart = Get-Date

function Save-Result {
    param($obj)
    try {
        $dir = Split-Path -Parent $OutPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $json = $obj | ConvertTo-Json -Depth 8
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $tmp = $OutPath + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $OutPath -Force
    } catch {
        # Last resort: never leave the caller without a file to read.
        try {
            $bad = '{"source":"none","error":"write failed"}'
            [System.IO.File]::WriteAllText($OutPath, $bad, (New-Object System.Text.UTF8Encoding $false))
        } catch { }
    }
}

# ---------------------------------------------------------------------------
# 1) Device latitude / longitude (Windows Location Service)
# ---------------------------------------------------------------------------
try {
    Add-Type -AssemblyName System.Device -ErrorAction Stop
    $devStart = Get-Date
    $watcher = New-Object System.Device.Location.GeoCoordinateWatcher
    $watcher.Start()
    $deadline = (Get-Date).AddSeconds($DeviceTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($watcher.Status -ne [System.Device.Location.GeoPositionStatus]::Initializing) { break }
        Start-Sleep -Milliseconds 200
    }
    $result.device.status = $watcher.Status.ToString()
    $loc = $watcher.Position.Location
    if ($watcher.Status -eq [System.Device.Location.GeoPositionStatus]::Ready -and -not $loc.IsUnknown) {
        $result.device.available = $true
        $result.device.latitude = [math]::Round($loc.Latitude, 6)
        $result.device.longitude = [math]::Round($loc.Longitude, 6)
        if ($loc.HorizontalAccuracy -ge 0) {
            $result.device.accuracy = [math]::Round($loc.HorizontalAccuracy, 1)
        }
    } elseif ($watcher.Permission -eq [System.Device.Location.GeoPositionPermission]::Denied) {
        $result.device.error = 'permission denied (turn on Windows location services)'
    } else {
        $result.device.error = 'location unavailable (status=' + $watcher.Status.ToString() + ')'
    }
    $watcher.Stop()
    $watcher = $null
} catch {
    $result.device.error = 'device location failed: ' + $_.Exception.Message
}
if ($devStart) { $result.timings.device_ms = [int]((New-TimeSpan -Start $devStart -End (Get-Date)).TotalMilliseconds) }

# ---------------------------------------------------------------------------
# 2) IP based location
#    Endpoints are tried in order; the first one that answers wins.
#    (a)/(b) return Chinese place names, (c) is an English HTTPS fallback.
# ---------------------------------------------------------------------------
function Get-IpLocation {
    param([int]$Timeout)

    # (a) ip-api.com -- free tier, plain HTTP, supports lang=zh-CN
    try {
        $u = 'http://ip-api.com/json/?lang=zh-CN&fields=status,message,country,countryCode,regionName,city,district,isp,query'
        $r = Invoke-RestMethod -Uri $u -TimeoutSec $Timeout -UseBasicParsing
        if ($r.status -eq 'success') {
            return @{
                address = [string]$r.query; country = [string]$r.country; country_code = [string]$r.countryCode
                province = [string]$r.regionName; city = [string]$r.city; district = [string]$r.district
                isp = [string]$r.isp; source = 'ip-api.com'
            }
        }
    } catch { }

    # (b) ip.zxinc.org -- HTTPS, Chinese names packed as "Country<en-dash>Province<en-dash>City"
    try {
        $u = 'https://ip.zxinc.org/api.php?type=json'
        $r = Invoke-RestMethod -Uri $u -TimeoutSec $Timeout -UseBasicParsing
        if ($r.code -eq 0 -and $r.data) {
            # NOTE: PowerShell 5.1 has no "if as an expression", so compute first.
            $parts = @(([string]$r.data.country) -split "[\u2013\u2014-]")
            $c0 = ''; $c1 = ''; $c2 = ''
            if ($parts.Count -gt 0) { $c0 = $parts[0].Trim() }
            if ($parts.Count -gt 1) { $c1 = $parts[1].Trim() }
            if ($parts.Count -gt 2) { $c2 = $parts[2].Trim() }
            return @{
                address = [string]$r.data.myip
                country = $c0
                country_code = ''
                province = $c1
                city = $c2
                district = ''
                isp = ([string]$r.data.local).Trim()
                source = 'ip.zxinc.org'
            }
        }
    } catch { }

    # (c) ipwho.is -- HTTPS, English names
    try {
        $u = 'https://ipwho.is/'
        $r = Invoke-RestMethod -Uri $u -TimeoutSec $Timeout -UseBasicParsing
        if ($r.success -eq $true) {
            return @{
                address = [string]$r.ip; country = [string]$r.country; country_code = [string]$r.country_code
                province = [string]$r.region; city = [string]$r.city; district = ''
                isp = [string]$r.connection.isp; source = 'ipwho.is'
            }
        }
    } catch { }

    return $null
}

$ip = $null
$ipStart = Get-Date
try { $ip = Get-IpLocation -Timeout $HttpTimeoutSec } catch { $ip = $null }
$result.timings.ip_ms = [int]((New-TimeSpan -Start $ipStart -End (Get-Date)).TotalMilliseconds)
if ($null -ne $ip) {
    $result.ip = $ip
    $result.source = 'ip'
} else {
    $result.error = 'ip geolocation failed (no endpoint answered)'
}

# ---------------------------------------------------------------------------
# 3) location_text -- built from the IP result; consecutive duplicates dropped
#    e.g. country + province + city => "China Shanxi Taiyuan"
# ---------------------------------------------------------------------------
$parts = @()
foreach ($v in @($result.ip.country, $result.ip.province, $result.ip.city)) {
    $s = ([string]$v).Trim()
    if ($s -and ($parts.Count -eq 0 -or $parts[$parts.Count - 1] -ne $s)) { $parts += $s }
}
$result.location_text = ($parts -join ' ')

# ---------------------------------------------------------------------------
# 4) Local (LAN) IPv4 addresses -- extra context, not used for geolocation
# ---------------------------------------------------------------------------
try {
    $lan = @()
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
            $a = $ua.Address
            if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $lan += $a.ToString() }
        }
    }
    $result.local_ips = $lan
} catch { }

# ---------------------------------------------------------------------------
# 5) Write it out
# ---------------------------------------------------------------------------
$result.timings.total_ms = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
Save-Result $result

if ($result.location_text) {
    Write-Output ('LOCATION_OK ' + $result.source + ' ' + $result.location_text)
} else {
    Write-Output ('LOCATION_FAIL ' + $result.error)
}
