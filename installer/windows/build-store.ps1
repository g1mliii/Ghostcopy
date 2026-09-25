<#
.SYNOPSIS
    Build the Microsoft Store package, and upload its debug symbols to Sentry.

.DESCRIPTION
    The Windows counterpart to installer/macos/build-release.sh. Three steps,
    in an order that matters: build, upload symbols, package.

    Symbols go up BEFORE the package is made, for the same reason the macOS
    script does it during the build - the PDBs exist only as long as the build
    output does, and a package shipped without its symbols already uploaded is
    one whose first crash report cannot be read. Nothing recreates them later
    except an identical rebuild, and "identical" is not something to rely on.

    The PDBs are NOT in the package. windows/runner/CMakeLists.txt writes them
    to build/windows/x64/symbols, outside the bundle msix packs, so users do
    not download them.

.PARAMETER SkipSymbols
    Package without uploading symbols. For a local packaging test only - never
    for a build that goes to the Store, whose crash reports would then stay as
    raw addresses forever.

.EXAMPLE
    installer\windows\build-store.ps1

.NOTES
    One-time setup, both on any machine that makes a Store build:

    1. sentry-cli:
           winget install --id Sentry.sentry-cli --exact
       or  npm install -g @sentry/cli

       winget installs the alias as `sentry`, npm as `sentry-cli`. Both are
       the same binary and this script accepts either.

    2. The Sentry org auth token. Create it at
       https://spiderweb.sentry.io/settings/auth-tokens/ with project:write,
       copy it, and then run:

           installer\windows\set-sentry-token.ps1

       Run it by name with the token still on the clipboard - do not paste a
       snippet that reads the clipboard, because copying the snippet is what
       replaces the token with the snippet. That script validates what it
       stores and reads it back, so a truncated or wrong value fails there
       rather than during a release.

    The token is never committed, never passed on a command line, and never
    written to the build log.
#>
[CmdletBinding()]
param(
    [switch]$SkipSymbols
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot
try {
    $symbolsDir = Join-Path $repoRoot 'build\windows\x64\symbols'
    $tokenFile = Join-Path $env:LOCALAPPDATA 'GhostCopy\sentry-auth-token'

    Write-Host '==> Building Windows release' -ForegroundColor Cyan
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }

    # A silent change to the link settings is exactly the kind of thing that
    # would go unnoticed until the first unreadable crash report, so it is
    # checked rather than assumed.
    $pdbs = @(Get-ChildItem $symbolsDir -Filter '*.pdb' -ErrorAction SilentlyContinue)
    if ($pdbs.Count -eq 0) {
        throw "No PDBs in $symbolsDir. The release link should produce them - see the /DEBUG note in windows/runner/CMakeLists.txt."
    }
    Write-Host ("    {0} symbol file(s): {1}" -f $pdbs.Count, ($pdbs.Name -join ', '))

    if ($SkipSymbols) {
        Write-Warning 'Skipping symbol upload (-SkipSymbols). Do NOT submit this package.'
    }
    else {
        Write-Host '==> Uploading debug symbols to Sentry' -ForegroundColor Cyan
        # winget registers the alias as `sentry`, npm as `sentry-cli`. Same
        # binary; which one exists depends only on how it was installed, so
        # accept either rather than making the release depend on that choice.
        $sentry = @('sentry-cli', 'sentry') |
            ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
            Select-Object -First 1
        if (-not $sentry) {
            throw 'Neither sentry-cli nor sentry found on PATH. See the setup notes at the top of this script.'
        }
        if (-not (Test-Path $tokenFile)) {
            throw "No Sentry token at $tokenFile. Run installer\windows\set-sentry-token.ps1 with the token on the clipboard."
        }

        # Decrypted here and put in the environment for the child process only,
        # so it never appears in a command line or in this session's history.
        $secure = Get-Content $tokenFile | ConvertTo-SecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        try {
            $env:SENTRY_AUTH_TOKEN = $plain
            & $sentry.Source debug-files upload --org spiderweb --project flutter --wait $symbolsDir
            if ($LASTEXITCODE -ne 0) { throw "$($sentry.Name) upload failed ($LASTEXITCODE)" }
        }
        finally {
            Remove-Item Env:\SENTRY_AUTH_TOKEN -ErrorAction SilentlyContinue
            $plain = $null
        }
    }

    Write-Host '==> Packaging MSIX for the Store' -ForegroundColor Cyan
    # --build-windows false: the build above is the one the symbols were taken
    # from, and letting msix rebuild would risk packaging a binary whose PDBs
    # were never uploaded.
    dart run msix:create --store --build-windows false
    if ($LASTEXITCODE -ne 0) { throw "msix:create failed ($LASTEXITCODE)" }

    $msix = Join-Path $repoRoot 'build\windows\x64\runner\Release\ghostcopy.msix'
    Write-Host ''
    Write-Host "Done: $msix" -ForegroundColor Green
    Write-Host 'Upload it under Packages in the Partner Center submission.'
}
finally {
    Pop-Location
}
