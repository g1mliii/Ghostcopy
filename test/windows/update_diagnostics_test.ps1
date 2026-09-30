# Standalone PowerShell assertions; no Pester installation required.
# Load only the parser function, without executing the collector's OS reads.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'installer\windows\collect-update-diagnostics.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Collector has syntax errors.' }
$parser = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SafeEventDetails'
}, $true)
. ([scriptblock]::Create($parser.Extent.Text))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$xml = [xml]@'
<Event><EventData>
<Data Name="PackageFullName">g1mli.GhostCopy_1.0.16.0_x64__41asz506sbn22</Data>
<Data Name="ErrorCode">0x0</Data>
<Data Name="Summary">
Overall time: 91687 ms (Active time: 91672 ms)
Gap: 91375 ms
Registration cost: 94 ms
Gap: 31 ms
private-account: 123 ms
</Data>
<Data Name="Message">[Telemetry]: EndDownload :: ProductId = 9NW0TTGMSF80 DownloadSize = 5088758 StageDurationInMilliseconds = 10236 HResult = 0 PluginTelemetryData = {"UserIdentityInfo":"private-account","file":"private-file"}</Data>
<Data Name="UserID">private-sid</Data>
<Data Name="CommandLine">private-file</Data>
</EventData></Event>
'@
$details = Get-SafeEventDetails $xml
Assert-True ($details.packages.Count -eq 1) 'Expected the GhostCopy package.'
Assert-True ($details.timings.Count -eq 4) 'Expected timing allowlist and repeated gaps.'
Assert-True ($details.timings[1].milliseconds -eq 91375) 'Lost the servicing delay.'
Assert-True ($details.storeOperation -eq 'EndDownload') 'Download and install stages must be distinguishable.'
Assert-True ($details.StageDurationInMilliseconds -eq '10236') 'Lost download duration.'
Assert-True ($details.HResult -eq '0') 'Lost operation result.'
Assert-True (($details | ConvertTo-Json -Depth 8) -notmatch 'private-|UserIdentityInfo|CommandLine|UserID') 'Exported private event data.'

$progress = Get-SafeEventDetails ([xml]'<Event><EventData><Data Name="Message">InstallState: Completed completePercent: 100 readyForLaunch: True installType: Update</Data></EventData></Event>')
Assert-True ($progress.InstallState -eq 'Completed' -and $progress.readyForLaunch -eq 'True') 'Lost Store completion state.'
$rejected = Get-SafeEventDetails ([xml]'<Event><EventData><Data Name="Message">HResult = private-account InstallState: private-file</Data><Data Name="ErrorCode">private-secret</Data><Data Name="EventName">private-event</Data></EventData></Event>')
Assert-True (($rejected | ConvertTo-Json) -notmatch 'private-') 'Unvalidated status field was exported.'
$empty = Get-SafeEventDetails ([xml]'<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData/></Event>')
Assert-True ($empty.packages.Count -eq 0) 'Empty events should be accepted.'
$hang = Get-SafeEventDetails ([xml]'<Event><EventData><Data Name="EventName">MoAppHang</Data><Data Name="P6">2097152</Data></EventData></Event>')
Assert-True ($hang.EventName -eq 'MoAppHang' -and $hang.P6 -eq '2097152') 'Lost the hang type.'
Write-Host 'Update diagnostics parser assertions passed.'
