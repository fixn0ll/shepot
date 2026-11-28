#ifndef AppVersion
  #define AppVersion "0.1.3"
#endif

[Setup]
AppId={{6F7D8A1B-3C42-4B7E-9A55-19E0D3C67C10}
AppName=Shepot
AppVersion={#AppVersion}
AppPublisher=fixn0ll
AppPublisherURL=https://github.com/fixn0ll/shepot
AppSupportURL=https://github.com/fixn0ll/shepot/releases
AppUpdatesURL=https://github.com/fixn0ll/shepot/releases
DefaultDirName={localappdata}\Programs\Shepot
DefaultGroupName=Shepot
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
AppMutex=Local\ShepotSingleInstanceMutex
CloseApplications=yes
RestartApplications=yes
SetupIconFile=..\assets\app.ico
UninstallDisplayIcon={app}\shepot.exe
OutputDir=..\dist
OutputBaseFilename=ShepotSetup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern dynamic

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\bin\shepot.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Shepot"; Filename: "{app}\shepot.exe"
Name: "{autodesktop}\Shepot"; Filename: "{app}\shepot.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\shepot.exe"; Description: "{cm:LaunchProgram,Shepot}"; Flags: nowait postinstall
