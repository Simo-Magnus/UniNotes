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
;   schermata di disinstallazione dell'app (scelta dei dati da eliminare,
;   anche nel cloud e nel calendario) e aspetta che si chiuda; poi toglie i
;   file del programma. L'app non ha un tasto per disinstallarsi: la
;   disinstallazione parte sempre da qui (vedi
;   lib/core/services/app_uninstall.dart). Prima chiude UniNotes se è aperto
;   ([Code]) e alla fine toglie tutta la cartella del programma, anche i file
;   creati dopo l'installazione.

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
; I modelli inclusi (Parakeet in data\parakeet, 670 MB, e Whisper small
; q5_1 in data\whisper, 181 MiB) si comprimono poco (~430 + ~170 MB): più
; thread per non allungare troppo la build.
LZMAUseSeparateProcess=yes
LZMANumBlockThreads=4
WizardStyle=modern
; Immagini con il logo (tools/genera_icona.py), una per ogni scala dello
; schermo: riquadro a sinistra di benvenuto e fine, icona in alto a destra.
WizardImageFile=immagini\grande_100.bmp,immagini\grande_125.bmp,immagini\grande_150.bmp,immagini\grande_175.bmp,immagini\grande_200.bmp,immagini\grande_225.bmp,immagini\grande_250.bmp
WizardSmallImageFile=immagini\piccola_100.bmp,immagini\piccola_125.bmp,immagini\piccola_150.bmp,immagini\piccola_175.bmp,immagini\piccola_200.bmp,immagini\piccola_225.bmp,immagini\piccola_250.bmp
; Un'app UniNotes aperta si chiude prima di sostituirne i file.
CloseApplications=yes
RestartApplications=no
; La cartella del programma si toglie tutta con la disinstallazione: se ne
; resta una da una versione vecchia, la nuova installazione la riusa senza
; l'avviso «la cartella esiste già».
DirExistsWarning=no

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Modello Whisper base q5_1 delle versioni fino al 21/10/2026 (non si usa
; più): un aggiornamento lo toglie, al suo posto c'è small q5_1.
Type: files; Name: "{app}\data\whisper\ggml-base-q5_1.bin"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Collegamenti con l'AppUserModelID dell'app (lo stesso che il processo
; dichiara all'avvio, windows/runner/notification_identity.cpp, e dei toast,
; lib/core/reminders/windows_aumid.dart) e il CLSID che attiva l'app dal
; tocco su un toast (GUID di lib/core/reminders/notification_platform.dart,
; scritto anche nel CustomActivator dell'AUMID): metodo ufficiale per le
; notifiche delle app desktop non pacchettizzate; nome e icona dei toast e
; il pulsante sulla barra delle applicazioni sono quelli di UniNotes.
Name: "{autoprograms}\UniNotes"; Filename: "{app}\uninotes.exe"; AppUserModelID: "SimoMagnus.UniNotes"; AppUserModelToastActivatorCLSID: "5d3f2b7e-91c4-4a8e-b6f1-0c7a2e9d4b13"
Name: "{autodesktop}\UniNotes"; Filename: "{app}\uninotes.exe"; AppUserModelID: "SimoMagnus.UniNotes"; AppUserModelToastActivatorCLSID: "5d3f2b7e-91c4-4a8e-b6f1-0c7a2e9d4b13"; Tasks: desktopicon

[Run]
; Ultima pagina dell'installazione: casella «Avvia UniNotes» (selezionata;
; chi non vuole aprire l'app subito la toglie prima di «Fine»). Non c'è
; nelle installazioni silenziose (/SILENT, /VERYSILENT): lì l'app non parte
; da sola. Testo scritto qui, senza dipendere dalla traduzione di Inno Setup.
Filename: "{app}\uninotes.exe"; Description: "Avvia UniNotes"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Schermata di disinstallazione dell'app (scelta dei dati da eliminare).
Filename: "{app}\uninotes.exe"; Parameters: "--disinstalla"; Flags: waituntilterminated; RunOnceId: "DisinstallaUniNotes"

[UninstallDelete]
; Tutto quello che resta nella cartella del programma (file creati dopo
; l'installazione, modelli scaricati come ripiego): la cartella sparisce. I
; dati dello studente non sono qui (AppData\Roaming) e li gestisce la
; schermata di disinstallazione dell'app.
Type: filesandordirs; Name: "{app}"

[Registry]
; Registrazione delle notifiche di Windows scritta dall'app al primo avvio
; (flutter_local_notifications): si toglie con il programma. AUMID attuale
; SimoMagnus.UniNotes; io.github.simomagnus.universitynotes è quello delle
; versioni fino a ottobre 2026 (l'app lo toglie da sola al primo avvio della
; versione nuova; qui per chi disinstalla senza averla mai aperta).
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\SimoMagnus.UniNotes"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup\SimoMagnus.UniNotes"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\io.github.simomagnus.universitynotes"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup\io.github.simomagnus.universitynotes"; Flags: uninsdeletekey dontcreatekey
; Schema uninotes:// : dopo l'accesso a OneDrive o Google Drive nel browser
; la pagina riporta nell'app (lib/core/services/app_return.dart, che lo
; registra anche al primo avvio se manca).
Root: HKCU; Subkey: "Software\Classes\uninotes"; ValueType: string; ValueName: ""; ValueData: "URL:UniNotes"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\uninotes"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\uninotes\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\uninotes.exe"",0"
Root: HKCU; Subkey: "Software\Classes\uninotes\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\uninotes.exe"" ""%1"""

[Code]
// UniNotes aperto (anche solo nell'area di notifica) blocca uninotes.exe e
// le sue librerie: il disinstallatore non riuscirebbe a toglierli e l'app
// resterebbe. Si chiude prima di iniziare e di nuovo prima di cancellare i
// file (la schermata di disinstallazione dell'app a quel punto è già chiusa).
procedure ChiudiUniNotes();
var
  Codice: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM uninotes.exe', '',
    SW_HIDE, ewWaitUntilTerminated, Codice);
end;

function InitializeUninstall(): Boolean;
begin
  ChiudiUniNotes();
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    ChiudiUniNotes();
  if CurUninstallStep = usPostUninstall then
  begin
    ChiudiUniNotes();
    // ultimo controllo: se qualcosa è rimasto, la cartella si toglie qui
    DelTree(ExpandConstant('{app}'), True, True, True);
  end;
end;
