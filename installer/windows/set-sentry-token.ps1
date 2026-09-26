<#
.SYNOPSIS
    Store the Sentry org auth token for this Windows account.

.DESCRIPTION
    Reads the token from the clipboard and writes it DPAPI-encrypted to
    %LOCALAPPDATA%\GhostCopy\sentry-auth-token, where build-store.ps1 reads it.
    DPAPI ties the file to this Windows account on this machine: copied
    elsewhere, or opened by another account, it is unreadable.

    The clipboard, not a prompt, for the same reason the macOS script uses
    pbpaste - an interactive console prompt truncates a long token silently,
    and a token cut short does not fail until the upload. Not a command-line
    parameter either, which would put the token in PSReadLine's plain-text
    history.

    This is a script rather than a snippet to paste because pasting a snippet
    replaces the token on the clipboard with the snippet - which is exactly
    what happened the first time. Run it by name with the token still copied.

.EXAMPLE
    # Copy the token from Sentry, then:
    installer\windows\set-sentry-token.ps1

.NOTES
    Create the token at https://spiderweb.sentry.io/settings/auth-tokens/
    with project:write (needed for `sentry-cli debug-files upload`).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$raw = Get-Clipboard -Raw
if ([string]::IsNullOrWhiteSpace($raw)) {
    throw 'The clipboard is empty. Copy the Sentry token, then run this again.'
}
$token = $raw.Trim()

# Validated rather than trusted, because every way this goes wrong is silent:
# the value is never echoed, and a bad one is not noticed until an upload
# fails during a release.
if ($token -match '\s') {
    throw 'The clipboard contains whitespace, so it is not a token. If you just copied a command to paste, copy the token itself and run this again.'
}
if ($token.Length -lt 32) {
    throw "The clipboard holds only $($token.Length) characters, which is too short for a Sentry token."
}
if ($token -notmatch '^[A-Za-z0-9_\-\.]+$') {
    throw 'The clipboard contains characters a Sentry token does not use. Copy the token itself and run this again.'
}

$dir = Join-Path $env:LOCALAPPDATA 'GhostCopy'
New-Item -ItemType Directory -Force $dir | Out-Null
$file = Join-Path $dir 'sentry-auth-token'

($token | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString) |
    Set-Content $file -NoNewline

# Read back, so a truncation or an encoding problem is caught here rather than
# mid-release.
$check = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        (Get-Content $file | ConvertTo-SecureString)))
if ($check -ne $token) {
    Remove-Item $file -Force
    throw 'The token did not survive the round trip and was not saved.'
}

Set-Clipboard ' '

$prefix = if ($token.Length -ge 7) { $token.Substring(0, 7) } else { '' }
Write-Host "Saved to $file" -ForegroundColor Green
Write-Host ("  {0} characters, starts '{1}', verified by reading it back." -f $token.Length, $prefix)
Write-Host '  Clipboard cleared.'
