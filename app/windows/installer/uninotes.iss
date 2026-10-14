; Installatore di UniNotes per Windows (Inno Setup 6, gratuito).
;
; Lo genera la build CI (.github/workflows/app.yml, job «windows»):
;   iscc /DAppVersion=2026.9.0 app\windows\installer\uninotes.iss
; dopo `flutter build windows --release`. Risultato:
; app\build\installer\UniNotes_setup.exe.
;
; - Installazione per utente, senza amministratore, in
;   %LOCALAPPDATA%\Programs\UniNotes; collegamento nel menu Start e, a
;   scelta, sul desktop; UniNotes compare in «App installate».
; - Aggiornamento: si installa la nuova versione sopra la precedente (stesso
;   AppId); i dati dell'utente non sono nella cartella del programma e
;   restano.
; - Disinstallazione: il disinstallatore standard di Inno Setup. Avviato da
;   «App installate» lancia prima `uninotes.exe --disinstalla`, che apre la
;   schermata «Disinstalla UniNotes» dell'app (scelta dei dati da eliminare,
;   anche nel cloud e nel calendario) e aspetta che si chiuda; poi toglie i
;   file del programma. Quando invece è l'app a lanciarlo, dopo la pulizia,
;   lo fa in modalità silenziosa e lascia un segno nella cartella del
;   programma: `--disinstalla` lo trova e si chiude subito, senza ripetere
;   le domande (vedi lib/core/services/app_uninstall.dart).

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef BuildDir
  #define BuildDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

[Setup]
; Identificativo fisso: non va mai cambiato, serve agli aggiornamenti.
AppId={{B4BE0090-B51B-43DE-A150-98B2E4A46A48}
AppName=UniNotes
AppVersion={#AppVersion}
AppVerName=UniNotes {#AppVersion}
AppPublisher=Simo-Magnus
AppPublisherURL=https://simo-magnus.github.io/UniNotes/
AppSupportURL=https://github.com/Simo-Magnus/UniNotes
AppUpdatesURL=https://simo-magnus.github.io/UniNotes/
VersionInfoVersion={#AppVersion}
VersionInfoProductName=UniNotes
DefaultDirName={localappdata}\Programs\UniNotes
DefaultGroupName=UniNotes
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=UniNotes_setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\uninotes.exe
UninstallDisplayName=UniNotes
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Un'app UniNotes aperta si chiude prima di sostituirne i file.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\UniNotes"; Filename: "{app}\uninotes.exe"
Name: "{autodesktop}\UniNotes"; Filename: "{app}\uninotes.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\uninotes.exe"; Description: "{cm:LaunchProgram,UniNotes}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Schermata «Disinstalla UniNotes» dell'app (si chiude da sola se la
; pulizia è già stata fatta dall'app).
Filename: "{app}\uninotes.exe"; Parameters: "--disinstalla"; Flags: waituntilterminated; RunOnceId: "DisinstallaUniNotes"

[UninstallDelete]
; Segno «pulizia già fatta» scritto dall'app prima di avviare la
; disinstallazione.
Type: files; Name: "{app}\.pulizia_fatta"

[Registry]
; Registrazione delle notifiche di Windows scritta dall'app al primo avvio
; (flutter_local_notifications): si toglie con il programma.
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\io.github.simomagnus.universitynotes"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup\io.github.simomagnus.universitynotes"; Flags: uninsdeletekey dontcreatekey
