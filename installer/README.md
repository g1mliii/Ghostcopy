# GhostCopy Installer

This directory contains the installation packaging scripts for GhostCopy.

## Prerequisites

### For Inno Setup (Traditional .exe Installer)
1. Download and install Inno Setup: https://jrsoftware.org/isdl.php
2. Optional: Install Inno Setup Preprocessor for advanced features

### For MSIX (Windows Store Package)
1. Install `msix` package:
   ```bash
   flutter pub add msix
   ```

## Building the Installer

### Option 1: Inno Setup (.exe installer)

1. Build the Flutter app in release mode:
   ```bash
   flutter build windows --release
   ```

2. Compile the Inno Setup script:
   ```bash
   # Using Inno Setup GUI
   - Open ghostcopy.iss in Inno Setup Compiler
   - Click Build > Compile

   # OR using command line
   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\ghostcopy.iss
   ```

3. Output: `build\installer\ghostcopy-setup-1.0.0.exe`

### Option 2: MSIX (Windows Store package)

1. Build MSIX package:
   ```bash
   flutter pub run msix:create
   ```

2. Output: `build\windows\x64\runner\Release\ghostcopy.msix`

## Installation Locations

### Program Files
- **Executable:** `C:\Program Files\GhostCopy\ghostcopy.exe`

### User Data
- **Settings:** `%APPDATA%\Roaming\com.ghostcopy\shared_preferences.json`
- **Credentials:** Windows Credential Manager (flutter_secure_storage_*)
- **Auto-start:** `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\GhostCopy`

## Uninstall Cleanup

The uninstaller removes **EVERYTHING**:
- ✅ Application files in Program Files
- ✅ Settings in AppData\Roaming
- ✅ Cache in LocalAppData
- ✅ Credentials in Windows Credential Manager
- ✅ Auto-start registry entry
- ✅ Temp files

**Zero traces left behind.**

## Code Signing (Optional but Recommended)

To sign the installer:

1. Get a code signing certificate (DigiCert, Sectigo, etc.)

2. Sign the executable before packaging:
   ```bash
   signtool sign /f certificate.pfx /p password /t http://timestamp.digicert.com build\windows\x64\runner\Release\ghostcopy.exe
   ```

3. Sign the installer:
   ```bash
   signtool sign /f certificate.pfx /p password /t http://timestamp.digicert.com build\installer\ghostcopy-setup-1.0.0.exe
   ```

4. For MSIX, signing is required:
   ```bash
   flutter pub run msix:create --certificate-path certificate.pfx --certificate-password password
   ```

## Testing Uninstall Cleanup

To verify complete cleanup:

1. Install GhostCopy
2. Run the app and configure settings
3. Check these locations exist:
   - `C:\Program Files\GhostCopy\`
   - `%APPDATA%\Roaming\com.ghostcopy\`
   - Registry: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\GhostCopy`
   - Credential Manager: `cmdkey /list | findstr flutter`

4. Uninstall via "Add or Remove Programs"
5. Verify ALL locations are gone (use Revo Uninstaller to double-check)
