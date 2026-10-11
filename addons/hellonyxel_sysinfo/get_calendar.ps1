# get_calendar.ps1
# ---------------------------------------------------------------------------
# Read THIS PC's calendars and write them as JSON for the game (calendar panel).
#
# Data source: the Windows Runtime AppointmentStore API
#   (Windows.ApplicationModel.Appointments) -- the SAME store that powers the
#   built-in Windows "Calendar" / "Mail and Calendar" app. So what the game
#   stores is exactly the player's own device calendar appointments.
#
#   !! IMPORTANT real-world constraint: the AppointmentStore API is a UWP
#   capability. On a NON-PACKAGED Win32 process (this script is launched by
#   powershell.exe directly, not inside a packaged app) Windows will typically
#   only grant an EMPTY store -- RequestStoreAsync(AllCalendarsReadOnly) either
#   throws UnauthorizedAccessException or returns a store with zero calendars.
#   We therefore treat "no data" as a SUCCESSFUL-but-empty result: the file is
#   still written (valid JSON, events = []), and the panel simply shows "no
#   device calendar available". This keeps the game robust instead of erroring.
#   If the game is ever shipped as a packaged/bridged app the same code will
#   start returning real appointments with no change.
#
# Output file (UTF-8, no BOM, written atomically via .tmp + Move-Item):
#   %Documents%\HelloNyxel\settings\device_calendar.json
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads a .ps1 that has
#       no BOM as ANSI, so any non-ASCII byte here would be garbled into syntax
#       errors. All non-ASCII text (subjects, locations) comes from the device
#       calendar responses, decoded as UTF-8 at runtime.
#
# Usage:
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File get_calendar.ps1 \
#       -OutPath "D:\Documents\HelloNyxel\settings\device_calendar.json"
# ---------------------------------------------------------------------------
param(
    [Parameter(Mandatory = $true)][string]$OutPath,
    [int]$Days = 60,
    [int]$PastDays = 7,
    [int]$MaxCount = 1000
)

$ErrorActionPreference = 'Continue'

$scriptStart = Get-Date
$nowText = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$result = @{
    updated_at = $nowText
    updated_epoch = [int64](([datetime]::UtcNow - [datetime]'1970-01-01T00:00:00').TotalSeconds)
    error = ''
    available = $false
    source = @{
        provider = 'Windows.ApplicationModel.Appointments.AppointmentStore'
        access = 'AllCalendarsReadOnly'
        note = ''
    }
    # Each event: id, subject, start, end, all_day, location, details,
    #              busy_status, sensitivity, calendar_name, reminder_min
    events = @()
    timings = @{
        total_ms = 0
    }
}

$script:LastError = ''

# JSON-safe scalar helpers.
function StrOrEmpty {
    param($v)
    if ($null -eq $v) { return '' }
    return [string]$v
}

# Await a WinRT IAsyncOperation<T> by converting it to a .NET Task and blocking.
# Requires System.Runtime.WindowsRuntime to be loaded (AsTask extension).
function Await {
    param($Task)
    $netTask = $Task.AsTask()
    $netTask.Wait()
    return $netTask.Result
}

# Atomic write (mirror get_local_weather.ps1 Save-Result).
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
# 1) Load the Windows Runtime and request the appointment store.
# ---------------------------------------------------------------------------
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
} catch {
    $result.error = 'Windows Runtime not available: ' + $_.Exception.Message
    $result.source.note = 'System.Runtime.WindowsRuntime could not be loaded'
    $result.timings.total_ms = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
    Save-Result $result
    Write-Output ('DEVICE_CALENDAR_EMPTY no-winrt')
    return
}

# ---------------------------------------------------------------------------
# 2) Request a read-only store over ALL calendars.
# ---------------------------------------------------------------------------
$store = $null
try {
    $access = [Windows.ApplicationModel.Appointments.AppointmentStoreAccessType]::AllCalendarsReadOnly
    $store = Await ([Windows.ApplicationModel.Appointments.AppointmentManager]::RequestStoreAsync($access))
} catch {
    $result.error = 'RequestStoreAsync failed: ' + $_.Exception.Message
    $result.source.note = 'appointment store access denied (non-packaged process)'
    $result.timings.total_ms = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
    Save-Result $result
    Write-Output ('DEVICE_CALENDAR_EMPTY store-denied')
    return
}

if ($null -eq $store) {
    $result.error = 'appointment store is null'
    $result.source.note = 'RequestStoreAsync returned null (non-packaged process)'
    $result.timings.total_ms = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
    Save-Result $result
    Write-Output ('DEVICE_CALENDAR_EMPTY store-null')
    return
}

$result.available = $true

# ---------------------------------------------------------------------------
# 3) Build a calendar-id -> display-name map (best effort).
# ---------------------------------------------------------------------------
$calName = @{}
try {
    $cals = Await ($store.FindAppointmentCalendarsAsync())
    foreach ($c in @($cals)) {
        if ($c -and $c.LocalId) {
            $calName[[string]$c.LocalId] = StrOrEmpty $c.DisplayName
        }
    }
} catch {
    $script:LastError = 'enumerate calendars failed: ' + $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 4) Query appointments across the window [now - PastDays, now + Days].
# ---------------------------------------------------------------------------
$events = @()
try {
    $opts = New-Object Windows.ApplicationModel.Appointments.FindAppointmentsOptions
    try { $opts.FetchStartTime = $true } catch { }
    try { $opts.FetchLocation = $true } catch { }
    try { $opts.MaxCount = [uint32]$MaxCount } catch { }

    $start = [datetime]::Now.Date.AddDays(-1 * [math]::Max(0, $PastDays))
    $range = [TimeSpan]::FromDays([math]::Max(1, $Days + $PastDays))
    $appts = Await ($store.FindAppointmentsAsync($start, $range, $opts))

    foreach ($a in @($appts)) {
        if ($null -eq $a) { continue }
        $subject = StrOrEmpty $a.Subject
        $startDt = $a.StartTime
        $startIso = ''
        if ($startDt) { $startIso = $startDt.ToString('yyyy-MM-ddTHH:mm:ss') }
        $endIso = ''
        $dur = $a.Duration
        if ($startDt -and $dur) {
            $endIso = ($startDt.Add($dur)).ToString('yyyy-MM-ddTHH:mm:ss')
        }
        $reminderMin = $null
        try {
            if ($a.Reminder -and $a.Reminder.HasValue) {
                $reminderMin = [int]$a.Reminder.Value.TotalMinutes
            }
        } catch { }
        $calId = StrOrEmpty $a.CalendarId
        $calDisplayName = ''
        if ($calName.ContainsKey($calId)) { $calDisplayName = $calName[$calId] }
        # Stable id: calendarId + subject + start (appointment has no public Id here).
        $evId = ($calId + '|' + $subject + '|' + $startIso)
        $events += @{
            id = $evId
            subject = $subject
            start = $startIso
            end = $endIso
            all_day = [bool]$a.AllDay
            location = StrOrEmpty $a.Location
            details = StrOrEmpty $a.Details
            busy_status = StrOrEmpty $a.BusyStatus
            sensitivity = StrOrEmpty $a.Sensitivity
            calendar_name = $calDisplayName
            reminder_min = $reminderMin
        }
    }
} catch {
    $result.error = 'FindAppointmentsAsync failed: ' + $_.Exception.Message
    $result.source.note = 'query threw; returning whatever was collected'
}

$result.events = $events
if ($events.Count -eq 0 -and -not $result.error) {
    $result.source.note = 'store opened but no appointments readable (non-packaged access)'
}

$result.timings.total_ms = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
Save-Result $result

$evCount = $result.events.Count
if ($result.error) {
    Write-Output ('DEVICE_CALENDAR_PARTIAL events=' + ([string]$evCount) + ' error=' + $result.error)
} else {
    Write-Output ('DEVICE_CALENDAR_OK events=' + ([string]$evCount))
}
