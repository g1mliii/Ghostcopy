<# Inspect the final archive, not just the pre-packaging build directory. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackagePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($PackagePath))
try {
    foreach ($name in @('ghostcopy.exe', 'ghostcopy-agent.exe', 'ghostcopy_shell.dll', 'AppxManifest.xml')) {
        if (-not $archive.GetEntry($name)) { throw "Package is missing $name" }
    }
    if (@($archive.Entries | Where-Object { $_.FullName -like '*.pdb' }).Count) {
        throw 'Debug symbols must not be shipped in the Store package.'
    }
    $reader = [IO.StreamReader]::new($archive.GetEntry('AppxManifest.xml').Open())
    try { $manifest = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    $ns = [Xml.XmlNamespaceManager]::new($manifest.NameTable)
    $ns.AddNamespace('p', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
    $ns.AddNamespace('uap3', 'http://schemas.microsoft.com/appx/manifest/uap/windows10/3')
    $ns.AddNamespace('desktop', 'http://schemas.microsoft.com/appx/manifest/desktop/windows10')
    $ns.AddNamespace('desktop4', 'http://schemas.microsoft.com/appx/manifest/desktop/windows10/4')
    $ns.AddNamespace('uap', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')
    $app = $manifest.SelectSingleNode('/p:Package/p:Applications/p:Application[@Id="ghostcopy"]', $ns)
    if (-not $app -or $app.GetAttribute('Executable') -ne 'ghostcopy.exe') { throw 'GUI identity changed.' }
    if (@($manifest.SelectNodes('/p:Package/p:Applications/p:Application', $ns)).Count -ne 1 -or
        $manifest.SelectSingleNode('//*[@AppListEntry="none"]') -or
        $app.HasAttribute('SupportsMultipleInstances', 'http://schemas.microsoft.com/appx/manifest/desktop/windows10/4') -or
        @($manifest.SelectNodes('//*[@Category="windows.appExecutionAlias"]')).Count -ne 1) {
        throw 'Require one visible GUI, no headless entries, one alias and unchanged GUI activation.'
    }
    $alias = $app.SelectSingleNode('p:Extensions/uap3:Extension[@Category="windows.appExecutionAlias"]', $ns)
    if (-not $alias -or $alias.GetAttribute('Executable') -ne 'ghostcopy-agent.exe' -or
        $alias.GetAttribute('EntryPoint') -ne 'Windows.FullTrustApplication' -or
        -not $alias.SelectSingleNode('uap3:AppExecutionAlias/desktop:ExecutionAlias[@Alias="ghostcopy.exe"]', $ns)) {
        throw 'Missing or incorrect console execution alias.'
    }
    foreach ($category in @('windows.protocol', 'windows.startupTask', 'windows.toastNotificationActivation', 'windows.fileExplorerContextMenus', 'windows.comServer')) {
        if (-not $app.SelectSingleNode("p:Extensions/*[@Category='$category']", $ns)) {
            throw "Existing Windows integration is missing: $category"
        }
    }
    $stream = $archive.GetEntry('ghostcopy-agent.exe').Open()
    $memory = [IO.MemoryStream]::new()
    try {
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
        if ([BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x4550 -or
            [BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0x8664 -or
            [BitConverter]::ToUInt16($bytes, $peOffset + 24 + 68) -ne 3) {
            throw 'Companion is not an x64 console executable.'
        }
    }
    finally { $stream.Dispose(); $memory.Dispose() }
    Write-Host "Verified MSIX $($manifest.Package.Identity.Version): GUI, console companion, alias and existing integrations." -ForegroundColor Green
}
finally { $archive.Dispose() }
