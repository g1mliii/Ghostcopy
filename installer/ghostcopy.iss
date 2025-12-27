; GhostCopy Installer Script for Inno Setup
; Complete install/uninstall with ZERO traces left behind

#define MyAppName "GhostCopy"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "GhostCopy"
#define MyAppURL "https://github.com/yourusername/ghostcopy"
#define MyAppExeName "ghostcopy.exe"

[Setup]
; Basic App Info
AppId={{A5B3C2D1-E4F5-6789-ABCD-EF0123456789}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}

; Install Location
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes

; Output
OutputDir=..\build\installer
OutputBaseFilename=ghostcopy-setup-{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes

; Modern UI
WizardStyle=modern
SetupIconFile=..\assets\icons\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

; Privileges
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog

; Architecture
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

; Misc
DisableWelcomePage=no
LicenseFile=..\LICENSE
InfoBeforeFile=..\README.md

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startup"; Description: "Launch GhostCopy at Windows startup"; GroupDescription: "Startup Options:"; Flags: checkedonce

[Files]
; Main executable
Source: "..\build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
Source: "..\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Run the app after install (hidden, background mode)
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; Set auto-start if requested
Filename: "reg"; Parameters: "add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v {#MyAppName} /t REG_SZ /d ""{app}\{#MyAppExeName}"" /f"; Tasks: startup; Flags: runhidden

[UninstallRun]
; Kill running process before uninstall
Filename: "taskkill"; Parameters: "/F /IM {#MyAppExeName}"; Flags: runhidden; RunOnceId: "KillGhostCopy"

; Remove auto-start registry entry
Filename: "reg"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v {#MyAppName} /f"; Flags: runhidden; RunOnceId: "RemoveAutoStart"

; Clear Windows Credential Manager entries (Flutter Secure Storage)
Filename: "powershell"; Parameters: "-ExecutionPolicy Bypass -Command ""& {{ cmdkey /list | Select-String 'flutter_secure_storage' | ForEach-Object {{ $target = ($_ -split ':')[1].Trim(); cmdkey /delete:$target }} }}"""; Flags: runhidden waituntilterminated; RunOnceId: "ClearCredentials"

[UninstallDelete]
; Delete application folder
Type: filesandordirs; Name: "{app}"

; Delete SharedPreferences (Flutter auto-created in AppData\Roaming)
Type: filesandordirs; Name: "{userappdata}\com.ghostcopy"

; Delete any cache files in LocalAppData
Type: filesandordirs; Name: "{localappdata}\GhostCopy"

; Delete any temp files
Type: filesandordirs; Name: "{tmp}\ghostcopy_*"

[Code]
// Check if app is running before install/uninstall
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  // Try to kill running process
  Exec('taskkill', '/F /IM {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  Result := True;
end;

function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
begin
  // Confirm complete removal
  if MsgBox('This will completely remove GhostCopy and all its data, including:' + #13#10 +
            '- Application files' + #13#10 +
            '- Settings and preferences' + #13#10 +
            '- Stored credentials' + #13#10 +
            '- Auto-start configuration' + #13#10 + #13#10 +
            'Continue with uninstall?', mbConfirmation, MB_YESNO) = IDYES then
  begin
    // Kill the process
    Exec('taskkill', '/F /IM {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Result := True;
  end
  else
    Result := False;
end;

// Show completion message
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    // Installation complete
    MsgBox('GhostCopy has been installed successfully!' + #13#10 + #13#10 +
           'Press Ctrl+Shift+V to open the Spotlight window.', mbInformation, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // Uninstall complete
    MsgBox('GhostCopy has been completely removed from your system.' + #13#10 +
           'No files or settings remain.', mbInformation, MB_OK);
  end;
end;
