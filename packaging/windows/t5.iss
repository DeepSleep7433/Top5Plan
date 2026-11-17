; T5 Windows per-user installer.
; Built with Inno Setup 6.7.4. This is a test/engineering build, not a
; production code-signed release.

#define MyAppName "T5 决策与待办"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "T5Plan"
#define MyAppExeName "t5_plan.exe"
#define MyAppId "{{5A31A0A4-3F8A-4E35-9E57-48F1E5D5C0B2}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion=1.0.0.0
VersionInfoProductName={#MyAppName}
VersionInfoDescription=T5 personal decision and todo application
DefaultDirName={localappdata}\Programs\T5
DefaultGroupName=T5
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\release\1.0.0\windows
OutputBaseFilename=t5-setup-1.0.0-x64
SetupIconFile=..\..\client\assets\t5.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
DirExistsWarning=no
UsePreviousAppDir=yes
CreateUninstallRegKey=yes
Uninstallable=yes

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: unchecked

[Files]
Source: "..\..\build\windows-installer-payload\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\T5 决策与待办"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\T5 决策与待办"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 T5"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C taskkill /IM {#MyAppExeName} /F >NUL 2>&1"; Flags: runhidden; RunOnceId: "StopT5"
