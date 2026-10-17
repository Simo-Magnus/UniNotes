# OneDrive: registrazione dell'app in Microsoft Entra

Gli **studenti non devono fare nulla**: l'app pubblicata contiene già l'ID
applicazione Microsoft, incluso al momento della build. Questa pagina serve a chi
compila e pubblica l'app (una sola volta).

## 1. Registrazione

1. Apri [Microsoft Entra → Registrazioni app](https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
   con un account Microsoft (va bene un account personale) → **Nuova registrazione**.
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

Non usare le piattaforme «Web» o «Applicazione a pagina singola»: danno gli
errori AADSTS50011 / AADSTS7000218 (l'app li spiega in italiano).

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
  da quello di OneDrive (vedi docs/notifiche.md). Aggiungerlo all'elenco
  evita una pagina di consenso inattesa ma non è obbligatorio: con gli
  account Microsoft il consenso dinamico funziona anche senza.

Non serve il consenso dell'amministratore per gli account personali. Alcuni
atenei bloccano le app esterne (errori AADSTS65001/90094): gli studenti
possono usare un account Microsoft personale (OneDrive gratuito 5 GB).

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

## 5. Cosa fa l'app su OneDrive

Nella cartella scelta (predefinita `UniNotes`, selezionabile con il
navigatore delle cartelle) crea:

```
UniNotes/
  Corsi/<Ateneo - Corso>/Registrazioni | Trascrizioni | Riassunti | Appunti | Claude
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
