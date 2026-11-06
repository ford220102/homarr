#define MyAppName "Homarr"
#define MyAppVersion "2.11.1"
#define MyAppPublisher "Homarr Labs"
#define MyAppURL "https://homarr.dev"
#define MyStageDir "stage"

[Setup]
AppId={{8F2A6C3B-4D5E-4F6A-9B7C-8D9E0F1A2B3C}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\artifacts
OutputBaseFilename=Homarr-Windows-Setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\Start-Homarr.ps1
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#MyStageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Uruchom Homarr"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\Start-Homarr.ps1"" -NoWait"; WorkingDir: "{app}"
Name: "{group}\Zatrzymaj Homarr"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\Start-Homarr.ps1"" -Stop"; WorkingDir: "{app}"
Name: "{group}\Otwórz dashboard"; Filename: "http://127.0.0.1:3000"
Name: "{autodesktop}\Uruchom Homarr"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\Start-Homarr.ps1"" -NoWait"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\Start-Homarr.ps1"" -NoWait"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent; Description: "Start Homarr after installation"

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\Start-Homarr.ps1"" -Stop"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated
