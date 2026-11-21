#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef BuildDir
  #error BuildDir is required
#endif
#ifndef OutputPath
  #error OutputPath is required
#endif
#ifndef ArtifactName
  #error ArtifactName is required
#endif
#ifndef AppArch
  #define AppArch "x64"
#endif

[Setup]
AppId=Flutify
AppName=Flutify
AppVersion={#AppVersion}
AppPublisher=Flutify
AppPublisherURL=https://github.com/is-hp-is-mad/Flutify
AppSupportURL=https://github.com/is-hp-is-mad/Flutify/issues
DefaultDirName={localappdata}\Programs\Flutify
DefaultGroupName=Flutify
DisableProgramGroupPage=yes
DisableDirPage=no
PrivilegesRequired=lowest
#if AppArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
MinVersion=10.0.17763
OutputDir={#OutputPath}
OutputBaseFilename={#ArtifactName}-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Flutify.exe
LicenseFile={#BuildDir}\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Flutify"; Filename: "{app}\Flutify.exe"; WorkingDir: "{app}"; AppUserModelID: "Flutify"
Name: "{autodesktop}\Flutify"; Filename: "{app}\Flutify.exe"; WorkingDir: "{app}"; AppUserModelID: "Flutify"; Tasks: desktopicon

[Run]
Filename: "{app}\Flutify.exe"; Description: "{cm:LaunchProgram,Flutify}"; Flags: nowait postinstall

; Uninstall removes the installed program files plus everything Flutify.exe
; registers at runtime outside the install directory (Start menu link, app
; identity key, spotify: handler). User data (settings, playlist backups,
; WebView2 login profile, logs, temp profiles) is kept unless the user agrees in
; the uninstall dialog or passes /PURGE=1 to unins000.exe (silent default: keep).
; Cache folders the user moved to a custom location (FlutifyCache) are never
; deleted automatically.

[Code]
function PurgeRequested: Boolean;
begin
  if ExpandConstant('{param:PURGE|}') <> '' then
    Result := ExpandConstant('{param:PURGE|0}') = '1'
  else if UninstallSilent then
    Result := False
  else
    Result := MsgBox('Also delete Flutify settings, playlist backups, the login profile and logs?',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
end;

procedure DeleteTempFiles;
var
  Temp: String;
  Find: TFindRec;
begin
  Temp := GetEnv('TEMP');
  if Temp = '' then
    Exit;
  DeleteFile(Temp + '\flutify.log');
  DeleteFile(Temp + '\flutify.prev.log');
  DelTree(Temp + '\libCachedImageData', True, True, True);
  if FindFirst(Temp + '\flutify_backup_profile_*', Find) then
  begin
    try
      repeat
        if (Find.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          DelTree(Temp + '\' + Find.Name, True, True, True);
      until not FindNext(Find);
    finally
      FindClose(Find);
    end;
  end;
end;

procedure PurgeUserData;
begin
  DelTree(ExpandConstant('{app}\Flutify.exe.WebView2'), True, True, True);
  DelTree(ExpandConstant('{userappdata}\Flutify'), True, True, True);
  DelTree(ExpandConstant('{localappdata}\Flutify'), True, True, True);
  DeleteTempFiles;
end;

// Flutify.exe writes these at every launch (windows/runner/media_identity.cpp,
// protocol_handler.cpp). They are not installer-managed, so remove them here;
// otherwise a dangling Start menu link and registry keys survive the uninstall.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command, Previous: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // Remove {app} if it is now empty (covers reinstalls over a kept
    // directory where Inno Setup did not record {app} as newly created).
    RemoveDir(ExpandConstant('{app}'));
    Exit;
  end;
  if CurUninstallStep <> usUninstall then
    Exit;
  if RegQueryStringValue(HKCU, 'Software\Classes\spotify\shell\open\command', '', Command) and
     (Pos(Lowercase(ExpandConstant('{app}\Flutify.exe')), Lowercase(Command)) > 0) then
  begin
    if RegQueryStringValue(HKCU, 'Software\Flutify\Protocol', 'Previous', Previous) and
       (Previous <> '<none>') and (Previous <> '') then
      RegWriteStringValue(HKCU, 'Software\Classes\spotify\shell\open\command', '', Previous)
    else
      RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\spotify');
  end;
  RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\Flutify.SpotifyURI');
  RegDeleteValue(HKCU, 'Software\RegisteredApplications', 'Flutify');
  RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\AppUserModelId\Flutify');
  RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Flutify');
  DeleteFile(ExpandConstant('{userprograms}\Flutify.lnk'));
  if PurgeRequested then
    PurgeUserData;
end;
