<# Optional native test. Registers a disposable development package with a
   unique name and alias, exercises only help/MCP discovery, then removes it.
   Never replaces the installed GhostCopy package or its real alias. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackagePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\windows'))
$suffix = [guid]::NewGuid().ToString('N')
$identity = "GhostCopy.Test.$suffix"
$alias = "ghostcopy-smoke-$suffix.exe"
$staging = Join-Path $buildRoot "alias-smoke-$suffix"
if (-not $staging.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Invalid smoke-test directory.'
}
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($PackagePath), $staging)
    $source = [xml](Get-Content -LiteralPath (Join-Path $staging 'AppxManifest.xml') -Raw)
    # Exercise the production application/alias structure, changing only test
    # identity and removing unrelated OS integrations to avoid collisions.
    $source.Package.Identity.SetAttribute('Name', $identity)
    $source.Package.Identity.SetAttribute('Version', '1.0.0.0')
    $applications = @($source.SelectNodes('//*[local-name()="Applications"]/*'))
    if ($applications.Count -ne 1) { throw 'Expected one visible production application.' }
    $extensions = $applications[0].SelectSingleNode('*[local-name()="Extensions"]')
    foreach ($extension in @($extensions.ChildNodes)) {
        if ($extension.GetAttribute('Category') -ne 'windows.appExecutionAlias') {
            [void]$extensions.RemoveChild($extension)
        }
    }
    $aliasNode = $extensions.SelectSingleNode('.//*[local-name()="ExecutionAlias"]')
    if (-not $aliasNode) { throw 'Missing production execution alias.' }
    $aliasNode.SetAttribute('Alias', $alias)
    $source.Save((Join-Path $staging 'AppxManifest.xml'))
    Add-AppxPackage -Register (Join-Path $staging 'AppxManifest.xml')
    $aliasPath = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$alias"
    & (Join-Path $PSScriptRoot 'cli_binary_test.ps1') -Executable $aliasPath
    Write-Host 'Native Windows alias activation passed with a disposable package.'
}
finally {
    $registered = Get-AppxPackage -Name $identity
    if ($registered) { Remove-AppxPackage -Package $registered.PackageFullName }
    # The resolved target must still be exactly the directory this test owns.
    $resolved = (Resolve-Path -LiteralPath $staging).Path
    if ($resolved -eq $staging -and $resolved.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
