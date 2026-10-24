; The Hive app installer for Windows (Inno Setup 6): the family's music
; player, not the server. Built by the release workflow from the Flutter
; build in app\build\windows\x64\runner\Release.
;
; Installs for the person running it (no administrator needed) to
; %LOCALAPPDATA%\Programs\Hive, with a Start menu shortcut. Running a newer
; installer updates it; sign-in and downloads are kept.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
AppId={{3F6B1D84-2C7E-4A59-8E31-7B0C9D4A2E65}
AppName=Hive
AppVersion={#MyAppVersion}
AppVerName=Hive {#MyAppVersion}
AppPublisher=Hive
DefaultDirName={userpf}\Hive
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\dist-installer
OutputBaseFilename=HiveSetup-{#MyAppVersion}
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\hive.exe
UninstallDisplayName=Hive
LicenseFile=..\..\LICENSE
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Files]
Source: "..\..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{userprograms}\Hive"; Filename: "{app}\hive.exe"

[Run]
Filename: "{app}\hive.exe"; Description: "Open Hive"; Flags: nowait postinstall skipifsilent
