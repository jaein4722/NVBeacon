; NVBeacon installer, compiled with Inno Setup 6 by scripts\package.ps1 -Installer:
;   ISCC.exe /DAppVersion=1.0.0 /DSourceDir=<packaged folder> /DOutputDir=<dist> /DIconFile=<NVBeacon.ico> NVBeacon.iss
;
; Installs for the current user only, under %LOCALAPPDATA%\Programs\NVBeacon, so it
; needs no administrator rights or UAC prompt. Running the installer of a newer
; version over an existing install upgrades it in place. Uninstalling asks whether
; to also delete the user's data: settings (%APPDATA%\NVBeacon), GPU History
; (%LOCALAPPDATA%\NVBeacon) and saved SSH passwords (Credential Manager). The default
; answer keeps it.

#ifndef AppVersion
  #error Pass /DAppVersion=x.y.z
#endif
; The file version must be numbers only: 1.0.0 for AppVersion 1.0.0-beta.1.
#ifndef AppNumericVersion
  #define AppNumericVersion AppVersion
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<folder made by package.ps1>
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

; Must match the tray window class and single-instance mutex in Sources\NVBeacon\main.swift.
#define TrayWindowClass "NVBeaconTrayWindow"
#define InstanceMutex "Local\NVBeacon.Tray"

[Setup]
; Never change AppId: Windows matches upgrades and the uninstaller by it.
AppId={{2EAF98CD-F5CA-4455-8F34-8B5931D1289A}
AppName=NVBeacon
AppVersion={#AppVersion}
AppVerName=NVBeacon {#AppVersion}
AppPublisher=Lee Jaein
AppPublisherURL=https://github.com/jaein4722/NVBeacon
AppSupportURL=https://github.com/jaein4722/NVBeacon/issues
AppUpdatesURL=https://github.com/jaein4722/NVBeacon/releases
AppCopyright=Copyright (c) 2026 Lee Jaein. MIT License.
VersionInfoVersion={#AppNumericVersion}
PrivilegesRequired=lowest
DefaultDirName={autopf}\NVBeacon
DisableProgramGroupPage=yes
; Inno Setup 6 skips the welcome page unless asked; show it like most installers.
DisableWelcomePage=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
; Follows the Windows light/dark setting, like the app.
WizardStyle=modern dynamic
#ifdef IconFile
SetupIconFile={#IconFile}
#endif
#ifdef WizardImages
WizardImageFile={#WizardImages}
#endif
#ifdef WizardSmallImages
WizardSmallImageFile={#WizardSmallImages}
#endif
UninstallDisplayIcon={app}\NVBeacon.exe
UninstallDisplayName=NVBeacon
OutputDir={#OutputDir}
OutputBaseFilename=NVBeacon-{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
; NVBeacon is closed by PrepareToInstall below, which lets it save GPU History first.
CloseApplications=no
ShowLanguageDialog=auto
LanguageDetectionMethod=uilanguage

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[CustomMessages]
english.LaunchNVBeacon=Start NVBeacon
korean.LaunchNVBeacon=NVBeacon 실행
english.StartupGroup=Startup:
korean.StartupGroup=시작:
english.LaunchAtLogin=Launch NVBeacon at login
korean.LaunchAtLogin=로그인 시 NVBeacon 실행
english.StillRunning=NVBeacon is still running. Quit it from its notification area icon, then try again.
korean.StillRunning=NVBeacon이 아직 실행 중입니다. 알림 영역 아이콘 메뉴에서 종료한 뒤 다시 시도하세요.
english.DeleteData=Also delete NVBeacon's data?%n%nThis removes the server list, settings, watches, GPU History and saved SSH passwords. Choose No to keep them for a later reinstall.
korean.DeleteData=NVBeacon의 데이터도 삭제할까요?%n%n서버 목록, 설정, 감시 항목, GPU 기록, 저장된 SSH 비밀번호가 지워집니다. 나중에 다시 설치해 이어서 쓰려면 '아니요'를 누르세요.
english.PasswordsNotDeleted=Some saved passwords could not be deleted. Remove the entries starting with NVBeacon/ssh-password/ in Credential Manager.
korean.PasswordsNotDeleted=저장된 비밀번호 일부를 삭제하지 못했습니다. 자격 증명 관리자에서 NVBeacon/ssh-password/로 시작하는 항목을 지워 주세요.
english.WebView2Missing=NVBeacon needs the Microsoft Edge WebView2 Runtime, which is not installed on this PC.%n%nOpen its download page now? Setup will continue either way.
korean.WebView2Missing=NVBeacon을 실행하려면 Microsoft Edge WebView2 런타임이 필요한데, 이 PC에 설치되어 있지 않습니다.%n%n지금 다운로드 페이지를 열까요? 설치는 그대로 계속됩니다.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
; Offered on the first install only. Afterwards Settings > General > Launch at Login
; owns this, so an upgrade never turns it back on.
Name: "launchatlogin"; Description: "{cm:LaunchAtLogin}"; GroupDescription: "{cm:StartupGroup}"; Flags: unchecked; Check: not IsUpgrade

[Registry]
; The same value the app writes for Launch at Login.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "NVBeacon"; ValueData: """{app}\NVBeacon.exe"""; Tasks: launchatlogin

[InstallDelete]
; The UI files are replaced as a whole so pages removed in a newer version do not linger.
Type: filesandordirs; Name: "{app}\NVBeaconWindows_NVBeacon.resources"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\NVBeacon"; Filename: "{app}\NVBeacon.exe"
Name: "{autodesktop}\NVBeacon"; Filename: "{app}\NVBeacon.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\NVBeacon.exe"; Description: "{cm:LaunchNVBeacon}"; Flags: nowait postinstall skipifsilent

[Code]
const
  WM_CLOSE = $0010;
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  WebView2Client = '\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{2EAF98CD-F5CA-4455-8F34-8B5931D1289A}_is1';

{ True when NVBeacon is already installed for this user, i.e. this run is an upgrade. }
function IsUpgrade(): Boolean;
begin
  Result := RegKeyExists(HKCU, UninstallKey);
end;

{ Asks a running NVBeacon to quit (it saves GPU History and removes its tray icon),
  then waits up to 10 s for its single-instance mutex to go away. }
function CloseNVBeacon(): Boolean;
var
  Window: HWND;
  Attempt: Integer;
begin
  Result := True;
  Window := FindWindowByClassName('{#TrayWindowClass}');
  if Window = 0 then
    Exit;
  PostMessage(Window, WM_CLOSE, 0, 0);
  for Attempt := 1 to 100 do
  begin
    if not CheckForMutexes('{#InstanceMutex}') then
      Exit;
    Sleep(100);
  end;
  Result := False;
end;

function HasVersion(RootKey: Integer; const SubKey: String): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(RootKey, SubKey, 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0');
end;

function WebView2Installed(): Boolean;
begin
  Result := HasVersion(HKLM, 'SOFTWARE\WOW6432Node' + WebView2Client)
    or HasVersion(HKLM, 'SOFTWARE' + WebView2Client)
    or HasVersion(HKCU, 'Software' + WebView2Client);
end;

function InitializeSetup(): Boolean;
var
  ErrorCode: Integer;
begin
  Result := True;
  if not WebView2Installed() and not WizardSilent() then
    if MsgBox(CustomMessage('WebView2Missing'), mbConfirmation, MB_YESNO) = IDYES then
      ShellExec('open', 'https://developer.microsoft.com/microsoft-edge/webview2/', '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not CloseNVBeacon() then
    Result := CustomMessage('StillRunning');
end;

function InitializeUninstall(): Boolean;
begin
  Result := CloseNVBeacon();
  if not Result then
    MsgBox(CustomMessage('StillRunning'), mbError, MB_OK);
end;

var
  DeleteData: Boolean;

{ Before any file is removed: removes "Launch at Login" when it points at this copy
  (a registration for another copy is left alone) and asks whether to delete the
  user's data, saved passwords included (a silent uninstall keeps it). Passwords go
  first, while NVBeacon.exe still exists; the data folders after the files. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command: String;
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    if RegQueryStringValue(HKCU, RunKey, 'NVBeacon', Command) then
      if CompareText(Command, '"' + ExpandConstant('{app}\NVBeacon.exe') + '"') = 0 then
        RegDeleteValue(HKCU, RunKey, 'NVBeacon');
    if not UninstallSilent() then
      DeleteData := MsgBox(CustomMessage('DeleteData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
    if DeleteData then
      if not Exec(ExpandConstant('{app}\NVBeacon.exe'), '--forget-passwords', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
        MsgBox(CustomMessage('PasswordsNotDeleted'), mbError, MB_OK);
  end;
  if (CurUninstallStep = usPostUninstall) and DeleteData then
  begin
    DelTree(ExpandConstant('{userappdata}\NVBeacon'), True, True, True);
    DelTree(ExpandConstant('{localappdata}\NVBeacon'), True, True, True);
  end;
end;
