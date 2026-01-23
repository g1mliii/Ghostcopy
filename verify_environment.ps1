$ErrorActionPreference = "Stop"
$shortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\GhostCopy.lnk"

Write-Host "--- ENVIRONMENT VERIFICATION ---"

# 1. Shortcut Check
if (Test-Path $shortcutPath) {
    Write-Host "✅ Shortcut exists at: $shortcutPath"
    $WshShell = New-Object -comObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($shortcutPath)
    Write-Host "Target Path: $($Shortcut.TargetPath)"
} else {
    Write-Host "❌ Shortcut MISSING at: $shortcutPath"
}

# 2. Focus Assist / Notification Settings
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"
Write-Host "`n--- NOTIFICATION REGISTRY SETTINGS ---"
Get-ItemProperty $regPath | Select-Object * | Format-List

# 3. Check for specific app suppression
$appRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\com.ghostcopy.app"
if (Test-Path $appRegPath) {
    Write-Host "Found specific settings for 'com.ghostcopy.app':"
    Get-ItemProperty $appRegPath | Select-Object * | Format-List
} else {
    Write-Host "No specific registry overrides for 'com.ghostcopy.app' (Good for defaults)."
}
