; The Hive server installer for Windows (Inno Setup 6). Built by build.ps1.
;
; Installs to Program Files\Hive: hive.exe (Python inside), tools\ (FFmpeg,
; fpcalc), admin\ (Hive Admin) and the service. Data lives in
; C:\ProgramData\Hive and is never touched by installing, updating or
; removing Hive. Running a newer installer is the update: it stops Hive, backs
; up, replaces the program and starts Hive again.
;
; Unattended: HiveServerSetup.exe /VERYSILENT /MUSIC="D:\Music" [/HOST=tailscale]

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
AppId={{8C3E7B52-6F1A-4F3C-9B8E-5D2A1C0F4E71}
AppName=Hive server
AppVersion={#MyAppVersion}
AppVerName=Hive server {#MyAppVersion}
AppPublisher=Hive
DefaultDirName={autopf}\Hive
DisableProgramGroupPage=yes
DisableDirPage=auto
OutputDir=..\..\dist-installer
OutputBaseFilename=HiveServerSetup-{#MyAppVersion}
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\hive.exe
UninstallDisplayName=Hive server
LicenseFile=..\..\LICENSE
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
WizardStyle=modern
SetupLogging=yes
CloseApplications=no

[Files]
Source: "..\..\dist\hive\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "hive-service.xml"; DestDir: "{app}"; Flags: ignoreversion

[Dirs]
Name: "{commonappdata}\Hive"

[Run]
; Devices reach Hive over Tailscale only (its addresses are 100.64.0.0/10).
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Hive"""; Flags: runhidden; StatusMsg: "Letting devices on your private network reach Hive…"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Hive"" dir=in action=allow protocol=TCP localport=8443 remoteip=100.64.0.0/10"; Flags: runhidden
; "install" fails harmlessly on an update (already installed); "refresh" picks up a changed service file.
Filename: "{app}\hive-service.exe"; Parameters: "install"; Flags: runhidden; StatusMsg: "Starting Hive…"
Filename: "{app}\hive-service.exe"; Parameters: "refresh"; Flags: runhidden
Filename: "{app}\hive-service.exe"; Parameters: "start"; Flags: runhidden
Filename: "http://localhost:8443/admin/"; Description: "Open Hive Admin"; Flags: postinstall shellexec nowait skipifsilent

[UninstallRun]
Filename: "{app}\hive-service.exe"; Parameters: "stop"; Flags: runhidden; RunOnceId: "StopHive"
Filename: "{app}\hive-service.exe"; Parameters: "uninstall"; Flags: runhidden; RunOnceId: "RemoveHive"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Hive"""; Flags: runhidden; RunOnceId: "Firewall"

[Messages]
FinishedLabel=Hive is running. It starts by itself whenever this computer starts.%n%nOpen Hive Admin on this computer to set it up. Your music and everything Hive knows stay on this computer.

[Code]
var
  MusicPage: TInputDirWizardPage;

function ConfigPath: String;
begin
  Result := ExpandConstant('{commonappdata}\Hive\hive.toml');
end;

function FirstInstall: Boolean;
begin
  Result := not FileExists(ConfigPath);
end;

procedure InitializeWizard;
begin
  if FirstInstall then
  begin
    MusicPage := CreateInputDirPage(wpSelectDir,
      'Your music', 'Where is the family''s music?',
      'Hive plays the music in this folder and the folders inside it. Your files are never changed or moved. You can add more folders later in Hive Admin.',
      False, '');
    MusicPage.Add('Music folder:');
    MusicPage.Values[0] := ExpandConstant('{param:MUSIC|' + GetEnv('USERPROFILE') + '\Music}');
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := '';
  if FileExists(ExpandConstant('{app}\hive-service.exe')) then
  begin
    { An update: stop Hive, then back up before anything is replaced. }
    Exec(ExpandConstant('{app}\hive-service.exe'), 'stop', '', SW_HIDE, ewWaitUntilTerminated, Code);
    Sleep(2000);
    if FileExists(ExpandConstant('{app}\hive.exe')) then
      if not Exec(ExpandConstant('{app}\hive.exe'), 'backup --kind before-update', '', SW_HIDE,
                  ewWaitUntilTerminated, Code) or (Code <> 0) then
      begin
        Exec(ExpandConstant('{app}\hive-service.exe'), 'start', '', SW_HIDE, ewWaitUntilTerminated, Code);
        Result := 'Hive couldn''t make a backup before updating, so nothing was changed and Hive is running as before. ' +
                  'Is the backup drive connected? Check Hive Admin → Backups, then run this installer again.';
      end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Music, Text: String;
begin
  if (CurStep = ssPostInstall) and FirstInstall then
  begin
    Music := ExpandConstant('{param:MUSIC|' + GetEnv('USERPROFILE') + '\Music}');
    if MusicPage <> nil then
      Music := MusicPage.Values[0];
    ForceDirectories(Music);
    { TOML literal strings ('...') keep Windows backslashes as they are. }
    Text := '# Hive server settings. Hive Admin changes most of these for you.' + #13#10 +
            '# Listen on this computer and its Tailscale address.' + #13#10 +
            'host = "' + ExpandConstant('{param:HOST|tailscale}') + '"' + #13#10 +
            'music_folders = [''' + Music + ''']' + #13#10;
    SaveStringToFile(ConfigPath, Text, False);
  end;
end;
