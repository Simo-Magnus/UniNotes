# Google Drive: registrazione dell'app in Google Cloud

Gli **studenti non devono fare nulla**: l'app pubblicata contiene già gli ID
client Google, inclusi al momento della build. Questa pagina serve a chi compila
e pubblica l'app (una sola volta). Finché gli ID non sono nella build, la scheda
Google Drive in Collegamenti mostra «Google Drive non è ancora disponibile in
questa versione dell'app» e il pulsante di accesso è disattivato.

## Cosa fa l'app con Google Drive

Le stesse cose di OneDrive: nella cartella scelta (predefinita `UniNotes`)
tiene `Corsi/` (registrazioni, trascrizioni, riassunti, appunti), `Libri/`,
`Materiali/`, `Allegati/` e `Backup/`, con sincronizzazione bidirezionale
all'avvio, ogni N minuti, al ritorno nell'app e quando torna la connessione. I
file eliminati su Drive vanno nel cestino di Drive (recuperabili per 30 giorni);
quelli eliminati altrove finiscono sul dispositivo nella cartella nascosta
`.cestino-googledrive`.

### Scope `drive.file`: niente verifica a pagamento

L'app chiede solo lo scope **`https://www.googleapis.com/auth/drive.file`**. Con
questo scope l'app vede:

- la cartella `UniNotes` e tutto ciò che crea lei, da **ogni dispositivo** che
  usa lo stesso progetto Google Cloud (PC, Mac, telefoni);
- i file che lo studente sceglie con **«Importa da Drive»** (Google Picker).

Non vede i file messi nella cartella da altre vie (sito di Drive, app Drive,
Drive per desktop, condivisioni): restano lì finché non si importano. Per farli
entrare in UniNotes ci sono tre strade:

1. **Importa da Drive** (Collegamenti → Google Drive): apre il Google Picker. I
   file già dentro `UniNotes` da quel momento si sincronizzano; quelli altrove
   si copiano (copia lato server, l'originale resta) in
   `UniNotes/Materiali/<insegnamento>` o `UniNotes/Materiali/Da ordinare`.
2. **Condividi → UniNotes** (Android, anche dall'app Drive con «Invia una
   copia») e **Apri in UniNotes** / foglio Condividi (iPhone, iPad).
3. **Trascinamento** dei file sulla finestra dell'app (Windows, macOS).

Nei casi 2 e 3 l'app chiede in quale insegnamento salvare (o «Da ordinare»),
copia il file in Materiali e lo carica nella cartella UniNotes.

`drive.file` è uno scope **non sensibile**: non serve la verifica degli scope con
restrizioni né la valutazione di sicurezza annuale (CASA) a pagamento, e non c'è
il limite di 100 utenti. Resta la normale verifica del brand (nome, logo,
dominio) se si mostra il logo nella schermata di consenso.

Il selettore delle cartelle (*Cambia…*) mostra solo le cartelle che l'app vede
(quelle che ha creato).

### Migrazione da una versione con lo scope `drive`

Il progetto Google Cloud è nuovo, quindi:

- l'accesso salvato da una versione precedente non vale più: al primo controllo
  l'app lo toglie in silenzio (nessun errore, nessun «collegamento
  interrotto»), mostra una volta «Google Drive va ricollegato» e nella scheda un
  avviso finché lo studente non si ricollega;
- una cartella `UniNotes` creata dal vecchio client non è visibile: all'accesso
  l'app ne crea una nuova e spiega una volta (con «Ho capito») che i file vecchi
  si recuperano con «Importa da Drive». I file presenti sul dispositivo si
  ricaricano da soli nella cartella nuova (lo stato di sincronizzazione riparte
  da zero, nulla viene eliminato).

## 1. Progetto e API

1. Apri la [console di Google Cloud](https://console.cloud.google.com/) →
   **Nuovo progetto** → nome `UniNotes`.
2. *API e servizi → Libreria* → abilita **Google Drive API** e **Google Picker
   API**.
3. Annota il **numero del progetto** (*Dashboard* o *Impostazioni progetto* →
   «Numero progetto», solo cifre): è l'App ID del Picker.

## 2. Schermata di consenso OAuth (Google Auth Platform)

1. *Google Auth Platform → Branding*: nome `UniNotes`, email di
   assistenza, logo (facoltativo), link a home page, privacy e termini (il sito
   del progetto); tra i domini autorizzati `simo-magnus.github.io`.
2. *Pubblico*: tipo **Esterno**.
3. *Accesso ai dati → Aggiungi o rimuovi ambiti*:
   `https://www.googleapis.com/auth/drive.file` (non sensibile). Nessun altro
   scope Drive.
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

Sul telefono il ritorno dall'accesso e dal Picker usa lo schema
`com.googleusercontent.apps.<id>` (l'ID client al contrario) con
`flutter_web_auth_2`:

- **iOS**: non serve altro (ASWebAuthenticationSession riceve lo schema senza
  registrarlo nell'Info.plist).
- **Android**: nel client Android, *Impostazioni avanzate* → attiva **Schema URI
  personalizzato** (senza, Google rifiuta il ritorno all'app). Nient'altro: lo
  schema di ritorno nell'`AndroidManifest.xml` (`${googleAuthScheme}`) lo calcola
  `app/android/app/build.gradle.kts` dall'ID passato con
  `--dart-define=GOOGLE_ANDROID_CLIENT_ID`. L'impronta SHA-1 da indicare è quella
  della chiave di firma (`keytool -list -v -keystore <chiave>.jks -alias
  upload`); per Google Play serve un secondo client con la SHA-1 della chiave di
  firma dell'app di Play Console.

## 4. Chiave API per il Picker

*API e servizi → Credenziali → Crea credenziali → Chiave API*, poi
**Modifica la chiave**:

- *Restrizioni delle applicazioni*: **Siti web**, referrer
  `https://simo-magnus.github.io/UniNotes/*` (la pagina del Picker);
- *Restrizioni delle API*: solo **Google Picker API**.

La chiave finisce nella build e nella pagina: con queste restrizioni non serve
ad altro. Il Picker usa il token dell'app (scope `drive.file`) e il numero del
progetto (`setAppId`): i file scelti diventano accessibili a tutti i client del
progetto.

### Come funziona «Importa da Drive»

Il Picker esiste solo come API web (JavaScript). L'app apre nel browser la
pagina statica `sito/drive-picker.html` (GitHub Pages,
`https://simo-magnus.github.io/UniNotes/drive-picker.html`; un altro indirizzo
con `--dart-define=GOOGLE_PICKER_URL=…`) e le passa nel **frammento**
dell'indirizzo (`#token=…&key=…&app=…&ret=…&state=…`, mai inviato ai server) il
token di accesso, la chiave, il numero del progetto e l'indirizzo di ritorno. La
pagina toglie subito il frammento dalla barra, apre il Picker e torna all'app con
i soli id dei file:

- **PC e Mac**: `http://127.0.0.1:<porta>/picker?state=…&ids=…` (server locale
  dell'app, come per l'accesso);
- **telefono**: `com.googleusercontent.apps.<id>:/picker?state=…&ids=…` (lo schema
  già registrato per l'accesso). Se il browser blocca il ritorno automatico la
  pagina mostra il pulsante «Torna a UniNotes».

La pagina accetta come ritorno solo questi due tipi di indirizzo. Codice:
`lib/features/cloud/drive_picker.dart` (pagina, ritorno e lettura degli id) e
`GoogleDriveService.planImport` / `copyIntoApp`.

Senza chiave o numero del progetto nella build, «Importa da Drive» apre il
selettore di file del sistema: sul PC si scelgono i file da Drive per desktop
(unità G:), sul telefono dal fornitore «Drive» del selettore; i file passano
dall'app e si caricano nella cartella UniNotes come quelli condivisi.

## 5. Build

```bash
flutter build windows --release \
  --dart-define=GOOGLE_CLIENT_ID=<id>.apps.googleusercontent.com \
  --dart-define=GOOGLE_CLIENT_SECRET=<segreto> \
  --dart-define=GOOGLE_PICKER_API_KEY=<chiave API> \
  --dart-define=GOOGLE_CLOUD_PROJECT_NUMBER=<numero del progetto>
```

Per macOS lo stesso con `flutter build macos`; per iOS
`--dart-define=GOOGLE_IOS_CLIENT_ID=…`, per Android
`--dart-define=GOOGLE_ANDROID_CLIENT_ID=…`, più la chiave e il numero del
progetto.

Nel workflow `.github/workflows/app.yml` i valori arrivano da questi secrets del
repository (*Settings → Secrets and variables → Actions*):

| Secret | Diventa | Piattaforme |
|---|---|---|
| `GOOGLE_DRIVE_CLIENT_ID_DESKTOP` | `GOOGLE_CLIENT_ID` | Windows, macOS |
| `GOOGLE_DRIVE_CLIENT_SECRET_DESKTOP` | `GOOGLE_CLIENT_SECRET` | Windows, macOS |
| `GOOGLE_DRIVE_CLIENT_ID_ANDROID` | `GOOGLE_ANDROID_CLIENT_ID` | Android |
| `GOOGLE_DRIVE_CLIENT_ID_IOS` | `GOOGLE_IOS_CLIENT_ID` | iPhone, iPad |
| `GOOGLE_PICKER_API_KEY` | `GOOGLE_PICKER_API_KEY` | tutte |
| `GOOGLE_CLOUD_PROJECT_NUMBER` | `GOOGLE_CLOUD_PROJECT_NUMBER` | tutte |

Un secret mancante lascia vuoto il valore per quelle piattaforme: la build
riesce lo stesso. Senza ID client il collegamento a Google Drive resta
disattivato; senza chiave o numero del progetto «Importa da Drive» usa il
selettore di file del sistema.

## Errori frequenti

L'app traduce in italiano gli errori di Google (`GoogleOAuth.explain`):

| Errore | Causa |
|---|---|
| `redirect_uri_mismatch` | l'ID client desktop è di tipo «Applicazione web» |
| `invalid_client` | ID o segreto sbagliati nella build |
| `org_internal` | pubblico «Interno» invece di «Esterno» |
| `invalid_grant` | accesso scaduto o revocato (o app in stato «Test» da più di 7 giorni) |
| `admin_policy_enforced` | l'ateneo blocca le app esterne sull'account istituzionale: usare un account Google personale |
| Picker: «The API developer key is invalid» | chiave API sbagliata, Picker API non abilitata o referrer diverso da `simo-magnus.github.io/UniNotes/*` |
| Picker: file scelto ma «non trovato» | numero del progetto (App ID) sbagliato: il permesso va a un altro progetto |
