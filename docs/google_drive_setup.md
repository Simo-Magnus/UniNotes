# Google Drive: registrazione dell'app in Google Cloud

Gli **studenti non devono fare nulla**: l'app pubblicata contiene già gli ID
client Google, inclusi al momento della build. Questa pagina serve a chi compila
e pubblica l'app (una sola volta). Finché gli ID non sono nella build, la scheda
Google Drive in Collegamenti mostra «Questa versione dell'app non include l'ID
client Google» e il pulsante di accesso è disattivato.

## Cosa fa l'app con Google Drive

Le stesse cose di OneDrive: nella cartella scelta (predefinita
`UniNotes`) tiene `Corsi/` (registrazioni, trascrizioni, riassunti,
appunti), `Libri/`, `Materiali/`, `Allegati/` e `Backup/`, con sincronizzazione
bidirezionale all'avvio, ogni N minuti, al ritorno nell'app e quando torna la
connessione. I file eliminati su Drive vanno nel cestino di Drive (recuperabili
per 30 giorni); quelli eliminati altrove finiscono sul dispositivo nella
cartella nascosta `.cestino-googledrive`.

Appena ci si collega, l'app crea nel Drive dell'account scelto la cartella
`UniNotes` (o quella scelta con *Cambia…*, che sfoglia le cartelle del Drive come
per OneDrive). Da quel momento tutto ciò che si aggiunge nella cartella o nelle sue
sottocartelle (dal sito di Drive, dal PC, dal telefono) arriva nell'app, e tutto
ciò che si crea nell'app arriva nella cartella.

Per questo l'app chiede lo scope **`drive`** (accesso al Drive): con `drive.file`
vedrebbe solo i file creati da lei, non quelli caricati dal sito di Drive. L'app
legge e scrive soltanto nella cartella scelta, e i dati passano direttamente tra il
dispositivo e Google, senza server intermedi.

`drive` è uno scope **con restrizioni** (*restricted*):

- finché l'app non è verificata da Google, all'accesso compare l'avviso «App non
  verificata» e possono usarla al massimo 100 utenti;
- per pubblicarla senza limiti serve la **verifica dello scope con restrizioni**
  (motivazione, video dimostrativo dell'uso dello scope, informativa privacy sul
  sito). La valutazione di sicurezza CASA è richiesta quando i dati con restrizioni
  passano da un server dell'app: UniNotes non ne ha, ma va confermato con Google
  durante la verifica; se richiesta, si ripete ogni 12 mesi.

Fonti: [Restricted scope verification (Google)](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification).

## 1. Progetto e API

1. Apri la [console di Google Cloud](https://console.cloud.google.com/) →
   **Nuovo progetto** → nome `UniNotes`.
2. *API e servizi → Libreria* → **Google Drive API** → **Abilita**.

## 2. Schermata di consenso OAuth (Google Auth Platform)

1. *Google Auth Platform → Branding*: nome `UniNotes`, email di
   assistenza, logo (facoltativo), link a home page, privacy e termini (il sito
   del progetto).
2. *Pubblico*: tipo **Esterno**.
3. *Accesso ai dati → Aggiungi o rimuovi ambiti*:
   `https://www.googleapis.com/auth/drive` (con restrizioni, vedi sopra), con la
   motivazione: «sincronizzazione bidirezionale della cartella UniNotes scelta
   dall'utente, compresi i file aggiunti dal sito di Drive».
4. *Pubblico → Pubblica app* → stato **In produzione**. In stato «Test» i token
   scadono dopo 7 giorni e possono accedere solo gli utenti di test.

## 3. ID client

*Google Auth Platform → Client → Crea client*:

| Tipo | Per | Valore da includere nella build |
|---|---|---|
| **App desktop** | Windows, macOS (ritorno su `http://127.0.0.1:<porta>`, PKCE) | `GOOGLE_CLIENT_ID` e `GOOGLE_CLIENT_SECRET` |
| **iOS** (bundle id `io.github.simomagnus.universitynotes`) | iPhone, iPad | `GOOGLE_IOS_CLIENT_ID` |
| **Android** (pacchetto `io.github.simomagnus.universitynotes` + impronta SHA-1 del certificato di firma) | Android | `GOOGLE_ANDROID_CLIENT_ID` |

Il «segreto» del client desktop non è un segreto vero (Google lo dice per le app
installate): la protezione viene da PKCE. Si include nella build come gli ID.

### Telefono

Sul telefono il ritorno dall'accesso usa lo schema `com.googleusercontent.apps.<id>`
(l'ID client al contrario) con `flutter_web_auth_2`:

- **iOS**: non serve altro (ASWebAuthenticationSession riceve lo schema senza
  registrarlo nell'Info.plist).
- **Android**: nel client Android, *Impostazioni avanzate* → attiva **Schema URI
  personalizzato**. Nient'altro: lo schema di ritorno nell'`AndroidManifest.xml`
  (`${googleAuthScheme}`) lo calcola `app/android/app/build.gradle.kts` dall'ID
  passato con `--dart-define=GOOGLE_ANDROID_CLIENT_ID`. L'impronta SHA-1 da
  indicare è quella della chiave di firma (`keytool -list -v -keystore
  <chiave>.jks -alias upload`); per Google Play serve un secondo client con la
  SHA-1 della chiave di firma dell'app di Play Console.

## 4. Build

```bash
flutter build windows --release \
  --dart-define=GOOGLE_CLIENT_ID=<id>.apps.googleusercontent.com \
  --dart-define=GOOGLE_CLIENT_SECRET=<segreto>
```

Per macOS lo stesso con `flutter build macos`; per iOS
`--dart-define=GOOGLE_IOS_CLIENT_ID=…`, per Android
`--dart-define=GOOGLE_ANDROID_CLIENT_ID=…`.

Nel workflow `.github/workflows/app.yml` i valori arrivano da questi secrets del
repository (*Settings → Secrets and variables → Actions*):

| Secret | Diventa | Piattaforme |
|---|---|---|
| `GOOGLE_DRIVE_CLIENT_ID_DESKTOP` | `GOOGLE_CLIENT_ID` | Windows, macOS |
| `GOOGLE_DRIVE_CLIENT_SECRET_DESKTOP` | `GOOGLE_CLIENT_SECRET` | Windows, macOS |
| `GOOGLE_DRIVE_CLIENT_ID_ANDROID` | `GOOGLE_ANDROID_CLIENT_ID` | Android |
| `GOOGLE_DRIVE_CLIENT_ID_IOS` | `GOOGLE_IOS_CLIENT_ID` | iPhone, iPad |

Un secret mancante lascia vuoto l'ID per quelle piattaforme: la build riesce lo
stesso, e nell'app il collegamento a Google Drive resta disattivato.

## Errori frequenti

L'app traduce in italiano gli errori di Google (`GoogleOAuth.explain`):

| Errore | Causa |
|---|---|
| `redirect_uri_mismatch` | l'ID client desktop è di tipo «Applicazione web» |
| `invalid_client` | ID o segreto sbagliati nella build |
| `org_internal` | pubblico «Interno» invece di «Esterno» |
| `invalid_grant` | accesso scaduto o revocato (o app in stato «Test» da più di 7 giorni) |
| `admin_policy_enforced` | l'ateneo blocca le app esterne sull'account istituzionale: usare un account Google personale |
