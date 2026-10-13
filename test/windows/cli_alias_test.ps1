# Regression check: preserve the GUI's registrations and make alias patching idempotent.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ghostcopy-alias-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $path = Join-Path $temporary 'AppxManifest.xml'
    @'
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
 xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
 xmlns:desktop="http://schemas.microsoft.com/appx/manifest/desktop/windows10"
 IgnorableNamespaces="desktop">
 <Applications><Application Id="ghostcopy" Executable="ghostcopy.exe" EntryPoint="Windows.FullTrustApplication">
 <uap:VisualElements DisplayName="GhostCopy" />
 <Extensions><uap:Extension Category="windows.protocol"><uap:Protocol Name="ghostcopy" /></uap:Extension>
 <desktop:Extension Category="windows.startupTask" Executable="ghostcopy.exe" />
 </Extensions></Application></Applications>
</Package>
'@ | Set-Content -LiteralPath $path -Encoding UTF8
    & "$repoRoot/installer/windows/set-cli-alias.ps1" -ManifestPath $path
    & "$repoRoot/installer/windows/set-cli-alias.ps1" -ManifestPath $path
    $document = [xml](Get-Content -LiteralPath $path -Raw)
    $aliases = @($document.SelectNodes('//*[@Category="windows.appExecutionAlias"]'))
    if ($aliases.Count -ne 1 -or $aliases[0].GetAttribute('Executable') -ne 'ghostcopy-agent.exe') {
        throw 'Alias patch is not idempotent or targets the GUI.'
    }
    if ($document.SelectSingleNode('//*[@AppListEntry="none"]') -or
        @($document.SelectNodes('//*[local-name()="Application"]')).Count -ne 1) {
        throw 'Store packages must not introduce a headless application.'
    }
    if ($document.SelectSingleNode('//*[@Id="ghostcopy"]').GetAttribute('Executable') -ne 'ghostcopy.exe' -or
        -not $document.SelectSingleNode('//*[@Name="ghostcopy"]') -or
        -not $document.SelectSingleNode('//*[@Category="windows.startupTask"]')) {
        throw 'Patching removed an existing GUI integration.'
    }
    $guiExtensions = $document.SelectSingleNode('//*[@Id="ghostcopy"]/*[local-name()="Extensions"]')
    $conflict = $aliases[0].CloneNode($true)
    $conflict.SetAttribute('Executable', 'other.exe')
    [void]$guiExtensions.AppendChild($conflict)
    $document.Save($path)
    $rejected = $false
    try { & "$repoRoot/installer/windows/set-cli-alias.ps1" -ManifestPath $path }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'A conflicting alias was silently replaced.' }
    Write-Host 'CLI alias manifest regression checks passed.'
}
finally {
    # Only the one file and empty directory created by this test.
    Remove-Item -LiteralPath (Join-Path $temporary 'AppxManifest.xml') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporary
}
