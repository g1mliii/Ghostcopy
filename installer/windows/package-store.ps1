<# Package an already-built Windows release, including the CLI/MCP companion.
   Does not rebuild the GUI, upload symbols, sign, install or publish anything.
   For Store submissions use build-store.ps1, which uploads symbols first. #>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bundle = Join-Path $repoRoot 'build\windows\x64\runner\Release'
Push-Location $repoRoot
try {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle 'ghostcopy.exe'))) {
        throw 'Build the Windows release first.'
    }
    Write-Host '==> Compiling the CLI/MCP companion' -ForegroundColor Cyan
    Push-Location (Join-Path $repoRoot 'packages\ghostcopy_agent')
    try {
        dart pub get
        if ($LASTEXITCODE -ne 0) { throw 'Companion dependency resolution failed.' }
        dart compile exe bin/ghostcopy.dart -o (Join-Path $bundle 'ghostcopy-agent.exe')
        if ($LASTEXITCODE -ne 0) { throw 'Companion compilation failed.' }
    }
    finally { Pop-Location }
    & (Join-Path $repoRoot 'test\windows\cli_binary_test.ps1') -Executable (Join-Path $bundle 'ghostcopy-agent.exe')
    # Separate build/pack is the supported custom-manifest workflow. A later
    # msix:create would regenerate the XML and lose the console alias.
    dart run msix:build --store --build-windows false
    if ($LASTEXITCODE -ne 0) { throw 'msix:build failed.' }
    & (Join-Path $PSScriptRoot 'set-cli-alias.ps1') -ManifestPath (Join-Path $bundle 'AppxManifest.xml')
    dart run msix:pack --store --build-windows false
    if ($LASTEXITCODE -ne 0) { throw 'msix:pack failed.' }
    & (Join-Path $PSScriptRoot 'verify-store-package.ps1') -PackagePath (Join-Path $bundle 'ghostcopy.msix')
}
finally { Pop-Location }
