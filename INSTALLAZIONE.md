# Installare UniNotes

Le versioni di prova si scaricano da **GitHub**, senza bisogno di un account.
La via più semplice è la pagina di download <https://simo-magnus.github.io/UniNotes/>,
che propone il file giusto per il dispositivo in uso.

- **Ultima build** (aggiornata a ogni modifica):
  <https://github.com/Simo-Magnus/UniNotes/releases/tag/ultima-build> → sezione
  *Assets*: `UniNotes_setup.exe` (Windows), `UniNotes.dmg` (macOS),
  `UniNotes-android.apk` (con `UniNotes-android-32bit.apk` e `UniNotes-android-x86_64.apk`),
  `UniNotes-ios-non-firmata.ipa`; in più `UniNotes-windows.zip` e `UniNotes-macos.zip` per
  chi preferisce non installare.
- **Versioni numerate**, quando ci sono: <https://github.com/Simo-Magnus/UniNotes/releases>
  → versione → *Assets*.

Quando l'app sarà negli store basterà
cercare «UniNotes» in Google Play, nell'App Store e, per Windows, nel Microsoft Store
(quando disponibile). Le versioni per Windows e macOS restano anche sul sito; macOS non
va sul Mac App Store.

| Piattaforma | File da scaricare | Requisiti |
|---|---|---|
| Android | `UniNotes-android.apk` (quasi tutti i telefoni, 64 bit); `UniNotes-android-32bit.apk` per i telefoni vecchi a 32 bit; `UniNotes-android-x86_64.apk` per Chromebook ed emulatori | Android 7.0 o successivo |
| Windows | `UniNotes_setup.exe` (oppure `UniNotes-windows.zip`); Microsoft Store quando disponibile | Windows 10/11 a 64 bit |
| macOS | `UniNotes.dmg` (oppure `UniNotes-macos.zip`) | macOS 12 o successivo (Intel o Apple Silicon) |
| iPhone / iPad | `UniNotes-ios-non-firmata.ipa` | iOS 15.6 o successivo; va firmato (vedi sotto) |

## Android

1. Sul telefono apri la pagina dell'ultima build e scarica `UniNotes-android.apk`.
2. Tocca `UniNotes-android.apk`. Android chiede di consentire l'installazione da questa
   fonte: *Impostazioni → Consenti da questa fonte* (o *Installa app sconosciute*).
3. Tocca *Installa*. Play Protect può avvisare che l'app non viene dallo Store: scegli
   *Installa comunque*.
4. Aggiornamenti: installa il nuovo APK sopra il vecchio, i dati restano.

Gli APK sono divisi per processore, così ognuno contiene solo le librerie che servono: se
`UniNotes-android.apk` non si installa («app non compatibile»), il telefono è a 32 bit e
serve `UniNotes-android-32bit.apk`. Su Google Play non serve scegliere: lo store invia da
solo la versione giusta.

(Il file `app-release.aab` serve solo per Google Play, non si installa a mano.)

## Windows

1. Scarica `UniNotes_setup.exe` e aprilo. Se Windows mostra «Windows ha protetto il
   PC» (SmartScreen, l'app non è ancora firmata): *Ulteriori informazioni → Esegui
   comunque*.
2. Segui l'installazione: non servono permessi di amministratore. UniNotes si
   installa per il tuo utente in `%LOCALAPPDATA%\Programs\UniNotes`, con il
   collegamento nel menu Start e, se lo spunti, sul desktop.
3. **Aggiornamenti**: scarica il nuovo `UniNotes_setup.exe` e installalo sopra la
   versione precedente; i dati restano.
4. Se manca una DLL (`MSVCP140.dll`, `VCRUNTIME140.dll`), installa il
   «Microsoft Visual C++ Redistributable x64» dal sito Microsoft.

**Dal Microsoft Store** (quando disponibile): cerca «UniNotes» nell'app Microsoft Store
e scegli *Installa*. Gli aggiornamenti arrivano dallo Store. Per toglierla: menu Start →
tasto destro su UniNotes → *Disinstalla*; Windows elimina anche i dati dell'app sul PC,
mentre appunti e registrazioni in `Documenti\UniNotes` restano. Se vuoi eliminare anche
le cartelle nel cloud e gli eventi nel calendario, prima usa *Disinstalla UniNotes*
nell'app. La versione dello Store e `UniNotes_setup.exe` sono la stessa app: basta
installarne una.

**Senza installazione** (alternativa): scarica `UniNotes-windows.zip`, **estrai tutta
la cartella** (tasto destro → *Estrai tutto*) e avvia `uninotes.exe`. In questo caso
UniNotes non compare in *App installate*: per toglierla usa *Disinstalla UniNotes*
nell'app e poi elimina la cartella.

## macOS

1. Scarica `UniNotes.dmg` e aprilo: nella finestra che compare trascina **UniNotes**
   sulla cartella *Applicazioni*. Poi puoi espellere l'immagine disco.
2. Primo avvio: finché l'app non è firmata e notarizzata da Apple, macOS la blocca.
   Apri *Impostazioni di Sistema → Privacy e sicurezza*, in fondo «UniNotes è stata
   bloccata» → *Apri comunque* (su macOS più vecchi: tasto destro sull'app → *Apri* →
   *Apri*). In alternativa, nel Terminale:
   `xattr -dr com.apple.quarantine "/Applications/UniNotes.app"`.
3. **Aggiornamenti**: apri il nuovo `UniNotes.dmg` e trascina UniNotes in
   *Applicazioni* sostituendo la versione precedente; i dati restano.
4. Al primo uso del registratore macOS chiede il permesso per il microfono: consentilo.
5. Whisper su Mac: scegli e scarica il modello in *Collegamenti → Whisper*; funziona con
   whisper.cpp incluso nell'app. Per le lezioni di ore conviene installare anche
   `brew install whisper-cpp` (Homebrew): l'app lo trova da sola.

In alternativa al DMG c'è `UniNotes-macos.zip`: si estrae da solo, poi si sposta
**UniNotes.app** in *Applicazioni*.

## iPhone e iPad

Apple non permette di installare app non firmate. Finché l'app non è su TestFlight o
sull'App Store ci sono due strade:

- **Con un Mac** (la più affidabile): apri `app/ios` in Xcode, accedi con il tuo Apple ID
  (*Xcode → Settings → Accounts*), scegli il tuo team in *Signing & Capabilities*, collega
  l'iPhone e premi *Run*. Con un Apple ID gratuito l'app va reinstallata ogni 7 giorni;
  con l'Apple Developer Program (99 €/anno) dura un anno e si può usare TestFlight.
- **Senza Mac**: firma `UniNotes-ios-non-firmata.ipa` con il tuo Apple ID usando
  uno strumento di *sideloading* (per esempio Sideloadly o AltStore) e installalo
  sull'iPhone collegato al PC. Anche qui, con un Apple ID gratuito la firma dura 7 giorni.
- Sull'iPhone, la prima volta: *Impostazioni → Generali → VPN e gestione dispositivi* →
  il tuo Apple ID → *Autorizza*; da iOS 16 attiva anche *Impostazioni → Privacy e
  sicurezza → Modalità sviluppatore*.

Quando l'app sarà su **TestFlight** basterà installare l'app TestFlight e aprire il
link d'invito.

## Disinstallare UniNotes

Il modo completo, su tutti i dispositivi, è **dall'app**: *Impostazioni → Privacy e
informazioni → Disinstalla UniNotes*.

1. Scegli **Elimina tutto** oppure **Scegli cosa eliminare**: un elenco con le
   dimensioni dove si possono calcolare (profilo e corso scelto con le impostazioni;
   database con insegnamenti, esami e studio; registrazioni e trascrizioni;
   appunti; libri scaricati; modelli Whisper; dati dell'ateneo scaricati; cartelle
   UniNotes su OneDrive e su Google Drive; eventi aggiunti al calendario; account
   collegati).
2. Conferma il riepilogo. Nel cloud e nel calendario si elimina solo ciò che l'app ha
   creato: le sue cartelle (Corsi, Libri, Materiali, Allegati, Backup e la cartella
   «UniNotes» se resta vuota, nel cestino del servizio per circa 30 giorni) e gli
   eventi con il riferimento «UniNotes». OneNote l'app lo legge soltanto: lì non
   crea nulla, quindi non c'è niente da eliminare.
3. Se hai scelto solo alcune voci, l'app chiede se disinstallarla comunque o tenerla.
4. Poi la disinstallazione parte dove il sistema lo permette:
   - **Windows**: l'app avvia il disinstallatore e si chiude; il programma sparisce
     da *App installate*.
   - **Android**: si apre la richiesta di disinstallazione del sistema (tocca *OK*);
     se non si apre, la pagina *Informazioni app*: tocca *Disinstalla*.
   - **macOS**: l'app prova a spostarsi nel Cestino; se macOS non lo permette apre
     il Finder su UniNotes: trascinala nel Cestino.
   - **iPhone e iPad**: non si può fare dall'app. Tieni premuta l'icona di
     UniNotes → *Rimuovi app* → *Elimina app*.

Se disinstalli **senza passare dall'app**:

- **Windows** (*Impostazioni → App → App installate → UniNotes → Disinstalla*): il
  disinstallatore apre la stessa schermata *Disinstalla UniNotes*; chiudendola senza
  scegliere, i dati restano sul PC. Gli appunti in `Documenti\UniNotes` si eliminano
  solo se li scegli.
- **Android**: il sistema elimina tutti i dati dell'app (l'app non usa cartelle
  condivise e non va nel backup di Google, quindi reinstallandola non ritrovi
  nulla). Restano solo i dati nel cloud e gli eventi nel calendario: per toglierli
  usa prima *Disinstalla UniNotes*.
- **iPhone e iPad**: il sistema elimina i dati dell'app ma non le voci nel
  portachiavi; l'app le svuota da sola al primo avvio dopo una nuova installazione.
  Anche qui cloud e calendario restano.
- **macOS**: trascinare l'app nel Cestino **non** elimina i suoi dati, che restano in
  `~/Library/Containers/io.github.simomagnus.universitynotes` (con le preferenze e
  le cache) e nel portachiavi. Per eliminare tutto usa *Disinstalla UniNotes*
  dall'app. Se l'hai già trascinata nel Cestino: reinstallala e scegli *Elimina*
  quando chiede «Ho trovato dati di una installazione precedente», oppure elimina a
  mano quella cartella dal Finder (*Vai → Vai alla cartella…* →
  `~/Library/Containers`) e, in *Accesso Portachiavi*, le voci di UniNotes.

Reinstallando, l'app non rilegge da sola i dati di un'installazione precedente
rimasti sul dispositivo: chiede «Ho trovato dati di una installazione precedente: li
usi o li elimini?» (sul PC, per gli appunti rimasti in Documenti: «li usi o li
ignori?»; ignorandoli la cartella resta con il nome «Corsi (installazione
precedente)»). Un aggiornamento a una versione più nuova non chiede nulla.

*Impostazioni → Privacy e informazioni → Elimina tutti i dati* fa la stessa pulizia
ma lascia l'app installata.

## Dopo l'installazione

1. Al primo avvio scegli università, corso e anno. L'app è leggera: contiene solo
   l'elenco degli atenei e dei corsi; quando confermi la scelta **scarica da internet
   i dati del solo tuo ateneo** (insegnamenti, libri, date d'esame, moduli di studio:
   da pochi MB fino a circa 65 MB sul dispositivo per gli atenei più grandi, come
   Bologna; il trasferimento è compresso) e li salva sul dispositivo, dove restano disponibili anche senza internet. Se cambi
   ateneo scarica il nuovo e cancella i dati del precedente. Quando c'è una versione
   più recente del database l'app la propone e riscarica solo i file cambiati del tuo
   ateneo (*Impostazioni → Il mio percorso → Aggiorna database*). Senza connessione
   puoi comunque usare l'app con i corsi aggiunti a mano, gli appunti e il
   registratore, e scaricare i dati più tardi.
2. Per la trascrizione: *Collegamenti → Whisper* (scarica il modello consigliato, nessun
   account, tutto resta sul dispositivo) oppure *Collegamenti → Gemini*: l'app copia la
   richiesta e apre Gemini, dove alleghi tu la registrazione.
3. Per avere gli stessi appunti su PC e telefono: *Collegamenti → OneDrive* o
   *Collegamenti → Google Drive*.

Installando e usando l'app accetti i [Termini e condizioni d'uso](https://github.com/Simo-Magnus/UniNotes/blob/main/TERMINI.md).
Quali dati restano sul dispositivo e quali passano ai servizi che colleghi è spiegato
nell'[Informativa sulla privacy](https://github.com/Simo-Magnus/UniNotes/blob/main/PRIVACY.md).
Entrambi i documenti si aprono anche dall'app, in *Impostazioni → Privacy e informazioni*.
