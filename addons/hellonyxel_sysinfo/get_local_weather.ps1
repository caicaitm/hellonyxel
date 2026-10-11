# get_local_weather.ps1
# ---------------------------------------------------------------------------
# Read THIS PC's weather and write it as JSON for the game (weather panel).
#
# Data source: the public MSN Weather "overview" endpoint -- the same backend
# that powers the Windows Weather app and the taskbar weather widget. So what
# the game stores is exactly "the machine's own weather" as Windows sees it
# (provider: Foreca, served by MSN). The response also contains the place name
# MSN resolved the coordinates to
#   value[0].responses[0].source.location
# which is what the game shows as "where this weather actually is".
#
# Location resolution (in this order):
#   (1) device -- Windows Location Service (GeoCoordinateWatcher). Same source
#                 the Windows Weather app uses, so it agrees with the widget.
#                 Polled until Ready (see NOTE 5) and retried with a fresh
#                 watcher -DeviceAttempts times.
#   (2) ip     -- public IP geolocation (ip-api.com). Fallback only, used when
#                 the device location is unavailable / denied. Beware: with a
#                 VPN / proxy this points at the network exit, not the PC.
#   BOTH are ALWAYS collected and queried against MSN independently. The PC can
#   therefore have MORE THAN ONE location's weather at the same time -- e.g.
#   the real device fix AND the IP (VPN-exit) fix. Every fetched location is
#   emitted in the top-level "locations" ARRAY (deduped by location_text, the
#   device one wins ties), so the player can pick which one to use in-game.
#
# History for trend comparison:
#   Each location keeps its OWN daily-forecast history keyed by "yyyy-MM-dd"
#   inside that location's "days" object. Entries inside the last RetainBackDays
#   days are NEVER dropped, so the days that have already passed stay in the
#   file (with the last forecast we recorded for them). Everything older is
#   pruned, so the file stays bounded. History is merged per-location across
#   runs by matching location_text.
#
# Hourly forecast (finer precision when the device source supports it):
#   The MSN overview payload carries an HOURLY array NESTED PER DAY, i.e.
#   value[0].responses[0].weather[0].forecast.days[i].hourly -- NOT
#   forecast.hourly (that property does not exist; only "days" is listed).
#   Each slot has "valid" (ISO-8601 with offset, e.g. 2026-10-04T20:00:00+08:00)
#   plus temp / feels / cap / icon / precip / uv / windSpd / windDir / rh ...
#   Measured: 10 days x 24 slots = 220 slots per coordinate; the current day
#   only carries the REMAINING hours (e.g. 20:00..23:00), earlier ones are gone.
#   So the game can offer per-hour precision today, and the game degrades to
#   daily-only automatically on any response that has no "hourly" arrays.
#   Merged per-location into "hours", keyed by "yyyy-MM-ddTHH" (local wall
#   clock, matching the "valid" offset), same retention rule as days.
#
# Output file (UTF-8, no BOM, written atomically via .tmp + Move-Item):
#   %Documents%\HelloNyxel\settings\local_weather.json
#
# NOTE 1: keep this file ASCII-only. Windows PowerShell 5.1 reads a .ps1 that
#         has no BOM as ANSI, so any non-ASCII byte here would be garbled into
#         syntax errors. All non-ASCII text (place names) comes from the web
#         service responses, decoded as UTF-8 at runtime.
# NOTE 2: condition strings ("Cloudy", "Light rain", ...) come from MSN/Foreca
#         in English; the game translates them for display.
# NOTE 3: the MSN endpoint is a public, non-secret key endpoint (the same key
#         the MSN web page sends). Its response carries a Microsoft copyright
#         notice -- this data is meant for personal on-device use.
# NOTE 4: both HTTP calls go through Invoke-TextRequest, which retries a few
#         times. The network here does occasionally fail a single lookup with
#         "The remote name could not be resolved"; retrying absorbs that and
#         the attempt count is recorded in timings.{ip,msn}_attempts.
# NOTE 5: never break the device-location wait just because the status is not
#         "Initializing" -- it briefly reads NoData before turning Ready. See
#         the block comment in section 1 for the measurements.
#
# Usage:
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File get_local_weather.ps1 \
#       -OutPath "D:\Documents\HelloNyxel\settings\local_weather.json"
# ---------------------------------------------------------------------------
param(
    [Parameter(Mandatory = $true)][string]$OutPath,
    [int]$DeviceTimeoutSec = 2,
    [int]$DeviceAttempts = 3,
    [int]$HttpTimeoutSec = 8,
    [int]$RetainBackDays = 7,
    [string]$Units = 'C'
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# Public, non-secret api key -- the same one the MSN weather page / Windows
# widget sends in the query string.
$MsnEndpoint = 'https://api.msn.com/weather/overview'
$MsnApiKey = 'UhJ4G66OjyLbn9mXARgajXLiLw6V75sHnfpU60aJBB'

$scriptStart = Get-Date
$nowText = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$today = (Get-Date).Date

$result = @{
    updated_at = $nowText
    # !! Must be a real Unix timestamp. The naive form
    #    ((Get-Date).ToUniversalTime() - [datetime]'1970-01-01T00:00:00Z')
    #    is WRONG: PowerShell parses that '...Z' literal into a LOCAL DateTime,
    #    so the result came out shifted by the UTC offset (measured -28800 s in
    #    UTC+8). Fresh data then looked 8 hours old -- the panel showed
    #    "8 hours ago" right after a fetch, and every hour counted as stale.
    updated_epoch = [int64](([datetime]::UtcNow - [datetime]'1970-01-01T00:00:00').TotalSeconds)
    error = ''
    source = @{
        provider = ''
        endpoint = $MsnEndpoint
        coord_source = ''
        coord_note = ''
        units = $Units
    }
    machine = @{
        latitude = $null
        longitude = $null
        accuracy = $null
        device_status = ''
        ip_address = ''
        ip_country = ''
        ip_province = ''
        ip_city = ''
        ip_isp = ''
        ip_source = ''
    }
    # !! Multi-location: every fetched location (device + IP) is an element of
    #    this array. Each element carries its own location_text / coord_source /
    #    location / current / days / retain. The single top-level location /
    #    current / days from earlier versions is GONE -- the game reads from
    #    the selected location element instead.
    locations = @()
    timings = @{
        device_ms = 0
        device_attempts = 0
        ip_ms = 0
        ip_attempts = 0
        http_ms = 0
        msn_attempts = 0
        total_ms = 0
    }
}

# JSON-safe scalar helpers: keep nulls as null instead of turning them into 0.
function NumOrNull {
    param($v)
    if ($null -eq $v) { return $null }
    return [double]$v
}
function IntOrNull {
    param($v)
    if ($null -eq $v) { return $null }
    return [int]$v
}
function StrOrEmpty {
    param($v)
    if ($null -eq $v) { return '' }
    return [string]$v
}

# Transient-failure guard for every HTTP call.
# Why it matters: a lookup of api.msn.com occasionally dies with "The remote
# name could not be resolved" (observed once, burning ~11 s of internal DNS
# retries). Without a retry a single blip would cost the whole hour, because
# the game only re-tries automatically at the next o'clock. Retrying here keeps
# that decision out of the caller.  $script:LastAttempts reports how many
# tries the last call needed, so the output JSON shows whether the net was flaky.
$script:LastAttempts = 0
$script:LastError = ''
function Invoke-TextRequest {
    param([string]$Uri, [int]$Attempts = 3, [int]$DelayMs = 700)
    $last = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $r = Invoke-RestMethod -Uri $Uri -TimeoutSec $HttpTimeoutSec -UseBasicParsing
            $script:LastAttempts = $i
            return $r
        } catch {
            $last = $_
            if ($i -lt $Attempts) { Start-Sleep -Milliseconds $DelayMs }
        }
    }
    $script:LastAttempts = $Attempts
    throw $last
}

function Save-Result {
    param($obj)
    try {
        $dir = Split-Path -Parent $OutPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $json = $obj | ConvertTo-Json -Depth 10
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $tmp = $OutPath + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $OutPath -Force
    } catch {
        try {
            $bad = '{"error":"write failed"}'
            [System.IO.File]::WriteAllText($OutPath, $bad, (New-Object System.Text.UTF8Encoding $false))
        } catch { }
    }
}

# ---------------------------------------------------------------------------
# Query MSN for ONE coordinate pair and build a location entry hashtable.
# Returns the entry (with a raw "w" node kept for the days-merge step) or
# $null on failure (the failure reason is recorded in $script:LastError).
# ---------------------------------------------------------------------------
function Build-Entry {
    param($lat, $lon, $coordSource, $acc)
    $httpStart = Get-Date
    try {
        $url = $MsnEndpoint + '?apikey=' + $MsnApiKey + '&lat=' + ([string]$lat) + '&lon=' + ([string]$lon) + '&units=' + $Units
        $resp = Invoke-TextRequest -Uri $url -Attempts 3
        $val = @($resp.value)[0]
        $node = @($val.responses)[0]
        $w = @($node.weather)[0]
        $src = $node.source
        $provider = StrOrEmpty $w.provider.name
        # Place name MSN resolved us to, e.g. "Zhangjiawan, Hubei, CN"
        # (consecutive duplicates dropped).
        $np = @()
        foreach ($v in @($src.location.Name, $src.location.StateCode, $src.location.CountryCode)) {
            $s = ([string]$v).Trim()
            if ($s -and ($np.Count -eq 0 -or $np[$np.Count - 1] -ne $s)) { $np += $s }
        }
        $locationText = ($np -join ', ')
        $location = @{
            name = StrOrEmpty $src.location.Name
            state = StrOrEmpty $src.location.StateCode
            country_code = StrOrEmpty $src.location.CountryCode
            timezone = StrOrEmpty $src.location.TimezoneName
            latitude = NumOrNull $src.coordinates.lat
            longitude = NumOrNull $src.coordinates.lon
            msn_id = StrOrEmpty $src.id
            location_text = $locationText
        }
        $c = $w.current
        $current = @{
            cap = StrOrEmpty $c.cap
            temp = NumOrNull $c.temp
            feels = NumOrNull $c.feels
            rh = NumOrNull $c.rh
            wind_spd = NumOrNull $c.windSpd
            wind_dir = IntOrNull $c.windDir
            wind_gust = NumOrNull $c.windGust
            uv = NumOrNull $c.uv
            uv_desc = StrOrEmpty $c.uvDesc
            aqi = NumOrNull $c.aqi
            icon = IntOrNull $c.icon
            sky = StrOrEmpty $c.sky
            daytime = StrOrEmpty $c.daytime
            created = StrOrEmpty $c.created
        }
        # Provider is the same for every coordinate (same MSN endpoint), but
        # record it once from the first successful query.
        if ($result.source.provider -eq '') { $result.source.provider = $provider }
        return @{
            location_text = $locationText
            coord_source = $coordSource
            latitude = NumOrNull $lat
            longitude = NumOrNull $lon
            accuracy = $acc
            location = $location
            current = $current
            w = $w
        }
    } catch {
        $script:LastError = 'weather request failed (' + $coordSource + ') after ' + ([string]$script:LastAttempts) +
            ' attempt(s): ' + $_.Exception.Message
        return $null
    }
}

# ---------------------------------------------------------------------------
# Merge one location's previous daily-forecast history with the freshly fetched
# forecast. Previous entries inside the retention window are kept as-is; today's
# fetch only overwrites the dates it actually covers.
# ---------------------------------------------------------------------------
function Merge-Days {
    param($prevDaysObj, $w)
    $prevDays = @{}
    if ($prevDaysObj -and $prevDaysObj.PSObject) {
        foreach ($p in $prevDaysObj.PSObject.Properties) { $prevDays[$p.Name] = $p.Value }
    }
    $cutoff = $today.AddDays(-1 * $RetainBackDays)
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $flags = [System.Globalization.DateTimeStyles]::None
    $list = @{}
    foreach ($k in $prevDays.Keys) {
        $kd = [datetime]::MinValue
        $ok = [datetime]::TryParseExact([string]$k, 'yyyy-MM-dd', $ci, $flags, [ref]$kd)
        if (-not $ok) { continue }
        if ($kd -lt $cutoff) { continue }
        $pd = $prevDays[$k]
        $list[[string]$k] = @{
            date = [string]$k
            hi = $pd.hi
            lo = $pd.lo
            cap = $pd.cap
            night_cap = $pd.night_cap
            precip = $pd.precip
            uv = $pd.uv
            wind_max = $pd.wind_max
            icon = $pd.icon
            first_seen = $pd.first_seen
            last_seen = $pd.last_seen
            updates = $pd.updates
        }
    }
    if ($null -ne $w) {
        foreach ($day in @($w.forecast.days)) {
            $dl = $day.daily
            $valid = StrOrEmpty $dl.valid
            if ($valid.Length -lt 10) { continue }
            $date = $valid.Substring(0, 10)
            $entry = $null
            if ($list.ContainsKey($date)) {
                $entry = $list[$date]
            } else {
                $entry = @{ date = $date; first_seen = $nowText; last_seen = $nowText; updates = 0 }
            }
            $entry.hi = NumOrNull $dl.tempHi
            $entry.lo = NumOrNull $dl.tempLo
            $entry.cap = StrOrEmpty $dl.day.cap
            $entry.night_cap = StrOrEmpty $dl.night.cap
            $entry.precip = NumOrNull $dl.precip
            $entry.uv = NumOrNull $dl.uv
            $entry.wind_max = NumOrNull $dl.windMax
            $entry.icon = IntOrNull $dl.icon
            $entry.last_seen = $nowText
            $entry.updates = [int]$entry.updates + 1
            $list[$date] = $entry
        }
    }
    $keys = @($list.Keys | Sort-Object)
    $first = ''
    $last = ''
    if ($keys.Count -gt 0) {
        $first = [string]$keys[0]
        $last = [string]$keys[$keys.Count - 1]
    }
    return @{ list = $list; first = $first; last = $last; count = $keys.Count }
}

# ---------------------------------------------------------------------------
# Merge one location's previous HOURLY forecast with the freshly fetched one.
#
# Hourly slots live NESTED PER DAY: $w.forecast.days[i].hourly -- there is no
# top-level forecast.hourly. The key is "yyyy-MM-ddTHH" taken from the slot's
# own "valid" field, so the merge is per hour and stays stable across runs that
# happen in different hours of the same day.
#
# Retention mirrors Merge-Days: anything older than the cutoff day is pruned,
# everything inside the window survives. Entries the current fetch does not
# cover (past hours of today) are kept exactly as last recorded.
#
# Size note: hourly slots do NOT carry the first_seen / last_seen / updates
# bookkeeping that days carry. Measured: those three fields alone were ~60 of
# the 212 bytes per slot, i.e. ~26 KB per location per run, and unlike a day
# an hour has no "trend comparison" value once it is past -- MSN only hands us
# the REMAINING hours of today anyway, so a stored past hour is already the
# last forecast for it. This keeps local_weather.json around 380 KB instead of
# 550 KB for two locations.
#
# If the response carries no hourly arrays at all, the previous history is
# returned untouched -- the game then simply has no hourly precision and falls
# back to daily. Never fabricate slots.
# ---------------------------------------------------------------------------
function Merge-Hours {
    param($prevHoursObj, $w)
    $prevHours = @{}
    if ($prevHoursObj -and $prevHoursObj.PSObject) {
        foreach ($p in $prevHoursObj.PSObject.Properties) { $prevHours[$p.Name] = $p.Value }
    }
    $cutoff = $today.AddDays(-1 * $RetainBackDays)
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $flags = [System.Globalization.DateTimeStyles]::None
    $list = @{}
    foreach ($k in $prevHours.Keys) {
        $kh = [datetime]::MinValue
        $ok = [datetime]::TryParseExact([string]$k, 'yyyy-MM-ddTHH', $ci, $flags, [ref]$kh)
        if (-not $ok) { continue }
        if ($kh.Date -lt $cutoff) { continue }
        $ph = $prevHours[$k]
        $list[[string]$k] = @{
            valid = [string]$k
            temp = $ph.temp
            feels = $ph.feels
            cap = $ph.cap
            precip = $ph.precip
            uv = $ph.uv
            wind_spd = $ph.wind_spd
            wind_dir = $ph.wind_dir
            rh = $ph.rh
            icon = $ph.icon
        }
    }
    $slotCount = 0
    if ($null -ne $w) {
        foreach ($day in @($w.forecast.days)) {
            # NOTE: when a day has no hourly array, @($null) yields an array
            # with ONE $null element in PowerShell -- hence the explicit
            # $null / type check before touching properties.
            $hours = $day.hourly
            if ($null -eq $hours) { continue }
            foreach ($h in @($hours)) {
                if ($null -eq $h) { continue }
                $slotCount++
                $valid = StrOrEmpty $h.valid
                if ($valid.Length -lt 13) { continue }
                # "2026-10-04T20:00:00+08:00" -> "2026-10-04T20"
                $key = $valid.Substring(0, 13)
                $list[$key] = @{
                    valid = $key
                    temp = NumOrNull $h.temp
                    feels = NumOrNull $h.feels
                    cap = StrOrEmpty $h.cap
                    precip = NumOrNull $h.precip
                    uv = NumOrNull $h.uv
                    wind_spd = NumOrNull $h.windSpd
                    wind_dir = IntOrNull $h.windDir
                    rh = NumOrNull $h.rh
                    icon = IntOrNull $h.icon
                }
            }
        }
    }
    $keys = @($list.Keys | Sort-Object)
    $first = ''
    $last = ''
    if ($keys.Count -gt 0) {
        $first = [string]$keys[0]
        $last = [string]$keys[$keys.Count - 1]
    }
    return @{ list = $list; first = $first; last = $last; count = $keys.Count; fetched = $slotCount }
}

# ---------------------------------------------------------------------------
# 1) Coordinates: device (Windows Location Service) first
#
# !! Do NOT bail out the moment the status is not "Initializing".  Right after
#   Start() the watcher can report NoData for a moment before flipping to
#   Ready -- the naive loop (break on anything != Initializing) gives up after
#   0 ms and records "NoData" although the fix arrives ~150 ms later. Measured
#   on this machine: the naive pattern produced Real coordinates only about a
#   third of the time, while polling until Ready got them 4/4 in ~160 ms.
#   (lfsvc, the Windows Geolocation Service, is startType=Manual here.)
#   Why it matters so much: the device fix is the PC's real position, whereas
#   the IP fallback resolves to the VPN / proxy exit -- i.e. the difference
#   between THIS machine's weather and somebody else's. So retry with a fresh
#   watcher a few times before falling back to IP.
# ---------------------------------------------------------------------------
$deviceLat = $null
$deviceLon = $null
$deviceAcc = $null
$devStart = Get-Date
try {
    Add-Type -AssemblyName System.Device -ErrorAction Stop
    $ready = [System.Device.Location.GeoPositionStatus]::Ready
    $statusSeen = ''
    $denied = $false
    for ($attempt = 1; $attempt -le $DeviceAttempts; $attempt++) {
        $watcher = New-Object System.Device.Location.GeoCoordinateWatcher
        $watcher.Start()
        $deadline = (Get-Date).AddSeconds($DeviceTimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ($watcher.Status -eq $ready) { break }
            Start-Sleep -Milliseconds 100
        }
        $statusSeen = $watcher.Status.ToString()
        $loc = $watcher.Position.Location
        if ($watcher.Status -eq $ready -and -not $loc.IsUnknown) {
            $deviceLat = [math]::Round($loc.Latitude, 6)
            $deviceLon = [math]::Round($loc.Longitude, 6)
            if ($loc.HorizontalAccuracy -ge 0) { $deviceAcc = [math]::Round($loc.HorizontalAccuracy, 1) }
        } elseif ($watcher.Permission -eq [System.Device.Location.GeoPositionPermission]::Denied) {
            $denied = $true
        }
        try { $watcher.Stop(); $watcher.Dispose() } catch { }
        $watcher = $null
        if ($null -ne $deviceLat) { break }
        if ($denied) { break }
        if ($attempt -lt $DeviceAttempts) { Start-Sleep -Milliseconds 300 }
    }
    if ($null -ne $deviceLat) {
        $result.source.coord_note = 'device location (Windows Location Service)'
    } elseif ($denied) {
        $result.source.coord_note = 'device location denied; also collecting IP'
    } else {
        $result.source.coord_note = 'device location unavailable (status=' + $statusSeen + ', ' +
            ([string]$DeviceAttempts) + ' attempt(s)); also collecting IP'
    }
    $result.machine.device_status = $statusSeen
} catch {
    $result.source.coord_note = 'device location failed: ' + $_.Exception.Message
}
$result.timings.device_ms = [int]((New-TimeSpan -Start $devStart -End (Get-Date)).TotalMilliseconds)
$result.timings.device_attempts = $DeviceAttempts

# ---------------------------------------------------------------------------
# 2) IP geolocation -- always collected (cross-check AND a second weather
#    source). Coordinates are used to query MSN independently of the device fix.
# ---------------------------------------------------------------------------
$ipLat = $null
$ipLon = $null
$ipStart = Get-Date
try {
    $u = 'http://ip-api.com/json/?lang=en&fields=status,message,country,countryCode,regionName,city,district,isp,query,lat,lon'
    $r = Invoke-TextRequest -Uri $u -Attempts 2
    $result.timings.ip_attempts = $script:LastAttempts
    if ($r.status -eq 'success') {
        $result.machine.ip_address = StrOrEmpty $r.query
        $result.machine.ip_country = StrOrEmpty $r.country
        $result.machine.ip_province = StrOrEmpty $r.regionName
        $result.machine.ip_city = StrOrEmpty $r.city
        $result.machine.ip_isp = StrOrEmpty $r.isp
        $result.machine.ip_source = 'ip-api.com'
        if ($null -ne $r.lat -and $null -ne $r.lon) {
            $ipLat = [double]$r.lat
            $ipLon = [double]$r.lon
        }
    } else {
        $result.error = 'ip geolocation failed: ' + (StrOrEmpty $r.message)
    }
} catch {
    $result.error = 'ip geolocation failed: ' + $_.Exception.Message
}
$result.timings.ip_ms = [int]((New-TimeSpan -Start $ipStart -End (Get-Date)).TotalMilliseconds)

# Top-level coordinate-source availability summary (device + ip).
if ($null -ne $deviceLat -and $null -ne $ipLat) {
    $result.source.coord_source = 'device+ip'
} elseif ($null -ne $deviceLat) {
    $result.source.coord_source = 'device'
} elseif ($null -ne $ipLat) {
    $result.source.coord_source = 'ip'
} else {
    $result.source.coord_source = ''
}
# Primary machine coordinate: device wins, IP is the fallback for metadata only.
if ($null -ne $deviceLat) {
    $result.machine.latitude = $deviceLat
    $result.machine.longitude = $deviceLon
    $result.machine.accuracy = $deviceAcc
} elseif ($null -ne $ipLat) {
    $result.machine.latitude = $ipLat
    $result.machine.longitude = $ipLon
    $result.machine.accuracy = $null
}

# ---------------------------------------------------------------------------
# 3) MSN weather for BOTH coordinate pairs (same backend as the Windows Weather
#    app / taskbar widget). Each successful query becomes a candidate location.
# ---------------------------------------------------------------------------
$candidates = @()
$httpStart = Get-Date
if ($null -ne $deviceLat) {
    $e = Build-Entry $deviceLat $deviceLon 'device' $deviceAcc
    if ($null -ne $e) { $candidates += $e }
}
if ($null -ne $ipLat) {
    $e = Build-Entry $ipLat $ipLon 'ip' $null
    if ($null -ne $e) { $candidates += $e }
}
$result.timings.http_ms = [int]((New-TimeSpan -Start $httpStart -End (Get-Date)).TotalMilliseconds)
$result.timings.msn_attempts = $script:LastAttempts

# ---------------------------------------------------------------------------
# 4) Merge each candidate's forecast into its own stored history.
#    Previous locations are read from the last file (by location_text); the old
#    single-location format (top-level "days") is migrated into one synthetic
#    entry so existing history is not lost on the first upgrade run.
# ---------------------------------------------------------------------------
$prevLocs = @()
if (Test-Path -LiteralPath $OutPath) {
    try {
        $prevRaw = [System.IO.File]::ReadAllText($OutPath, [System.Text.Encoding]::UTF8)
        $prev = $prevRaw | ConvertFrom-Json
        if ($prev -and $prev.locations) {
            $prevLocs = @($prev.locations)
        } elseif ($prev -and $prev.days) {
            # Migration: earlier versions stored a single top-level location.
            $prevLocs = @(@{
                location_text = StrOrEmpty $prev.location.location_text
                coord_source = StrOrEmpty $prev.source.coord_source
                days = $prev.days
                hours = $prev.hours
            })
        }
    } catch { }
}

foreach ($entry in $candidates) {
    $prevDays = $null
    $prevHours = $null
    foreach ($pl in $prevLocs) {
        if ((StrOrEmpty $pl.location_text) -eq $entry.location_text) {
            $prevDays = $pl.days
            $prevHours = $pl.hours
            break
        }
    }
    $m = Merge-Days $prevDays $entry.w
    $entry.days = $m.list
    $entry.retain = @{
        back_days = $RetainBackDays
        first_date = $m.first
        last_date = $m.last
        days = $m.count
    }
    # Hourly: same retention rule, keyed "yyyy-MM-ddTHH". When the provider
    # sends no hourly arrays, Merge-Hours returns the previous history as-is
    # (possibly empty) and fetched=0 -- the game then shows daily only.
    $mh = Merge-Hours $prevHours $entry.w
    $entry.hours = $mh.list
    $entry.retain.hours = $mh.count
    $entry.retain.hours_fetched = $mh.fetched
    $entry.retain.first_hour = $mh.first
    $entry.retain.last_hour = $mh.last
    # Raw MSN node no longer needed -- drop it before serializing.
    $entry.Remove('w')
}

# ---------------------------------------------------------------------------
# 5) Dedupe by location_text (device candidate is added first, so it wins ties
#    when device and IP resolve to the same place), then write it out.
# ---------------------------------------------------------------------------
$seen = @{}
$locations = @()
foreach ($e in $candidates) {
    $lt = StrOrEmpty $e.location_text
    if ($seen.ContainsKey($lt)) { continue }
    $seen[$lt] = $true
    $locations += $e
}
$result.locations = $locations

if ($locations.Count -eq 0 -and -not $result.error) {
    if ($null -eq $deviceLat -and $null -eq $ipLat) {
        $result.error = 'no coordinates available (device and IP both failed)'
    } else {
        $result.error = $script:LastError
    }
}

$result.timings.total_ms = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
Save-Result $result

$locCount = $result.locations.Count
if ($result.error) {
    Write-Output ('LOCAL_WEATHER_FAIL ' + $result.error + ' (sources=' + ([string]$locCount) + ')')
} else {
    $summ = ($result.locations | ForEach-Object {
        (StrOrEmpty $_.location_text) + '(' + (StrOrEmpty $_.coord_source) + ')'
    }) -join ' | '
    Write-Output ('LOCAL_WEATHER_OK sources=' + ([string]$locCount) + ' [' + $summ + ']')
}
