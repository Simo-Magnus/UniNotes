# OneDrive: registrazione dell'app in Microsoft Entra

Gli **studenti non devono fare nulla**: l'app pubblicata contiene già l'ID
applicazione Microsoft, incluso al momento della build. Questa pagina serve a chi
compila e pubblica l'app (una sola volta).

## 1. Registrazione

1. Apri [Microsoft Entra → Registrazioni app](https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
   con un account che abbia una directory Entra (le registrazioni fuori da una
   directory non sono più ammesse; quella di UniNotes è fatta con l'account del
   progetto, in una directory propria) → **Nuova registrazione**.
2. Nome: `UniNotes`.
3. Tipi di account supportati: **Account in qualsiasi directory organizzativa e
   account Microsoft personali** (tenant `common`: funziona sia con
   outlook/hotmail sia con gli account universitari).
4. Non inserire ancora un URI di reindirizzamento → **Registra**.
5. Copia **ID applicazione (client)** dalla pagina *Panoramica*.

## 2. Autenticazione (URI di reindirizzamento)

*Autenticazione → Aggiungi una piattaforma → App per dispositivi mobili e desktop*
e aggiungi questi URI personalizzati:

| Piattaforma | URI | Come lo usa l'app |
|---|---|---|
| Windows, macOS | `http://localhost` | server locale temporaneo (loopback, qualsiasi porta) |
| iOS | `msauth.io.github.simomagnus.universitynotes://auth` | `ASWebAuthenticationSession` tramite `flutter_web_auth_2` |
| Android | `msauth.io.github.simomagnus.universitynotes://auth` | Custom Tabs + `CallbackActivity` di `flutter_web_auth_2` (vedi `AndroidManifest.xml`) |

Su iOS lo stesso URI è quello che Entra genera per la piattaforma «iOS/macOS»
con bundle id `io.github.simomagnus.universitynotes`: puoi aggiungerlo anche da lì.
Su Android non serve la piattaforma «Android» di Entra (quella con l'hash della
firma è per MSAL): l'app usa lo schema personalizzato qui sopra.

Poi, nella stessa pagina, *Impostazioni avanzate* → **Consenti flussi client
pubblici: Sì**. Non creare segreti client: l'app è un client pubblico con PKCE.

Non registrare `http://localhost` né l'URI `msauth…` sotto le piattaforme
«Web» o «Applicazione a pagina singola»: danno gli errori AADSTS50011 /
AADSTS7000218 (l'app li spiega in italiano).

**Unica eccezione: la piattaforma «Web» con il solo URI della pagina per gli
amministratori** (*Aggiungi una piattaforma → Web*):

```
https://simo-magnus.github.io/UniNotes/amministratori.html
```

Serve come ritorno del link di consenso amministratore (sezione 6) e non
rompe il flusso client pubblico. Entra decide se trattare l'app come client
pubblico o riservato in base all'URI di reindirizzamento usato nello scambio
del codice: l'app usa sempre `http://localhost` o `msauth…://auth`, che restano
nella piattaforma «App per dispositivi mobili e desktop», quindi non le viene
mai chiesto un segreto. AADSTS7000218 compare solo se uno di quegli URI sta
(anche) sotto «Web», o se «Consenti flussi client pubblici» è su No. L'URI
della pagina non riceve mai un codice di autorizzazione: il consenso
amministratore restituisce solo `admin_consent=True&tenant=…` (o un errore),
che la pagina mostra. Neanche la piattaforma Web richiede un segreto client.

## 3. Autorizzazioni API

*Autorizzazioni API → Microsoft Graph → Autorizzazioni delegate*:

- `User.Read` (nome dell'account)
- `Files.ReadWrite` (cartella dell'app su OneDrive). Serve questo e non
  `Files.ReadWrite.AppFolder`: lo studente può scegliere la cartella (*Cambia…*)
  e l'app sincronizza in entrambi i sensi tutto ciò che c'è dentro, compresi i
  file aggiunti dal sito di OneDrive, da altre app o da OneDrive per desktop
  (elenco completo della cartella e `/delta` per le novità; su OneDrive for
  Business, senza `/delta` sulle sottocartelle, si rilegge tutta la cartella).
  Con AppFolder la cartella sarebbe fissa (`App/UniNotes`)
- `Notes.Read` (lettura dei blocchi appunti OneNote)
- `offline_access` (resta collegato senza rifare l'accesso)
- `Calendars.ReadWrite` (solo su Windows, calendario «UniNotes» in Outlook
  con le date delle prove): l'app lo chiede con il consenso dinamico solo
  quando lo studente attiva Impostazioni → Calendario, con un token separato
  da quello di OneDrive (vedi docs/notifiche.md). **Va aggiunto all'elenco**:
  il consenso dinamico funzionerebbe anche senza, ma «Concedi il consenso
  amministratore» in Entra admin center (sezione 6) approva solo i permessi
  elencati qui.

Non serve il consenso dell'amministratore per gli account personali; per gli
account universitari vedi la sezione 6.

## 4. ID dell'app UniNotes

La registrazione del progetto è già fatta (10/10/2026):

| Campo | Valore |
|---|---|
| ID applicazione (client) | `24f57293-12b8-4d3d-b33f-f55effdaa44f` |
| ID directory (tenant) di chi l'ha registrata | `2a05ac92-2049-4a26-9b34-897763efc8e2` |

L'ID applicazione è incluso nel codice (`MicrosoftOAuth.defaultClientId`):
tutte le build lo usano senza parametri. Non è un segreto (compare
nell'indirizzo di accesso); l'app non usa segreti client. L'accesso passa dal
tenant `common`, così entrano sia gli account personali sia quelli universitari:
per questo nella registrazione i **tipi di account supportati** devono essere
«Account in qualsiasi directory organizzativa e account Microsoft personali».
Con «Solo account in questa directory» potrebbero entrare solo gli account del
tenant indicato sopra.

Chi pubblica un fork con un'altra registrazione può sostituire l'ID:

```sh
flutter build windows --dart-define=MS_CLIENT_ID=<id-applicazione>
```

L'app non ha un'interfaccia per cambiare ID applicazione o tenant. Legge però
le impostazioni `onedrive_client_id` (ID al posto di quello della build) e
`onedrive_tenant` (`common` se mancano), se presenti nel database: per esempio
scritte da una versione precedente. «Usa un account Microsoft personale» riporta
`onedrive_tenant` a `common` se ammette solo account universitari.

## 5. Cosa fa l'app su OneDrive

Nella cartella scelta (predefinita `UniNotes`, selezionabile con il
navigatore delle cartelle) crea:

```
UniNotes/
  Dati/         <dispositivo> <codice>.json.gz (dati dell'app uniti fra i
                dispositivi: vedi docs/sincronizzazione_dati.md)
  Corsi/<Ateneo - Corso>/Registrazioni | Trascrizioni | Riassunti | Appunti | AI
  Libri/        libri copiati nell'app
  Materiali/    materiale didattico copiato nell'app
  Allegati/     allegati di Studio
  Backup/       Backup <dispositivo>.json (esportazione dei dati, solo se cambiati)
```

La sincronizzazione è bidirezionale (`lib/features/cloud/onedrive_sync.dart`):
file cambiati da una parte vengono copiati dall'altra, cambiati da entrambe
diventano due copie («conflitto»), eliminati finiscono nel cestino. I controlli
automatici (avvio, ogni N minuti, ritorno nell'app, ritorno della connessione)
usano `/delta` di Microsoft Graph sulla cartella per scaricare solo le novità;
una volta su sei, e con «Sincronizza ora», si rilegge tutto (su OneDrive for
Business `/delta` sulle sottocartelle non è disponibile: si rilegge sempre tutto).
Senza connessione (anche se cade a metà) la sincronizzazione si ferma salvando
quanto fatto e mostra «Serve una connessione a internet per sincronizzare con
OneDrive» (lo stesso per Google Drive) al posto dell'errore tecnico; l'ultima
sincronizzazione riuscita resta indicata e si riprova da sola quando torna la
rete, o con «Sincronizza ora».

I file scaricati si scrivono a pezzi in `nome.part` accanto alla destinazione
(senza tenerli interi in memoria) e solo alla fine prendono il posto di quello
vecchio: un download interrotto non rovina il file buono. Alla prima
sincronizzazione un file presente sia sul dispositivo sia su OneDrive con la
stessa dimensione si considera uguale (l'impronta di OneDrive, `quickXorHash`,
non è calcolata dall'app).

L'accesso è atomico: se dopo l'accesso con Microsoft non riescono la lettura
dell'account o la creazione della cartella, l'app toglie il token appena salvato
e mostra l'errore, invece di restare «collegata» a metà. «Scollega» toglie il
token dal dispositivo; Microsoft non permette a un'app pubblica di revocare il
proprio accesso (`revokeSignInSessions` chiuderebbe tutte le sessioni
dell'utente), quindi il dialogo indica dove toglierlo dall'account:
<https://account.live.com/consent/Manage> per gli account personali,
<https://myapps.microsoft.com> per quelli universitari.

## 6. Account universitari e consenso dell'amministratore

L'editore dell'app **non è verificato** (la verifica richiede un ente legale e
un dominio verificato). Per questo molti atenei impediscono agli studenti di
dare il consenso ad app non verificate, oppure tolgono del tutto il consenso
degli utenti. L'accesso con l'account universitario allora fallisce con
AADSTS65001, AADSTS90094, AADSTS90095, AADSTS50105 (utente non assegnato
all'app) o con la pagina «Need admin approval» / «Richiede l'approvazione
dell'amministratore». AADSTS65004 (consenso rifiutato) è trattato allo stesso
modo, perché è anche il codice che arriva quando lo studente esce da quella
pagina con «Torna all'applicazione»; la scheda aggiunge una riga per chi
avesse annullato per sbaglio.

**Nell'app** (`lib/features/cloud/microsoft_admin_consent.dart`,
`lib/features/links/microsoft_consent_sheet.dart`): al posto dell'errore
generico compare la scheda «Il tuo ateneo deve approvare UniNotes» con due
azioni.

- **Usa un account Microsoft personale**: rifà l'accesso con
  `prompt=select_account` (se l'impostazione `onedrive_tenant` ammette solo
  account universitari, torna a `common`). È gratuito con 5 GB di OneDrive, ma i file
  e i blocchi OneNote dell'account universitario non sono visibili.
- **Chiedi all'ateneo di approvare UniNotes**: un testo pronto per il servizio
  informatico, con «Copia» e «Condividi». Contiene l'ID applicazione, i
  permessi con il motivo, la frase sui dati che restano sul dispositivo e
  nell'account dello studente, il link alla pagina per gli amministratori e il
  link di consenso amministratore. Se l'app non ha un ID valido il testo non
  contiene né l'ID né il link di consenso. Sotto c'è il suggerimento di usare
  «Richiedi approvazione» se Microsoft lo mostra (flusso di lavoro di consenso
  amministratore attivo nell'ateneo).

La scheda OneDrive mostra sempre, finché l'account non è collegato, il link
«Perché non riesco a collegare l'account universitario?»: la pagina di
Microsoft può restare aperta senza tornare all'app, e allora l'errore non
arriva. Dopo un blocco il link resta anche ad account collegato (impostazione
`onedrive_admin_consent_needed`), con la sola richiesta all'ateneo. Il
calendario Outlook su Windows (Impostazioni → Calendario) usa la stessa
scheda: con l'account personale il calendario «UniNotes» va nell'Outlook di
quell'account e OneDrive resta com'è.

**Pagina per gli amministratori IT**: `sito/amministratori.html`, pubblicata
su <https://simo-magnus.github.io/UniNotes/amministratori.html> e collegata
dal piè di pagina del sito. Spiega l'app, i permessi, dove vanno i dati, come
approvare e come revocare, con una sezione in inglese. L'ID applicazione nella
pagina è il segnaposto `__MS_CLIENT_ID__`: il workflow
`.github/workflows/pagina.yml` lo sostituisce al deploy con il secret
`MS_CLIENT_ID` o, se il secret è vuoto, con `MicrosoftOAuth.defaultClientId`
letto dal codice (come fanno le build). Senza un ID valido la pagina nasconde
il link di consenso invece di mostrarlo rotto.

**Link di consenso amministratore** (lo stesso nell'app e nella pagina,
verificato da `test/microsoft_admin_consent_test.dart`):

```
https://login.microsoftonline.com/organizations/v2.0/adminconsent
  ?client_id=<ID>
  &scope=https://graph.microsoft.com/User.Read https://graph.microsoft.com/Files.ReadWrite
         https://graph.microsoft.com/Notes.Read offline_access
         https://graph.microsoft.com/Calendars.ReadWrite
  &redirect_uri=https://simo-magnus.github.io/UniNotes/amministratori.html
  &state=uninotes
```

- Endpoint v2.0 con `organizations`: vale per qualsiasi tenant, l'ateneo è
  quello dell'amministratore che accede (`common` qui non è ammesso).
- Scope espliciti invece di `.default`: l'approvazione copre esattamente i
  permessi che l'app chiede, compreso il calendario, anche se l'elenco della
  registrazione restasse indietro.
- `redirect_uri` è obbligatorio e deve essere registrato: per questo serve la
  piattaforma «Web» con l'URI della pagina (sezione 2). Microsoft torna sulla
  pagina con `admin_consent=True` oppure con `error`/`error_description`, e la
  pagina mostra l'esito.
- La variante v1 (`https://login.microsoftonline.com/common/adminconsent?client_id=<ID>`)
  non è usata: approva solo i permessi elencati nella registrazione e, senza
  `redirect_uri`, torna a un URI registrato come `http://localhost`, cioè a
  una pagina d'errore del browser anche quando il consenso è riuscito.

In alternativa l'amministratore usa Entra admin center → Applicazioni
aziendali → UniNotes → Autorizzazioni → «Concedi il consenso amministratore»
(approva i permessi elencati nella sezione 3), oppure attiva il flusso di
lavoro di consenso amministratore (Applicazioni aziendali → Consenso e
autorizzazioni → Impostazioni del consenso amministratore), così gli studenti
chiedono l'approvazione da soli con «Richiedi approvazione».
