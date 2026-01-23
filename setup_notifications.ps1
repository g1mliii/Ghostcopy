$ErrorActionPreference = "Stop"

$exePath = "C:\Users\subai\Documents\Ghostcopy\build\windows\x64\runner\Debug\ghostcopy.exe"
$shortcutName = "GhostCopy"
$programsPath = [Environment]::GetFolderPath("Programs")
$shortcutPath = "$programsPath\$shortcutName.lnk"

Write-Host "--- SETUP NOTIFICATIONS (IMPLICIT ID STRATEGY) ---"
Write-Host "Target Executable: $exePath"
Write-Host "Shortcut Path: $shortcutPath"

# 1. Ensure clean state
if (Test-Path $shortcutPath) {
    Write-Host "Shortcut exists. Deleting..."
    Remove-Item $shortcutPath -Force
}

# 2. Create basic helper shortcut
$WshShell = New-Object -comObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($shortcutPath)
$Shortcut.TargetPath = $exePath
$Shortcut.Save()

Write-Host "✅ Created standard shortcut at: $shortcutPath"
Write-Host "The app will now use Implicit AppID matching."
