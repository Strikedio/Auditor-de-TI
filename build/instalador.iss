; =====================================================================
;  Instalador do AuditorTI (Inno Setup 6)
;  Compilado por build\Compilar.ps1  ->  dist\AuditorTI-Setup-<versão>.exe
; =====================================================================
#ifndef MyAppVersion
  #define MyAppVersion "1.1.0"
#endif

[Setup]
AppId={{8E3B6C2A-5F41-4C1B-9A7E-3D2F1A9B7C11}
AppName=AuditorTI
AppVersion={#MyAppVersion}
AppVerName=AuditorTI {#MyAppVersion}
AppPublisher=Samuel David Diniz Reis
AppPublisherURL=https://github.com/Strikedio/Auditor-de-TI
AppSupportURL=https://github.com/Strikedio/Auditor-de-TI
DefaultDirName={autopf}\AuditorTI
DefaultGroupName=AuditorTI
DisableProgramGroupPage=yes
PrivilegesRequired=admin
OutputDir=..\dist
OutputBaseFilename=AuditorTI-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\AuditorTI.exe
UninstallDisplayName=AuditorTI
#ifexist "..\assets\icone.ico"
SetupIconFile=..\assets\icone.ico
#endif

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\dist\AuditorTI.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\AuditorTI.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LEIA-ME.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\AuditorTI"; Filename: "{app}\AuditorTI.exe"
Name: "{group}\Leia-me"; Filename: "{app}\LEIA-ME.txt"
Name: "{group}\Desinstalar AuditorTI"; Filename: "{uninstallexe}"
Name: "{autodesktop}\AuditorTI"; Filename: "{app}\AuditorTI.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\AuditorTI.exe"; Description: "{cm:LaunchProgram,AuditorTI}"; Flags: nowait postinstall skipifsilent shellexec
