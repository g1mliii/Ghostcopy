<#
.SYNOPSIS
    Save a local, limited report about GhostCopy Microsoft Store updates.
.DESCRIPTION
    Run during "Almost done" and again after completion. Reads existing Windows
    events, matching WER metadata, and the current package/process state. Does
    not terminate processes, change logging, read app data, or upload anything.
    Only selected numeric/status fields are exported: raw Store events can
    contain account identifiers, so messages, command lines, paths, computer
    names, and user SIDs are deliberately excluded.
.PARAMETER Since
    Beginning of the event window (defaults to the last six hours).
.PARAMETER OutputPath
    New JSON file to create. Defaults to a timestamped file in the temp folder.
.EXAMPLE
    installer\windows\collect-update-diagnostics.ps1
#>
[CmdletBinding()]
param(
    [datetime]$Since = (Get-Date).AddHours(-6),
    [string]$OutputPath = (Join-Path ([IO.Path]::GetTempPath()) (
        'ghostcopy-update-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-SafeEventDetails {
    param([xml]$EventXml)

    $fields = [ordered]@{}
    $packages = @()
    foreach ($data in $EventXml.SelectNodes('//*[local-name()="EventData"]/*[local-name()="Data"]')) {
        $name = $data.GetAttribute('Name')
        $value = $data.InnerText
        $packages += @([regex]::Matches($value,
            'g1mli\.GhostCopy_\d+\.\d+\.\d+\.\d+_(?:x64|x86|arm64|neutral)__[a-z0-9]+') |
            ForEach-Object { $_.Value })
        if ($name -in @('DeploymentOperation', 'ErrorCode', 'Error Code', 'P6') -and
            $value -match '^(?:-?\d+|0x[0-9a-fA-F]+)$') {
            $fields[$name] = $value
        }
        if ($name -eq 'EventName' -and $value -in @('MoAppHang', 'AppHangB1', 'AppHangXProcB1', 'MoAppCrash', 'APPCRASH')) {
            $fields[$name] = $value
        }
        if ($name -eq 'Summary') {
            # A timing-only allowlist, rather than exporting arbitrary labels.
            $timings = @([regex]::Matches($value,
                '(?m)^\s*(Overall time|Active time|Enqueue cost|Dequeue delay|Bundle processing cost|Indexing cost|Resolve dependency cost|Check approval cost|Evaluation cost|Hardlinking evaluation cost|Stage required cost|Flushing and closing files cost|Gap|Machine register cost|Stage user data cost|Registration cost|Repository commit transaction cost|Data flush cost|Post DeStage repository commit transaction cost|Remaining cost): (\d+) ms') |
                ForEach-Object { [ordered]@{ stage = $_.Groups[1].Value; milliseconds = [long]$_.Groups[2].Value } })
            if ($timings.Count) { $fields['timings'] = $timings }
        }
        if ($name -eq 'Message') {
            $kind = [regex]::Match($value, '^\[Telemetry\]:\s*(\w+)')
            if ($kind.Success -and $kind.Groups[1].Value -in @('StartDownload', 'EndDownload', 'StartInstall',
                    'EndInstall', 'StateTransition', 'FulfillmentComplete')) {
                $fields['storeOperation'] = $kind.Groups[1].Value
            }
            foreach ($key in @('DownloadSize', 'DownloadDurationInMilliseconds', 'StageDurationInMilliseconds',
                    'HResult', 'ExtendedHResult', 'completePercent', 'downloadedBytes', 'readyForLaunch',
                    'InstallState', 'PrevState', 'NewState', 'installType')) {
                # Extract only a single token and validate its type. Never copy
                # embedded PluginTelemetryData/UserIdentityInfo or other JSON.
                $match = [regex]::Match($value, '(?i)(?<![\w"])' + $key + '\s*[:=]\s*([\w.-]+)')
                if ($match.Success) {
                    $token = $match.Groups[1].Value
                    if ($token -match '^(?:-?\d+|0x[0-9a-fA-F]+|True|False|Pending|Downloading|Installing|Completed|Error|Canceled|Working|Update|Install)$') {
                        $fields[$key] = $token
                    }
                }
            }
        }
    }
    $fields['packages'] = @($packages | Sort-Object -Unique)
    return $fields
}

function Get-HangExecutable {
    param([xml]$EventXml)

    $node = $EventXml.SelectSingleNode('//*[local-name()="Data"][@Name="StorePath"]')
    if ($null -eq $node) { return $null }
    # Only open Windows' own matching WER report; never export its full text.
    $archiveRoot = Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'
    $folder = [IO.Path]::GetFullPath(($node.InnerText -replace '^\\\\\?\\', ''))
    if (-not $folder.StartsWith($archiveRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($folder) -notlike '*g1mli.GhostCopy*') { return $null }
    $report = Join-Path $folder 'Report.wer'
    if (-not (Test-Path -LiteralPath $report -PathType Leaf)) { return $null }
    foreach ($line in Get-Content -LiteralPath $report) {
        if ($line -match '^AppPath=(.*)$') {
            $executable = [IO.Path]::GetFileName($Matches[1])
            if ($executable -in @('ghostcopy.exe', 'dllhost.exe')) { return $executable }
        }
    }
    return $null
}

if ($Since -gt (Get-Date)) { throw 'Since must not be in the future.' }
if (Test-Path -LiteralPath $OutputPath) { throw 'Choose a new output file; existing reports are not overwritten.' }

$warnings = [Collections.Generic.List[string]]::new()
$events = [Collections.Generic.List[object]]::new()
$packages = @()
try {
    $packages = @(Get-AppxPackage -Name 'g1mli.GhostCopy' | ForEach-Object {
        [ordered]@{ package = $_.PackageFullName; version = $_.Version.ToString(); status = $_.Status.ToString() }
    })
} catch { $warnings.Add('Installed package state could not be read.') }

foreach ($log in @('Microsoft-Windows-AppXDeploymentServer/Operational', 'Microsoft-Windows-Store/Operational', 'Application')) {
    try {
        $filter = @{ LogName = $log; StartTime = $Since }
        if ($log -eq 'Application') { $filter['ProviderName'] = 'Windows Error Reporting'; $filter['Id'] = 1001 }
        # Bound memory/read time and explicitly mark an incomplete time window.
        $records = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 10000)
        if ($records.Count -eq 10000) { $warnings.Add("Event limit reached for $log; use a narrower Since window.") }
        $activities = @{}
        foreach ($record in $records) {
            $activity = [string]$record.ActivityId
            if ($record.ToXml() -match 'g1mli\.GhostCopy' -and $activity -and $activity -ne [guid]::Empty.ToString()) {
                $activities[$activity] = $true
            }
        }
        foreach ($record in $records) {
            $xmlText = $record.ToXml()
            $activity = [string]$record.ActivityId
            if ($xmlText -notmatch 'g1mli\.GhostCopy|9NW0TTGMSF80' -and
                -not $activities.ContainsKey($activity)) { continue }
            $eventXml = [xml]$xmlText
            $details = Get-SafeEventDetails $eventXml
            if ($log -eq 'Application') {
                try { $details['executable'] = Get-HangExecutable $eventXml }
                catch { $warnings.Add('A matching WER report could not be read.') }
            }
            $events.Add([ordered]@{
                timeUtc = $record.TimeCreated.ToUniversalTime().ToString('o')
                log = $log
                eventId = $record.Id
                activityId = $activity
                details = $details
            })
        }
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            $warnings.Add("Could not read $log; the report is partial.")
        }
    }
}

$processes = @()
$unreadableHosts = 0
foreach ($process in @(Get-Process -Name 'ghostcopy', 'dllhost' -ErrorAction SilentlyContinue)) {
    try {
        $shellLoaded = @($process.Modules | Where-Object { $_.ModuleName -eq 'ghostcopy_shell.dll' }).Count -gt 0
        if ($process.ProcessName -eq 'ghostcopy' -or $shellLoaded) {
            $processes += [ordered]@{
                executable = $process.ProcessName + '.exe'
                processId = $process.Id
                shellExtensionLoaded = $shellLoaded
                startedUtc = $process.StartTime.ToUniversalTime().ToString('o')
            }
        }
    } catch {
        if ($process.ProcessName -eq 'dllhost') { $unreadableHosts++ }
        else { $warnings.Add('A GhostCopy process exited or could not be inspected.') }
    }
}

$report = [ordered]@{
    schemaVersion = 1
    capturedUtc = [datetime]::UtcNow.ToString('o')
    sinceUtc = $Since.ToUniversalTime().ToString('o')
    windowsVersion = [Environment]::OSVersion.Version.ToString()
    installedPackages = $packages
    processes = $processes
    unreadableComHosts = $unreadableHosts
    events = @($events | Sort-Object { $_.timeUtc })
    warnings = @($warnings | Select-Object -Unique)
}
$json = $report | ConvertTo-Json -Depth 10
# CreateNew also prevents overwriting a file created after the initial check.
$stream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream.Write($bytes, 0, $bytes.Length)
} finally { $stream.Dispose() }
Write-Host "Saved local report: $OutputPath"
Write-Host ('{0} matching events; {1} warning(s). Nothing uploaded.' -f $events.Count, $report.warnings.Count)
