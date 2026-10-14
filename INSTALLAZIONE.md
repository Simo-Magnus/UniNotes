# Installare UniNotes

Le versioni di prova si scaricano da **GitHub**, senza bisogno di un account.
La via più semplice è la pagina di download <https://simo-magnus.github.io/UniNotes/>,
che propone il file giusto per il dispositivo in uso.

- **Ultima build** (aggiornata a ogni modifica):
  <https://github.com/Simo-Magnus/UniNotes/releases/tag/ultima-build> → sezione
  *Assets*: `UniNotes-windows.zip`, `UniNotes-macos.zip`, `UniNotes-android.apk`,
  `UniNotes-ios-non-firmata.ipa`.
- **Versioni numerate**, quando ci sono: <https://github.com/Simo-Magnus/UniNotes/releases>
  → versione → *Assets*.

Quando l'app sarà negli store basterà
cercare «UniNotes» in Google Play, App Store e Microsoft Store.

| Piattaforma | File da scaricare | Requisiti |
|---|---|---|
| Android | `UniNotes-android.apk` (quasi tutti i telefoni, 64 bit); `UniNotes-android-32bit.apk` per i telefoni vecchi a 32 bit; `UniNotes-android-x86_64.apk` per Chromebook ed emulatori | Android 7.0 o successivo |
| Windows | `UniNotes-windows.zip` | Windows 10/11 a 64 bit |
| macOS | `UniNotes-macos.zip` | macOS 12 o successivo (Intel o Apple Silicon) |
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

1. Scarica `UniNotes-windows.zip` ed **estrai tutta la cartella** (tasto destro →
   *Estrai tutto*), per esempio in `Documenti\UniNotes`.
2. Avvia `uninotes.exe`. Se Windows mostra «Windows ha protetto il PC»
   (SmartScreen, l'app non è ancora firmata): *Ulteriori informazioni → Esegui comunque*.
3. Se manca una DLL (`MSVCP140.dll`, `VCRUNTIME140.dll`), installa il
   «Microsoft Visual C++ Redistributable x64» dal sito Microsoft.
4. Facoltativo: tasto destro su `uninotes.exe` → *Mostra altre opzioni → Aggiungi
   a Start* (o crea un collegamento sul desktop).

## macOS

1. Scarica `UniNotes-macos.zip`, aprilo (si estrae da solo) e trascina
   **UniNotes.app** nella cartella *Applicazioni*.
2. Primo avvio: l'app non è ancora firmata da Apple, quindi macOS la blocca. Apri
   *Impostazioni di Sistema → Privacy e sicurezza*, in fondo «UniNotes è stata
   bloccata» → *Apri comunque* (su macOS più vecchi: tasto destro sull'app → *Apri* →
   *Apri*). In alternativa, nel Terminale:
   `xattr -dr com.apple.quarantine "/Applications/UniNotes.app"`.
3. Al primo uso del registratore macOS chiede il permesso per il microfono: consentilo.
4. Whisper su Mac: `brew install whisper-cpp` (Homebrew), poi scegli il modello in
   *Collegamenti*.

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
