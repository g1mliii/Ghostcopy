<# Exercise the compiled CLI or a registered alias without reading or sending user data. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Executable)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Invoke-Companion {
    param([string]$Arguments, [string[]]$InputLines = @())
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        foreach ($line in $InputLines) { $process.StandardInput.WriteLine($line) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            throw 'Companion did not exit after stdin closed.'
        }
        return @{ Code = $process.ExitCode; Output = $output.GetAwaiter().GetResult(); Error = $errors.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}
$help = Invoke-Companion '--help'
if ($help.Code -ne 0 -or $help.Output -notmatch 'ghostcopy mcp' -or $help.Error) {
    throw 'The console help command did not return cleanly over redirected pipes.'
}
$mcp = Invoke-Companion 'mcp' @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"packaging-smoke","version":"1"}}}',
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
)
if ($mcp.Code -ne 0 -or $mcp.Error) { throw "MCP failed: $($mcp.Error)" }
$replies = @($mcp.Output -split '\r?\n' | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
if ($replies.Count -ne 2) { throw 'MCP stdout contains extra output or is missing replies.' }
$initialize = $replies | Where-Object { $_.id -eq 1 }
$tools = $replies | Where-Object { $_.id -eq 2 }
if ($initialize.result.protocolVersion -ne '2025-06-18' -or
    (($tools.result.tools.name | Sort-Object) -join ',') -ne 'list_devices,send_file,send_text') {
    throw 'MCP initialization or tool discovery returned the wrong contract.'
}
$usage = Invoke-Companion 'unknown-command --json'
if ($usage.Code -ne 1) { throw 'The CLI did not propagate its usage-error exit code.' }
Write-Host 'Compiled CLI/MCP passed: help, piped JSON-RPC, tool discovery, EOF and exit codes.'
