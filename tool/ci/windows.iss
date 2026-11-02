; Native per-user installer; no administrator account or cross-repository release.
[Setup]
AppId=dev.yggvion.yggvion
AppName=Yggvion
AppVersion={#AppVersion}
VersionInfoVersion={#FileVersion}
DefaultDirName={localappdata}\Programs\Yggvion
DefaultGroupName=Yggvion
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=yggvion
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=yes
UninstallDisplayIcon={app}\yggvion.exe

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Yggvion"; Filename: "{app}\yggvion.exe"; AppUserModelID: "dev.yggvion.yggvion"

[Registry]
Root: HKCU; Subkey: "Software\Classes\yggvion"; ValueType: string; ValueData: "URL:Yggvion"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\yggvion"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\yggvion\shell\open\command"; ValueType: string; ValueData: """{app}\yggvion.exe"" ""%1"""
