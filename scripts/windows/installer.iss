; Inno Setup script for the mcvpn .exe installer.
; Compiled by the "windows" job in .github/workflows/release.yml via ISCC.exe;
; invoke it from the repo root: ISCC.exe scripts\windows\installer.iss
; Relative paths below are resolved relative to *this file*, not the CWD.

#define MyAppName "mcvpn"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define MyAppExeName "mcvpn.exe"
#define ReleaseDir "..\..\app\build\windows\x64\runner\Release"

[Setup]
AppId={{B4B6C7A0-5F1B-4C7D-9B0D-4E9E7B0B5B10}
AppName={#MyAppName}
AppVersion={#AppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=mcvpn-windows-setup
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
