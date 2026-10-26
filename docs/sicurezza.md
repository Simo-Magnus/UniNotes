# Sicurezza e privacy dell'app: caccia alle falle

Giri di controllo sulla sicurezza e sulla privacy di UniNotes, con la stessa
struttura della caccia ai crash (`docs/avvio_ed_errori.md`): più controlli in
parallelo, ognuno su una categoria; ogni difetto vero si corregge con la
correzione minima e un test; il giro successivo ricontrolla i resti e le parti
nuove. Le falle non ancora corrette sono descritte qui solo in modo generico.

Test: `app/test/sicurezza_g<N>_<sigla>_test.dart`.

## Giro 1 — Dati sul dispositivo e privacy

25/10/2026, dopo il commit c82f4692. Test: `app/test/sicurezza_g1_dati_test.dart`.

Controllati leggendo il codice: dove l'app salva i dati (database, appunti,
registrazioni, impostazioni, cache, file temporanei, copie `.danneggiato`,
`errori.log`) e cosa resta dopo «Elimina tutti i dati»; dove stanno i token
di OneDrive, Google Drive e Outlook; contenuto del registro degli errori e
dei messaggi di diagnostica; backup ed esportazione; sincronizzazione dei
dati fra dispositivi; notifiche, widget, Live Activity e appunti di sistema;
indicatore del registratore; apertura degli assistenti AI; coerenza con
`PRIVACY.md`.

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| Un backup ricevuto da altri (Importa dati) poteva cambiare la cartella dell'app su OneDrive e Google Drive (`onedrive_folder`, `gdrive_folder`): la sincronizzazione nei due sensi e «Elimina tutti i dati → Cartelle UniNotes» lavoravano allora su un'altra cartella del proprio cloud (es. le sottocartelle «Libri», «Corsi» di «Documenti»). Il backup esportato conteneva anche l'indirizzo email dell'account del calendario (`syscal_calendar_account`, `syscal_writers`), a differenza dell'account OneDrive/Google già escluso | basso | Le quattro impostazioni fra quelle protette (`BackupService.protectedSettings`): non si esportano e il ripristino tiene quelle del dispositivo. Come per la sincronizzazione dei dati, che non le porta già agli altri dispositivi | test gruppo 1 |
| «Elimina tutti i dati» con la sola voce «Registrazioni e trascrizioni» lasciava le registrazioni, trascrizioni e riassunti in «Eliminati di recente» (`.eliminati`) e quelli eliminati su un altro dispositivo (`.cestino-onedrive`, `.cestino-googledrive`) | medio | Dai cestini nascosti si tolgono anche questi; gli appunti eliminati restano con la loro voce «Appunti» | test gruppo 2 |
| Cartelle di lavoro con l'audio delle lezioni nella cartella temporanea (pezzi della trascrizione, testo dal vivo, forma d'onda, taglio, registrazione eliminata a metà): «Elimina tutti i dati» toglieva solo quelle più vecchie di 6 ore e mai `uninotes_cestino_`. Sul PC la cartella temporanea è del profilo utente e resta dopo la chiusura dell'app | basso | Con la voce delle registrazioni `clearTempFiles(allWork: true)` toglie tutte le cartelle di lavoro dell'app, anche recenti, e quelle del cestino; la pulizia di ogni avvio resta com'era. La cartella temporanea si può indicare (`DataEraser.tempDir`): i test non toccano più quella vera | test gruppi 2 e 3 |
| Con «Profilo» o «Database» (senza «Elimina tutto») restavano le copie JSON dei dati scaricate dalla sincronizzazione (`onedrive_backup`, `gdrive_backup`, con i backup di tutti i dispositivi: esami, voti, sessioni) e i file `.ics` con le prove esportate (`calendario`) | basso | Tolti con queste voci (`_deleteDatabaseCopies`) | test gruppo 2 |
| Nelle build pubblicate il testo trascritto di una frase in un'altra lingua finiva nel registro di sistema con `debugPrint` (logcat su Android, console di Apple), leggibile con gli strumenti di sviluppo e incluso nelle segnalazioni di sistema | basso | Solo in debug (`if (kDebugMode)`); controllo statico su tutto `lib/` per `debugPrint` con testo trascritto, prompt o token | test gruppo 4 |

### Falsi allarmi (controllati, nessuna correzione)

- **Token**: i refresh token di OneDrive, Google Drive e Outlook stanno solo
  in `flutter_secure_storage` (Keychain, Keystore, file cifrato con chiave nel
  Gestore credenziali su Windows), mai nel database: non finiscono nei backup,
  nell'esportazione né nella sincronizzazione (test «nessun token nel
  database»). L'access token resta solo in memoria. La chiave di Gemini delle
  versioni precedenti si cancella al primo avvio.
- **Registro degli errori**: resta sul dispositivo, nessuna funzione lo invia
  o lo condivide; contiene tipo, messaggio e punto del codice, al massimo un
  percorso o il nome di un file, come dice l'informativa. Non si sono
  trovati messaggi d'errore dell'app con token (le intestazioni
  `Authorization` non entrano nelle eccezioni).
- **Apertura degli assistenti AI**: l'app apre solo l'indirizzo base del
  servizio; il prompt va negli appunti di sistema, mai nell'indirizzo
  (`prefillUri` esiste ma non è usato). Gli appunti si leggono solo con la
  finestra della richiesta aperta (Trascrivi/Riassumi con Gemini).
- **Segnalazioni su GitHub**: nell'indirizzo solo ateneo, corso,
  insegnamento e anno, come dichiarato.
- **Calendario da un backup**: gli id degli eventi ripristinati non bastano a
  toccare altri eventi: l'app elimina e aggiorna solo gli eventi con il suo
  riferimento nella descrizione.
- **Percorsi da un backup o dal cloud**: i file di libri, materiali e allegati
  si leggono e cancellano solo per nome dentro le cartelle dell'app
  (`BookLibrary`); i percorsi degli appunti nei registri dei dati
  (`appunti:`) non possono uscire dalla cartella degli appunti.
- **Notifiche sulla schermata di blocco**: la notifica «Registrazione in
  corso» è pubblica di proposito (indicatore del microfono, con il nome
  dell'insegnamento); gli avvisi delle prove hanno la visibilità predefinita
  del sistema. Nessun voto o testo degli appunti nelle notifiche.
- **Anteprima nel selettore delle app recenti** (nessun `FLAG_SECURE`):
  proporzionato così; l'app non mostra credenziali o dati di pagamento.
- **Registratore**: sempre visibile mentre registra (notifica in primo piano
  su Android, indicatore del microfono su iPhone, iPad e Mac, icona con
  «registrazione in corso» nell'area di notifica di Windows e avviso quando si
  chiude la finestra). Su Android e iPhone i file restano nello spazio privato
  dell'app (su iOS la cartella Documenti non è condivisa con l'app File).
- **Backup di Android** disattivato (`allowBackup="false"` e regole di
  estrazione che escludono tutto).

### Resti e cose da valutare nei giri successivi

- iPhone, iPad e Mac: le voci del portachiavi usano l'accessibilità
  predefinita del pacchetto, che le include nei backup cifrati del dispositivo
  (iCloud, Finder). Cambiarla (es. «solo questo dispositivo») richiede una
  migrazione delle voci esistenti da provare su un dispositivo vero.
- Le evidenziazioni dei PDF (`evidenziazioni`) restano finché non si sceglie
  «Elimina tutto».
- Su Windows la pulizia delle cartelle di lavoro riconosce le cartelle solo
  dal prefisso del nome nella cartella temporanea del profilo.

### Per l'utente

Nessuna azione esterna richiesta da questo giro. Proposte di testo per
`PRIVACY.md` nel resoconto del giro (sezioni 2, 3, 4, 5, 6.2, 6.3, 8 e
riassunto in inglese).

## Giro 1 — Rete, accessi e dati in ingresso

25/10/2026, dopo il commit c82f4692. Test: `app/test/sicurezza_g1_rete_test.dart`.

Controllati leggendo il codice: accesso a OneDrive/Outlook (Microsoft) e a
Google Drive (PKCE, `state`, server locale di ritorno, scope, rinnovo e
revoca dei token, client id e segreto), tutte le chiamate HTTP (solo HTTPS,
certificati, reindirizzamenti, impronte dei file scaricati), apertura di
link e file esterni (`ExternalLauncher`, `AppLinkGuard`, collegamenti
`uninotes://` di widget e notifiche), file condivisi, aperti con l'app o
trascinati, backup e data pack importati, file del lettore (archivi ZIP,
EPUB, Markdown, immagini e SVG, PDF), pagina `sito/drive-picker.html`,
sincronizzazione dei dati e dei file con il cloud.

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| L'archivio di whisper.cpp per Windows (contiene i programmi che l'app poi avvia) si scaricava senza controllarne l'impronta: solo HTTPS e versione fissata | medio | Impronta SHA-256 dell'allegato ufficiale della versione fissata (`WhisperService.defaultBinariesSha256`): un archivio diverso si scarta prima dell'estrazione | test gruppo 5 |
| Quattro modelli Whisper scaricabili (medium q5_0 e q8_0, large-v2 q8_0, large-v3-turbo q8_0) senza impronta | basso | SHA-256 pubblicati da Hugging Face; un test controlla che ogni modello dell'elenco ne abbia una | test gruppo 5 |
| Il controllo dei programmi prima di aprire un file con il sistema guardava solo l'ultima estensione scritta: un percorso arrivato da un backup o da un altro dispositivo con punti o spazi finali, o con un flusso NTFS, poteva far avviare un programma su Windows. Mancavano anche alcuni tipi che Windows o macOS eseguono o installano all'apertura | medio | `ExternalLauncher.unsafePathReason` controlla anche l'estensione che resta togliendo ciò che Windows ignora; elenco dei tipi bloccati allargato | test gruppo 1 |
| Nel lettore, i collegamenti `note:` (Obsidian) di una nota Markdown si seguivano con qualsiasi percorso, anche di rete: toccandone uno il PC si collegava a un altro computer (che riceve le credenziali di Windows) o apriva file lontani dal documento. I link ai file avevano già il controllo | basso | Stessa regola dei link ai file (`isNearbyLink`): solo file relativi vicini al documento | test gruppo 2 |
| Ritorno del selettore di Google Drive: una richiesta con byte non validi sulla porta locale chiudeva l'attesa con un errore (l'accesso con Microsoft e Google era già protetto) | basso | La richiesta si ignora come le altre estranee | test gruppo 3 |
| Un registro della sincronizzazione dei dati manipolato nella cartella cloud (pochi KB che decompressi diventano GB) poteva esaurire la memoria e chiudere l'app a ogni sincronizzazione | basso | Decompressione a pezzi con limite (256 MB, `SyncSnapshot.maxDecodedBytes`): oltre il limite il registro si ignora | test gruppo 4 |

### Falsi allarmi (controllati, nessuna correzione)

- **Accesso OAuth**: PKCE S256 con verificatore casuale (`Random.secure`),
  `state` casuale controllato al ritorno (le richieste con uno `state` diverso
  si rifiutano e l'attesa continua), server di ritorno solo su `127.0.0.1`
  (e `::1` per Microsoft) con porta scelta dal sistema, chiuso dopo l'accesso
  o dopo 5 minuti; errori del provider mostrati con l'HTML protetto. Un
  `code` intercettato non basta senza il verificatore, che non lascia mai
  l'app. Sul telefono il ritorno usa lo schema dell'app con lo stesso PKCE.
- **Client id e segreto**: l'id Microsoft è pubblico (client senza segreto);
  il «segreto» del client Google di tipo «App desktop» per Google non è un
  segreto nelle app installate (la protezione viene da PKCE). Nessuno dei due
  dà accesso ai dati senza l'accesso dello studente.
- **Scope**: Google solo `drive.file`. Microsoft `Files.ReadWrite` serve a
  scegliere la cartella di sincronizzazione in qualsiasi punto di OneDrive
  (dichiarato in `PRIVACY.md`); `Calendars.ReadWrite` solo quando si attiva il
  calendario di Outlook, con un token separato.
- **Revoca**: Google revoca il refresh token (nel corpo della richiesta, non
  nell'indirizzo); Microsoft non ha una revoca per singola app dei client
  pubblici, il token si cancella dal dispositivo. Tenant e id applicazione
  arrivati da un backup non si usano (impostazioni protette); il tenant si
  normalizza, quindi l'accesso va sempre a `login.microsoftonline.com`.
- **HTTPS e certificati**: nessun `badCertificateCallback` né
  `HttpOverrides`; endpoint fissi su HTTPS. I download non passano da HTTPS a
  HTTP nei reindirizzamenti; il link di scaricamento di OneDrive si usa senza
  il token; il database dei corsi ha un limite di 50 MB, impronte SHA-256 per
  file e un indirizzo alternativo solo HTTPS (non ripristinabile da un
  backup).
- **Modelli Parakeet e VAD**: impronte SHA-256 controllate.
- **Link esterni**: `ExternalLauncher.openUrl` apre solo http, https, mailto,
  tel e gli schemi degli store (niente `javascript:`, `file:`, `intent:`,
  `content:`); nei documenti del lettore sono cliccabili solo http, https e
  mailto; gli appunti non hanno link cliccabili; i PDF non aprono link.
- **Collegamenti `uninotes://`, widget e notifiche**: portano solo a una
  sezione o a una schermata (prova, Focus, Registra); nessuna azione che
  cambia o cancella dati. Il ritorno dal browser riporta solo l'app in primo
  piano.
- **Dati in ingresso**: i file condivisi, aperti con l'app o trascinati si
  copiano in Materiali con un nome ripulito, dopo la scelta della cartella;
  i nomi dei file remoti della sincronizzazione non possono uscire dalla
  cartella dell'app (già corretto in un giro precedente); l'estrazione degli
  archivi (pacchetto `archive`) controlla i percorsi e i collegamenti
  simbolici; le voci ZIP del lettore hanno un limite di decompressione; le
  immagini incorporate nelle note e i link ai file si risolvono solo vicino
  al documento. Backup e data pack: JSON controllato per tipo, colonne
  filtrate, impostazioni di sicurezza mai ripristinate.
- **Lettore**: nessuna WebView, nessuno script eseguito; i formati si leggono
  dai byte del file (EPUB, Office, HTML in testo); gli SVG non caricano
  risorse remote; i PDF con PDFium senza JavaScript.
- **Pagina del selettore di Google Drive**: token nel frammento dell'indirizzo
  (non arriva al server), tolto dalla barra e dalla cronologia, nessun
  referrer; ritorno ammesso solo verso `127.0.0.1:<porta>/picker` o lo schema
  del client Google; gli id ricevuti dall'app si filtrano; niente
  `postMessage`.

### Resti e cose da valutare nei giri successivi

- Il convertitore per Windows scaricato a richiesta (per le registrazioni del
  telefono) viene da un indirizzo che cambia a ogni versione pubblicata,
  quindi non ha un'impronta fissa da controllare (solo HTTPS dal sito
  ufficiale).
- Il lettore multimediale apre i file con un motore che riconosce il
  contenuto anche dai byte: da verificare se un file multimediale rinominato
  con dentro una scaletta di indirizzi web può far fare richieste in rete.
- Il pulsante «Apri in OneNote» di una pagina OneNote usa uno schema che
  l'elenco dei link ammessi non contiene: non è una falla, ma il pulsante non
  apre l'app (funzione da ricontrollare).

### Per l'utente

Nessuna azione esterna obbligatoria da questo giro (dettagli e proposte nel
resoconto).

## Giro 1 — Superfici native e installatori

25/10/2026, dopo il commit c82f4692. Test: `app/test/sicurezza_g1_nativo_test.dart`
(controlli sui sorgenti: Kotlin e C++ compilati a parte, Swift e Inno Setup
solo letti).

Controllati: manifest Android con i componenti aggiunti dai pacchetti
(attività, receiver, servizi, fornitori esportati, `FileProvider` e loro
percorsi, permessi), codice Kotlin (file condivisi e «Apri con», widget,
notifica della registrazione, Non disturbare, calendario e conferma
dell'account, sincronizzazione in background, `PendingIntent`, registro di
sistema), backup e trasferimento tra telefoni, traffico in chiaro, build di
rilascio; Info.plist, diritti e codice Swift di iPhone, iPad e Mac (ATS,
schema `uninotes://`, file aperti con l'app, App Group dei widget, sandbox);
runner di Windows (copia unica, schema `uninotes:`, attivazione dei toast,
«Apri con», registro, programmi di sistema avviati dall'app, caricamento
delle DLL); installatore Inno Setup e pacchetto MSIX.

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| Android, «Condividi → UniNotes» e «Apri con»: il controllo che esclude i fornitori dell'app guardava solo il nome. Scritto con l'utente davanti (`content://0@<pacchetto>.fileProvider…`), il nome superava il controllo ma Android apriva lo stesso il fornitore dell'app (quello di open_filex vede tutto il file system dell'app): un'altra app poteva far copiare a UniNotes i suoi file privati (preferenze, database), poi proposti per il salvataggio in un insegnamento e nel cloud | medio | `IncomingShare.isOwnProvider`: nome senza la parte prima di «@», come fa Android, e in più il pacchetto a cui appartiene il fornitore (`resolveContentProvider`) | test «file condivisi da altre app» |
| Windows, schema `uninotes:`: con l'app chiusa gli argomenti dell'avvio arrivavano all'app. Un indirizzo con le virgolette aperto da un programma che non le codifica (i browser lo fanno) diventava più argomenti, per esempio quello della schermata di disinstallazione (che chiede comunque conferma prima di eliminare) | basso | `FromLink` nel runner (primo argomento, schema senza distinguere le maiuscole): avviata da un collegamento l'app parte senza argomenti, o torna in primo piano quella già aperta | test «schema uninotes:» |
| Disinstallatore di Windows: toglieva per intero la cartella del programma, anche i file non installati. La casella della cartella accetta qualsiasi percorso: con una cartella già piena scritta a mano (es. «D:\Programmi», o «Documenti\UniNotes», dove l'app tiene appunti e registrazioni) la disinstallazione l'avrebbe svuotata | medio | `CartellaDelProgramma`: la cartella si toglie per intero solo se si chiama «UniNotes» e non sta in Documenti; altrimenti si tolgono solo i file installati | test «installatore di Windows» |
| L'app avviava `reg`, `cmdkey`, PowerShell, `rundll32` ed Esplora file con il solo nome: Windows li cerca prima nella cartella del programma e in quella di lavoro, poi in System32 (un programma con lo stesso nome messo lì partirebbe al suo posto) | basso | `WindowsTools`: percorso completo nella cartella di Windows; controllo statico su tutto `lib/` | test «programmi di sistema» |
| Android: open_filex aggiunge al manifest l'accesso a foto e video (`READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`), che l'app non usa e che Google Play ammette solo per le app della galleria; l'informativa non li elencava | basso | Tolti dal manifest finale (`tools:node="remove"`) | test «accesso a foto e video» |

### Falsi allarmi (controllati, nessuna correzione)

- **Attività esportate**: solo il lanciatore, «Condividi/Apri con» e il
  ritorno dall'accesso Microsoft/Google, tutte con `taskAffinity` vuota (niente
  «task hijacking»). La schermata chiesta con l'extra `uninotes_route` da
  un'altra app apre solo una sezione o una scheda (anche «Registra» apre il
  registratore senza avviarlo). Il ritorno dell'accesso lo protegge PKCE.
- **Receiver e servizi**: tutti non esportati, tranne il receiver
  dell'accensione di flutter_foreground_task, che con `stopWithTask` non fa
  nulla. Tutte le `PendingIntent` dell'app sono immutabili e esplicite.
- **FileProvider** di open_filex e share_plus: non esportati, si aprono solo
  gli indirizzi concessi dall'app a un'altra app per un file scelto
  dall'utente («Apri», «Apri con», «Condividi»).
- **Backup**: `allowBackup="false"`, `fullBackupContent="false"` e regole che
  escludono tutto anche dal trasferimento tra telefoni. Niente traffico in
  chiaro (nessuna eccezione; da Android 9 è vietato), nessuna WebView usata
  dall'app, nessun messaggio nel registro di sistema dal codice Kotlin.
- **Calendario**: l'app scrive ed elimina solo gli eventi con il suo
  riferimento; la conferma dell'account mostra solo l'account del calendario
  scelto, che diventa visibile all'app e a nessun'altra.
- **iPhone, iPad e Mac**: nessuna eccezione ad App Transport Security; lo
  schema `uninotes://` porta solo a una schermata, all'esito del comando Focus
  o in primo piano; i file aperti con l'app si copiano con il loro nome
  (ultimo pezzo del percorso) nella cartella temporanea. App Group condiviso
  solo con i widget (prossime prove). Mac in sandbox: microfono, calendario,
  rete in uscita, ascolto solo su `localhost` (ritorno dall'accesso) e solo i
  file scelti; nessun diritto per eseguire codice non firmato.
- **Windows**: la copia unica usa un mutex della sessione (`Local\`), il
  ritorno dal browser porta solo la finestra in primo piano; l'attivazione dai
  toast passa solo il percorso della schermata; «Apri con» usa la finestra di
  Windows sul file scelto; l'app scrive nel registro solo chiavi
  dell'utente (`HKCU`: schema, icona e AUMID dei toast). Le DLL dell'app stanno
  nella cartella del programma accanto a uninotes.exe (dell'utente, come ogni
  installazione per utente); `SetDefaultDllDirectories` non aggiunto: le
  librerie dei pacchetti si caricano per nome dalla cartella del programma e
  il cambio va provato su una build vera.
- **Installatore**: per utente, senza amministratore, in
  `%LOCALAPPDATA%\Programs\UniNotes`; dopo l'installazione avvia l'app solo
  con la casella spuntata e con i permessi dell'utente; `taskkill` con il
  percorso completo.
- **MSIX**: solo `internetClient`, `microphone` e `runFullTrust` (necessario
  per un'app desktop Win32 come quella di Flutter).

### Resti e cose da valutare nei giri successivi

- Il FileProvider di open_filex dichiara tutto il file system (`root-path`):
  non è raggiungibile da fuori senza un indirizzo concesso, ma restringerlo
  alle cartelle dell'app (risorsa `filepaths.xml` sostituita nell'app e «Apri
  con» con `FileProvider.getUriForFile`) va provato su un telefono.
- La build Android di rilascio usa la chiave di debug se manca
  `key.properties`, senza errore.
- Pacchetto per Mac: firma, notarizzazione e quarantena dello zip/dmg da
  documentare con la pubblicazione.

### Per l'utente

Nessuna azione esterna obbligatoria. Da provare su un dispositivo vero:
«Condividi → UniNotes» da Foto, File e Gmail su Android; disinstallazione
su Windows (cartella predefinita); ritorno dall'accesso a OneDrive con l'app
chiusa e aperta; «Apri con» e «Mostra nella cartella» su Windows.

## Giro 1 — Repository, build e sito

25/10/2026, dopo il commit c82f4692. Test: `app/test/sicurezza_g1_repo_test.dart`
(controlli statici sui workflow, su Dependabot, sullo script della copia
pubblica e sulle pagine del sito; i controlli sui file che esistono solo
nella repo privata si saltano nella copia pubblica).

Controllati: tutta la storia delle due repository (ogni versione di ogni file,
anche cancellato, più autori e messaggi dei commit) con uno scanner di
espressioni regolari per i formati noti di chiavi e token, entropia, nomi di
file sensibili (keystore, certificati, `.env`, `key.properties`), indirizzi
email e numeri di telefono; l'esportazione della copia pubblica; i workflow di
GitHub Actions; le dipendenze (pacchetti Dart, Gradle, Python, azioni) con il
database pubblico OSV; le pagine del sito; le impostazioni pubbliche delle
repository su GitHub.

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| Workflow dell'app con `permissions: contents: write` per tutti i job: il token di analisi, test e build (anche quelli che eseguono il codice di una pull request dello stesso repository e gli strumenti scaricati durante la build) poteva scrivere nel repository, creare tag e release. Il workflow della prova di trascrizione non dichiarava permessi (valeva l'impostazione del repository) | medio | `contents: read` per tutto il workflow; scrivono solo i job che pubblicano («ultima-build», «release» e il salvataggio del database), con i propri permessi | test «permessi del token», «scrivono solo i job che pubblicano» |
| Azioni di terzi indicate con un'etichetta mobile (`@v2`, `@v3`): chi controlla l'azione può cambiare il codice eseguito con i secret di firma | medio | Tutte le azioni fissate allo SHA del commit, con la versione nel commento; Dependabot le aggiorna | test «azioni fissate allo SHA» |
| `actions/checkout` lasciava il token nella configurazione git della cartella di lavoro, leggibile dai passi successivi | basso | `persist-credentials: false` ovunque tranne nel job che deve fare il push | test «checkout non lascia il token» |
| Secret e valori inseriti a mano (`workflow_dispatch`) scritti direttamente nel testo degli script dei passi: finiscono nel file temporaneo dello script e un valore con caratteri speciali può cambiare il comando | basso | Passati come variabili d'ambiente del passo | test «secret e valori scritti a mano solo come variabili d'ambiente» |
| La copia pubblica non aveva un controllo automatico: un file nuovo nella radice (grafiche, mappe di id, file di prova) o una chiave committata per sbaglio sarebbe stato esportato | medio | Controllo alla fine dell'esportazione e con `--verifica`: solo le voci ammesse nella radice, nessun file privato, nessun keystore o file di configurazione locale, nessuna chiave o token riconoscibile, nessun indirizzo email personale (tranne quelli pubblici del progetto); la cartella delle grafiche è fra i file privati | test «esclude i file privati e si controlla da sola»; prova con una copia finta (7 problemi trovati) e con la copia attuale (superata) |
| Sito: il carattere IBM Plex Sans veniva da Google Fonts (pagina di download e pagina per gli amministratori IT): ogni visita mandava a Google l'indirizzo IP del visitatore, senza che l'informativa lo dicesse | medio | Carattere servito dal sito (`sito/fonts/`, licenza OFL inclusa) | test «nessuno script né carattere da server di terzi» |
| Sito: lo script di GoatCounter caricato da un server esterno senza versione né controllo d'integrità, anche nelle pagine dell'informativa e per gli amministratori; con il percorso inviava anche i parametri dell'indirizzo (ritorno dal consenso Microsoft, parametri aggiunti dai social) | basso | Conteggio con una sola richiesta al contatore scritta nella pagina, come già nei link corti: solo il percorso (e la sigla `?s=` nella pagina dei link), stesso interruttore `#toggle-goatcounter` | test «il contatore riceve solo il percorso» |
| Sito senza Content-Security-Policy | basso | Policy nel `<meta>` di ogni pagina (tranne il selettore di Google Drive): solo file del sito e il contatore delle visite | test «Content-Security-Policy» |

Nella storia delle due repository non ci sono chiavi API, token, client
secret, password, chiavi private o keystore, né file `.env` o
`key.properties`; tutti i commit hanno come autore l'indirizzo noreply di
GitHub. Nessuna vulnerabilità nota (OSV) nei 210 pacchetti Dart né nelle
azioni; una nel plugin Gradle di Kotlin (vedi sotto).

### Falsi allarmi (controllati, nessuna correzione)

- **Identificativi nelle build pubblicate**: l'ID dell'app Microsoft, gli ID
  client OAuth di Google e il numero del progetto non sono segreti. Il
  «client secret» di Google per PC e Mac è quello di un'app installata, che
  Google stesso considera non riservato (la protezione è PKCE con il ritorno
  su 127.0.0.1). La chiave API del selettore di Google Drive va comunque
  nella pagina pubblica `drive-picker.html` per funzionare: la protegge la
  restrizione in Google Cloud (vedi «Per l'utente»), non il segreto.
- **Token della sessione di concentrazione di Windows**
  (`WINDOWS_FOCUS_LAF_TOKEN`): è un token di Microsoft per una funzione ad
  accesso limitato, legato all'identità del pacchetto dello Store; va dentro
  l'app per definizione e da solo non serve ad altre app. È solo nel
  pacchetto MSIX (artefatto privato del workflow), non nelle release.
- **Build pubblicate**: niente simboli di debug (`.pdb`, `.dSYM`, mappe di
  offuscamento) nei file della release; i modelli scaricati durante la build
  sono controllati con SHA-256 (SHA-1 per il modello piccolo dei telefoni).
- **Cache delle build**: la cache dei modelli è per chiave fissa e una pull
  request da un fork non può scrivere quella del ramo principale; i file
  sono comunque controllati con l'impronta.
- **Pull request da un fork**: girano con il token in sola lettura e senza
  secret; non ci sono trigger `pull_request_target` o `workflow_run`.
- **Certificati `.pem`** in `tools/db_builder/adapters/certs`: certificati
  pubblici di autorità intermedie, nessuna chiave privata.
- **Indirizzi email** nelle pagine e nei documenti: solo quelli pubblici del
  progetto; quelli nei test e negli esempi sono inventati.
- **Link corti e pagina dei link**: destinazioni fisse scritte nel
  generatore, nessun reindirizzamento verso un indirizzo preso dalla
  richiesta; tutti i link in una nuova scheda hanno `rel="noopener"`. Il
  selettore di Google Drive torna solo a 127.0.0.1 o allo schema del client
  Google dell'app.
- **Casella di assistenza** (gruppo Google): l'archivio dei messaggi non è
  visibile senza accesso.
- **Strumenti Python**: nessun `verify=False`, `shell=True` o `eval`;
  l'archivio della copia pubblica si estrae con il filtro `data`.

### Resti e cose da valutare nei giri successivi

- Plugin Gradle di Kotlin 2.4.0: vulnerabilità nota nella cache di build
  (corretta da 2.4.20). Riguarda solo chi condivide una cache di build
  remota, che il progetto non usa: aggiornare con la pull request di
  Dependabot e provare la build Android.
- Database: alcuni testi copiati dalle pagine degli atenei contengono
  indirizzi email personali di docenti; il controllo della copia pubblica li
  elenca come avvisi. Vanno tolti o sostituiti nel database.
- Sul sito non si possono impostare intestazioni HTTP (GitHub Pages): niente
  `frame-ancestors`/`X-Frame-Options` né HSTS propri. Le pagine non hanno
  azioni da proteggere da un riquadro; il selettore di Google Drive non ha
  una policy perché carica gli script di Google (da provare con una policy
  dedicata).
- Le build Android senza la chiave di firma nei secret usano una chiave di
  debug diversa a ogni esecuzione (già annotato nel giro «Superfici native»).
- `choco install innosetup` e i modelli della prova di trascrizione si
  scaricano senza versione o impronta fissata (job senza secret).

### Per l'utente

Impostazioni di GitHub e dei servizi da controllare a mano (passaggi nel
resoconto del giro): protezione del ramo principale della repo pubblica,
scansione dei segreti con push protection, avvisi e aggiornamenti di
sicurezza di Dependabot, segnalazione privata delle vulnerabilità,
restrizioni della chiave API di Google, regole dell'ambiente `github-pages`.

## Giro 2 — App e codice nativo

25/10/2026, dopo il commit 622300d5. Test: `app/test/sicurezza_g2_app_test.dart`.

Ricontrollati i resti del giro 1 sull'app e sul codice nativo e, a occhi
nuovi, le parti cambiate di recente: pila delle sezioni principali
(`section_stack.dart`, `section_active.dart`), conferma dell'account del
calendario e ricontrollo del caricamento su Android
(`UniNotesCalendar.kt`), «Condividi → UniNotes» dopo la correzione del giro
1 (`IncomingShare.kt`), programmi di Windows (`windows_tools.dart`).

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| iPhone, iPad e Mac: i refresh token di OneDrive, Google Drive e Outlook stavano nel portachiavi con l'accessibilità predefinita del pacchetto («quando sbloccato»), che li include nei backup del dispositivo ripristinabili su un altro iPhone o Mac | basso | Accessibilità «dopo il primo sblocco, solo questo dispositivo» per tutte le voci (`SecureCloudSecrets.storage`); al primo avvio le voci esistenti si riscrivono con lo stesso valore (`migrateAppleAccessibility`, prima che parta la sincronizzazione). Il pacchetto (flutter_secure_storage_darwin ≥ 0.4.3) legge le voci con qualsiasi accessibilità e, scrivendo, toglie la vecchia e aggiunge la nuova: se l'aggiunta fallisce il token si rimette com'era; con il portachiavi bloccato non cambia nulla e si riprova al prossimo avvio. Segno della migrazione fra le impostazioni del dispositivo (`keychain_this_device`, non nei backup) | test gruppo 1 (canale finto con il comportamento del pacchetto, versione minima nel `pubspec.lock`) |
| Telefono: il ritorno dall'accesso a Microsoft o Google arriva a un'attività esportata, che qualsiasi app può aprire. Lo `state` sbagliato faceva già fallire l'accesso, ma il messaggio d'errore mostrava il testo `error_description` scritto da chi aveva aperto il ritorno (testo ingannevole dentro l'app) | basso | Con uno `state` diverso messaggio fisso (`foreignReturnMessage`), senza codice né testo presi dal ritorno | test gruppo 3 |
| Sincronizzazione dei dati: un registro con un percorso assoluto nella colonna degli allegati collegati agli appunti si applicava così com'era: l'allegato apriva (e, come appunto, modificava) un file qualsiasi del disco | basso | Ammesso solo un percorso dentro la cartella degli appunti (o di ripiego) o uguale a quello che la riga ha già su questo dispositivo; altrimenti vuoto, senza toglierlo agli altri dispositivi | test gruppo 4 |
| Filtri delle esclusioni arrivati dalla sincronizzazione o da un backup: il controllo dei giri sui crash fermava solo le forme più note di espressione regolare lenta (`(a+)+`, `(a\|aa)*`); altre (gruppi annidati, sequenze di gruppi con alternative, molti quantificatori, riferimenti all'indietro, testi lunghissimi) potevano bloccare l'app a ogni lettura del piano | basso | Si usano come espressioni solo quelle dal costo limitato (`ExclusionFilter.isSafePattern`: al massimo 200 caratteri, 2 quantificatori — 3 se ancorata all'inizio —, 5 gruppi non annidati, 30 alternative, nessun quantificatore su un gruppo complesso, nessun riferimento all'indietro); le altre come testo semplice; al massimo 100 filtri. Le caselle di Impostazioni e i filtri semplici restano espressioni | test gruppo 5 e test dei giri sui crash |
| Le evidenziazioni dei PDF restavano dopo «Elimina tutti i dati» se non si sceglieva tutto | basso | Tolte con la voce «Libri e materiali scaricati, con le evidenziazioni», come nella sincronizzazione (casella «Libri e materiale didattico… con le evidenziazioni») | test gruppo 6 |
| Pulizia delle cartelle temporanee: sul PC la cartella temporanea è di tutti i programmi dell'utente, e le cartelle `whisper_…` e `parakeet_…` di un altro programma si cancellavano come quelle dell'app | basso | Cartelle nuove con il prefisso `uninotes_`; quelle delle versioni precedenti si tolgono solo se il resto del nome è la parte casuale di `Directory.createTemp` (`isAppTempWorkDir`) | test gruppo 7 (anche un controllo su tutto `lib/`) |
| Spazio libero su Windows: l'unità finiva nel testo del comando PowerShell | basso (3 caratteri, non sfruttabile in pratica) | Passata come variabile d'ambiente | test gruppo 8 (anche il comando vero sul PC) |
| Lettore multimediale (media_kit, mpv): un file con estensione audio o video che in realtà è una scaletta di testo (M3U, PLS, CUE, EDL, ASX, XSPF, DASH, elenco di FFmpeg) si apriva come elenco e mpv seguiva gli indirizzi web che contiene, anche da un file locale: aprendo un allegato o una registrazione arrivati da altri l'app si collegava a un server scelto da chi aveva scritto il file | medio | Prima di aprire il lettore (registrazioni e lettore dei documenti) si guardano i primi 1024 byte: un testo non si apre (`MediaGuard`), un audio o video vero ha sempre byte di controllo nell'intestazione. FFmpeg da riga di comando (forma d'onda, conversioni) limita già gli indirizzi annidati ai file locali | test gruppo 9 |
| «Apri in OneNote» non funzionava: lo schema `onenote:` non è fra quelli ammessi | — (funzione) | Apertura dedicata solo dalla pagina OneNote (`ExternalLauncher.openOneNote`): solo `onenote:` seguito da un indirizzo `https:` senza spazi; senza l'app OneNote si apre la pagina nel browser. L'elenco degli schemi di `openUrl` non cambia | test gruppo 10 |
| La pulizia della chiave di Gemini delle versioni precedenti si segnava fatta anche con il portachiavi che non rispondeva: la chiave poteva restare per sempre | basso | Si segna solo dopo la cancellazione riuscita; altrimenti si riprova al prossimo avvio | test gruppo 11 e test aggiornato in `crash_r4_aggiornamento_test.dart` |
| Script aperti con il programma predefinito: su Windows (e sul Mac con il «Python Launcher») un `.py` si esegue con un doppio clic se Python è installato; lo stesso per Perl, Ruby, Tcl, AutoHotkey, AutoIt, e la Guida HTML `.chm` può avviare script | medio | «Apri» rifiuta questi tipi sul PC e sul Mac, con un messaggio che indica «Apri con…» (l'app la sceglie lo studente, per esempio un editor) o il lettore di UniNotes, che li mostra come testo; nessun dialogo in più. Sul telefono nessuno si esegue e restano apribili. Aggiunti ai tipi sempre bloccati `.wsb`, `.tool`, `.fileloc`, `.inetloc`, `.appimage` | test gruppo 12 |
| `WindowsTools`: una variabile `SystemRoot` relativa o di rete riportava la ricerca dei programmi in cartelle altrui | basso | Solo un percorso completo su un'unità locale, altrimenti `C:\Windows` | test gruppo 13 |

### Falsi allarmi (controllati, nessuna correzione)

- **Ritorno dell'accesso sul telefono** (`CallbackActivity` di
  flutter_web_auth_2, esportata per forza perché la apre il browser): un
  ritorno falso con l'accesso in corso lo fa fallire (lo `state` è casuale e
  non lascia mai l'app, il `code` senza il verificatore PKCE non serve) e
  l'app non resta bloccata (l'attesa finisce con l'errore, si riprova); senza
  un accesso in corso non succede niente. L'attività non ha il filtro per i
  testi condivisi.
- **Sezioni nascoste**: restano in memoria ma non si disegnano (nemmeno
  nell'anteprima delle app recenti), non sono lette dal lettore dello
  schermo e non ricevono tocchi; cambiando corso, anno o profilo (anche con
  «Elimina tutti i dati») si buttano.
- **Conferma dell'account del calendario**: nome e tipo dell'account vengono
  dal calendario scelto, letto dal fornitore del calendario di Android (il
  backup salva solo l'id); la finestra è quella del sistema e il testo è
  fisso. Il ricontrollo del caricamento richiede solo la sincronizzazione
  dell'account del calendario e legge solo quanti eventi restano da caricare.
- **«Condividi → UniNotes»**: il controllo dei fornitori dell'app toglie la
  parte prima di «@» come Android e guarda il pacchetto del fornitore; un
  fornitore con lo stesso prefisso di un'altra app si salta (nessun danno).
- **Copia di file negli appunti di sistema su Windows**: i percorsi passano
  già in una variabile d'ambiente.

### Resti e cose da valutare nei giri successivi

- **FileProvider di open_filex (`root-path`) non ristretto.** I file che
  l'app apre su Android stanno in `app_flutter` (appunti e registrazioni),
  `files` (libri, materiali, allegati) e `cache`. `app_flutter` non è sotto
  nessuno dei percorsi standard di FileProvider: si raggiunge solo con
  `root-path` (percorso fisso con il nome del pacchetto e l'utente 0, che non
  vale nei profili di lavoro) o con `files-path path="../app_flutter"` (si
  appoggia alla normalizzazione dei percorsi di androidx). Nessuna delle due
  si può provare senza un telefono, e un errore renderebbe impossibile
  aprire appunti e registrazioni con altre app. Il fornitore non è esportato
  e dà accesso solo agli indirizzi concessi per un file scelto dallo
  studente. Passi per chi lo prova: `app/android/app/src/main/res/xml/filepaths.xml`
  con `files-path`, `cache-path` e `files-path name="flutter"
  path="../app_flutter"` (stesso nome di risorsa, sostituisce quella del
  pacchetto); in `OpenWith.kt` l'indirizzo con
  `androidx.core.content.FileProvider.getUriForFile` invece di `/root…`;
  provare «Apri» e «Apri con…» di un PDF dei libri, di un appunto e di una
  registrazione, anche in un profilo di lavoro, e «Condividi».
- Lettore multimediale: in più si potrebbero passare a mpv le opzioni
  `access-references=no` e un elenco di protocolli di FFmpeg con il solo
  `file` per i file locali (da provare sui dispositivi: cambia la
  configurazione del lettore).
- I tipi di script già bloccati del tutto (`.js`, `.sh`, `.bat`, `.ps1`…)
  potrebbero seguire la stessa regola dei `.py` («Apri con…» ammesso), utile
  per i corsi di programmazione: decisione da prendere.

### Per l'utente

Nessuna azione esterna. Da provare su un dispositivo vero: su iPhone e Mac
con OneDrive o Google Drive già collegati, aggiornare l'app e controllare
che resti collegata (anche dopo un riavvio del telefono, prima e dopo lo
sblocco, e con la sincronizzazione in background); «Apri in OneNote» su
Windows, Mac, iPhone e Android con e senza l'app OneNote; aprire una
registrazione e un video nel lettore; «Apri» e «Apri con…» di un `.py` su
Windows.

## Giro 2 — Repository, build, sito e database

25/10/2026, dopo il commit 49f94255. Test: `app/test/sicurezza_g2_repo_test.dart`
(controlli statici; quelli sui file della sola repo privata si saltano nella
copia pubblica). Script: `python tools/db_builder/togli_email.py --verifica`
(nessun indirizzo email personale nel database) e il controllo della copia
pubblica con `--verifica` (repo privata).

Ricontrollati: firma della build Android, download e dipendenze dei
workflow, pagine del sito (anche quelle generate), testi del database
copiati dalle pagine degli atenei, controllo della copia pubblica (falsi
negativi), sintassi dei workflow dopo il giro 1 (PyYAML) ed espressioni
`${{ }}` rimaste nei comandi.

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| Build Android: senza la chiave nei secret (o con `key.properties` incompleto) la build di rilascio si firmava in silenzio con la chiave di debug, anche per la release dei tag `v*` e per l'AAB di Google Play. La chiave di debug del runner cambia a ogni esecuzione: un APK così non si aggiorna né con la build successiva né con quello firmato con la chiave vera (bisogna disinstallare e si perdono i dati dell'app sul telefono); una versione pubblicata così non avrebbe potuto ricevere aggiornamenti firmati | medio | Gradle si ferma se `UNINOTES_FIRMA_OBBLIGATORIA=1` e manca una chiave completa (alias, password, keystore esistente). Il workflow la rende obbligatoria per i tag `v*`, crea l'AAB solo con la chiave vera e pubblica la release solo con `firma=release`; l'«ultima-build» di prova resta possibile con la chiave di debug ma il titolo e la descrizione lo dicono, con l'avviso di esportare i dati prima di reinstallare | test gruppo «firma Android»; configurazione Gradle provata in locale con e senza firma obbligatoria |
| Pagina per gli amministratori: il testo `error_description` del ritorno dal consenso Microsoft si mostrava così com'era nell'indirizzo; chiunque poteva mandare un link al sito del progetto con un messaggio a scelta (es. un finto invito a scrivere a un indirizzo) | basso | Si mostrano solo i codici di errore OAuth noti e il codice `AADSTS` (sole cifre) | test «amministratori» |
| Selettore di Google Drive senza Content-Security-Policy (la pagina riceve il token di accesso nel frammento) | basso | Policy dedicata: script solo per impronta SHA-256 (quello della pagina) e da `apis.google.com`, riquadri, immagini e richieste solo verso Google, niente plugin, `base-uri` e moduli; a capo LF fissati in `.gitattributes` perché l'impronta resti valida | test «selettore di Google Drive»; in un browser il caricatore di Google e il riquadro del selettore si aprono senza violazioni della policy |
| Testi del database con indirizzi email personali (caselle Gmail, Libero, Tiscali di docenti e copisterie) copiati dalle pagine degli atenei, nei file pubblici `corsi/`, `moduli/` e `per_corso/` | basso | Filtro nella build (`pulizia.senza_email_personali`: in `build_db.py`, `dividi_per_corso.py` e nell'unione dei moduli): nei testi dei libri l'indirizzo diventa «[indirizzo nella pagina dell'ateneo]», le righe di contatto lette come moduli o argomenti si tolgono; le caselle istituzionali restano. File esistenti corretti con `tools/db_builder/togli_email.py` (impronte di `meta.json` e file per corso rigenerati); nel controllo della copia pubblica un indirizzo personale nel database ora blocca la pubblicazione | test gruppo «database»; `togli_email.py --verifica` |
| Controllo della copia pubblica: leggeva solo i file con un'estensione di testo nota; non vedeva SVG e altri testi con estensioni nuove, metadati di immagini e PDF, autore e testo dentro documenti Office/OpenDocument/EPUB, copie di database o registri (`.sqlite`, `.log`, …) e cartelle private dentro altre cartelle | basso | Ogni file si legge (i binari byte per byte, per i metadati in chiaro), le voci degli archivi ZIP si controllano, nuovi nomi vietati; un file troppo grande per il controllo blocca la copia | test «controllo della copia pubblica»; copia finta con 9 falle note (tutte trovate) e copia pubblica attuale (solo gli indirizzi del database, già corretti) |
| `choco install innosetup` senza versione; modelli Whisper della prova di trascrizione scaricati dal ramo principale senza impronta; whisper.cpp della prova clonato per tag senza controllo del commit; `requirements.txt` del database senza versioni (pypdf con vulnerabilità note per PDF malformati, letti dalle pagine degli atenei) | basso | Inno Setup 6.7.1 fissato (avviso se la firma di `ISCC.exe` non è valida); modelli da una revisione fissa di Hugging Face con SHA-256 controllato e solo HTTPS; commit di whisper.cpp controllato; `requests==2.34.2`, `pypdf==6.21.2`, tolto `pdfplumber` (non usato) | test gruppo «download nei workflow» |
| Plugin Gradle di Kotlin 2.4.0 (vulnerabilità della cache di build, GHSA-r937-wjx7-w2jp) | basso | 2.4.21 (stessa versione del linguaggio); la build Android la prova la build automatica | test «plugin Gradle di Kotlin» |
| Pagine del sito: commenti nel sorgente che nominavano e descrivevano il servizio del contatore delle visite | basso | Commenti tolti dai modelli (`pagine_legali.py`, `genera_link_sito.py`) e dalle pagine scritte a mano; interruttore del conteggio rinominato `#toggle-conteggio` (l'indirizzo tecnico del contatore resta nel codice) | test «il sito non nomina il contatore» |

Aggiunti anche `SECURITY.md` (segnalazioni private con GitHub, niente
indirizzi personali) e, nel `.gitignore`, i file di lavoro della radice della
repo privata.

### Falsi allarmi (controllati, nessuna correzione)

- **Espressioni `${{ }}` nei comandi dei workflow**: restano solo valori
  interni (numero dell'esecuzione, versione calcolata dal job di test,
  `matrix.shard`, `github.event_name`), non testi scelti da altri.
- **Sintassi dei workflow**: i quattro file si leggono con PyYAML.
- **Documenti di prova Office e OpenDocument** nella copia pubblica: autore
  «UniNotes», nessun dato personale.
- **Inno Setup preinstallato** nel runner di Windows: si usa quello, la
  versione fissa vale solo quando manca.
- **Numeri di telefono nel database**: sono di uffici e copisterie, scritti
  dagli atenei nelle pagine degli insegnamenti; restano avvisi del controllo.

### Resti e cose da valutare nei giri successivi

- La cronologia della repo pubblica contiene ancora le versioni precedenti
  dei file del database con quegli indirizzi (dati già pubblicati dagli
  atenei): riscriverla non è proporzionato.
- Il controllo dei binari cerca i metadati in chiaro: quelli compressi dentro
  un PDF non si vedono.

### Per l'utente

- Secret della chiave di firma Android nella repo pubblica (vedi resoconto):
  senza, l'«ultima-build» per Android usa una chiave di prova e una versione
  `v*` non si pubblica.
- Attivare la segnalazione privata delle vulnerabilità (Settings → Security)
  perché il link di `SECURITY.md` funzioni.
- Provare «Importa da Drive» dal telefono e dal PC dopo la pubblicazione del
  sito (policy nuova del selettore).

## Giro 3 — App e codice nativo

26/10/2026, dopo i commit 2117650e e f8880f97 (giro di verifica). Test:
`app/test/sicurezza_g3_app_test.dart` (Kotlin compilato a parte).

Controllati: avvio della registrazione dal widget «Registra lezione» (rotta
`registra:avvia` con il codice segreto, tutte le strade da cui una rotta
arriva all'app su Android), ricevitore dei comandi della notifica e dei
widget, ricevitori dei pacchetti registrati a runtime, allarmi e
`PendingIntent` dei widget; finestra di Windows (canale `finestra`,
proprietà `UniNotes.Chiusura`, attesa della copia precedente, copia
dell'ultima immagine, traccia dei tempi, modalità di prova); migrazione del
portachiavi; controllo delle impronte dei download; «Apri in OneNote».

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| Android: la rotta `registra:avvia` (avvio del microfono) era protetta dal codice segreto solo sulla strada dei widget. flutter_local_notifications legge il «payload» di una notifica da qualsiasi intent con la sua azione arrivato a MainActivity, che è esportata (icona dell'app): un'altra app installata poteva far partire la registrazione senza il codice (notifica e indicatore del microfono visibili, app subito in background) | medio | Il tocco su una notifica non avvia mai il microfono: `registra:avvia` diventa `registra` (`RemindersService.notificationRoute`); nessuna notifica dell'app usa quella rotta | test gruppo 1 (rosso prima della correzione) |
| Android: riaprendo UniNotes dalle app recenti dopo che il sistema aveva chiuso il processo, l'attività riceve di nuovo l'intent del tocco sul widget (con il codice giusto): la registrazione ripartiva da sola | medio | Con un intent riaperto dalle app recenti (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`) o un'attività ricreata (`savedInstanceState`) la rotta diventa `registra` (`WidgetSupport.routeOf`, parametro `fresh`) | test gruppo 1 (controllo sul sorgente), Kotlin compilato |
| Android 7–12: il ricevitore dei pulsanti di flutter_foreground_task è registrato senza `RECEIVER_NOT_EXPORTED` (esiste da Android 13) e controlla solo il pacchetto scritto nell'intent: un'altra app poteva mettere in pausa, salvare o eliminare (in «Eliminati di recente», senza il doppio tocco del widget) la registrazione in corso | basso | Dalla porta dei dati del servizio passano solo gli eventi del servizio e i pulsanti della notifica di riserva quando è davvero mostrata; «Elimina» solo dal canale nativo (ricevitore non esportato, doppio tocco) (`packageCommandAllowed`) | test gruppo 2 |

### Falsi allarmi (controllati, nessuna correzione)

- **Codice segreto dei widget**: 128 bit da `SecureRandom`, nelle
  preferenze private dell'app (escluse da backup e trasferimento),
  confrontato in tempo costante. Un'altra app non può leggere gli extra di
  una `PendingIntent` (serve un permesso di sistema) né crearne una uguale a
  nome dell'app; le `PendingIntent` sono immutabili, quindi chi le usa non
  può cambiarle. Il launcher (scelto dallo studente come schermata Home) o
  un'app a cui lo studente permette di ospitare widget può «toccare» il
  widget come farebbe lo studente: è il funzionamento dei widget di
  Android, e la registrazione resta visibile (notifica, indicatore del
  microfono). Ruotare il codice non cambierebbe questo.
- **Ricevitore della notifica e dei widget** (`RecordingCommandReceiver`):
  dichiarato nel manifest non esportato, accetta solo comandi noti; nessun
  ricevitore registrato a runtime dal codice dell'app. Gli allarmi dei
  widget sono non urgenti, con `PendingIntent` immutabili ed esplicite.
- **Dati dei widget sulla schermata Home**: nome delle prove e del corso in
  registrazione, come già dichiarato; nessun voto o testo degli appunti.
- **Windows, attesa della copia precedente**: un processo che tiene aperto il
  mutex senza finestra ritarda l'avvio di al massimo 15 secondi, poi l'app
  parte; bloccarla del tutto richiede un programma dell'utente stesso (che
  potrebbe comunque chiuderla). Il canale `finestra` accetta solo `uscita`
  e `nascosta` dall'app.
- **Ultima immagine della finestra**: solo in memoria (bitmap GDI), tolta
  dopo il ridisegno e alla chiusura; nulla su disco.
- **Traccia `UNINOTES_TRACCIA_FINESTRA`**: scritta solo se la variabile
  indica un file; contiene tempi, numero del processo e nomi degli eventi
  della finestra, nessun dato dell'utente.
- **Modalità di prova** (`UNINOTES_CARTELLA_PROVA`): costante di
  compilazione (`String.fromEnvironment`), non leggibile da variabili
  d'ambiente o argomenti; nessuna build automatica la imposta.
- **Download** (whisper.cpp, ffmpeg, modelli): l'impronta si controlla sul
  file completo `.part`, anche dopo una ripresa, prima di rinominarlo; un
  file già presente è uno scaricato e controllato prima (o di una versione
  precedente nella cartella dell'app, che solo l'utente può scrivere).
- **Migrazione del portachiavi**: ripetibile senza danni (riscrive lo stesso
  valore); il limite di 3 secondi non la interrompe, che finisce in
  background. Un rinnovo del token nello stesso istante potrebbe al massimo
  riportare il token precedente, che i due servizi accettano ancora.
- **«Apri in OneNote»**: solo `onenote:https://…` senza spazi; il ripiego
  nel browser passa dal controllo dei link.

### Resti e cose da valutare nei giri successivi

- FileProvider di open_filex (`root-path`) e opzioni più restrittive per il
  lettore multimediale: invariati, da provare su un dispositivo vero (passi
  nel giro 2). Il controllo dei file prima del lettore resta un controllo
  sull'inizio del file: le opzioni del lettore sarebbero la seconda difesa.
- `ExclusionFilter.isSafePattern`, `IncomingShare.kt`, percorsi di
  `data_sync.dart` e `gunzipLimited` non sono cambiati dal giro 2 e qui
  non sono stati ricontrollati a fondo.

### Per l'utente

Nessuna azione esterna. Da provare sul telefono (Android 12 e 14): avvio
dal widget «Registra lezione», poi app chiusa dal sistema e riaperta dalle
app recenti (deve aprire il registratore senza registrare); pulsanti della
notifica della registrazione e del widget (Pausa, Salva, Elimina con doppio
tocco); tocco sulle notifiche delle prove.

## Giro 3 — Repository, build e resti

26/10/2026, dopo i commit 2117650e e f8880f97 (giro di verifica). Test:
`app/test/sicurezza_g3_repo_test.dart` (controlli statici; quelli sui file
della sola repo privata si saltano nella copia pubblica). Prova del controllo
della copia pubblica con una copia finta con 11 falle note (PDF con XMP e
flusso di oggetti compressi, `.gz`, foglio Office con autore e cartella,
percorsi personali, token): tutte trovate, nessun falso allarme sui casi
ammessi.

Ricontrollati: esportazione e controllo della copia pubblica (tempi e
blocchi), workflow (espressioni nei comandi, Inno Setup, firma Android),
Content-Security-Policy del selettore di Google Drive dopo l'esportazione,
filtro degli indirizzi email del database, `SECURITY.md`, configurazione di
Dependabot, esito delle ultime esecuzioni dei workflow della repo pubblica.

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| Esportazione della copia pubblica ferma per ore a estrazione finita: `git archive` scriveva l'archivio in una pipe letta da `tarfile` e i due processi sono rimasti ad aspettarsi (git sull'ultimo blocco, Python in attesa della fine di git). Chi lanciava l'esportazione con una pipe dopo lo script (`… \| tail`) avrebbe pubblicato la copia anche dopo un errore, perché conta il codice d'uscita dell'ultimo comando | medio | L'archivio va in un file temporaneo (`git archive -o`) con un limite di tempo e si estrae da lì; git che fallisce o si blocca dà un errore. Codice d'uscita 1 anche per i riferimenti a file privati rimasti (prima solo stampati); il codice d'uscita è descritto nello script, da usare senza pipe | test «git archive in un file», «codice d'uscita 1»; esportazione completa in una cartella di prova: 66 s |
| Controllo della copia pubblica lento (55 s solo il controllo, quasi tutto nelle espressioni sui circa 2 GB del database) | basso | Ogni file letto una volta e controllato sui byte (niente decodifica, niente seconda lettura dei binari), espressioni senza `\b` iniziale, indirizzi email cercati dalla «@», numeri di riga contati una volta, file controllati in parallelo: 7,5 s, stessi risultati | test «controllo veloce»; confronto prima/dopo sulla copia pubblica |
| Metadati compressi dei PDF non controllati (XMP, autore nei flussi di oggetti) | basso | Flussi FlateDecode decompressi con zlib (limite per flusso e per file), contenuto dei `.gz`; autore di PDF, XMP, Office e OpenDocument ammesso solo vuoto, «UniNotes» o «Simo-Magnus» | test «metadati compressi dei PDF»; copia finta |
| Percorsi con il nome dell'utente del computer dello sviluppatore nella copia pubblica (già pubblicati): la cartella di lavoro predefinita di tre adattatori dei semestri e la cartella del file salvata da Excel in due fogli di prova | basso | Adattatori: cartella dalla variabile `SEMESTRI_SP` o da un file locale escluso dal repository (`tools/db_builder/cartella_lavoro.txt`), altrimenti la cartella temporanea. Fogli di prova senza il percorso (`absPath`). Il controllo della copia blocca un percorso `Users`/`home` con un nome non generico (nel database solo avviso: link copiati dalle pagine degli atenei) | test «nessun percorso con il nome dell'utente», «fogli di prova»; controllo della copia |
| Inno Setup scaricato in CI con Chocolatey: il pacchetto contiene l'installatore e non ne controlla l'impronta (scritta solo nel suo file di verifica) | basso | Installatore ufficiale della versione fissa dalla release di jrsoftware su GitHub, SHA-256 controllato prima di avviarlo (stesso valore pubblicato da GitHub per l'allegato e dal file di verifica del pacchetto) | test «Inno Setup» |
| Workflow del database: numero dello shard e tipo di evento ancora scritti nel testo dei comandi | basso (valori interni) | Variabili d'ambiente del passo, come gli altri valori | test «database: valori interni» |
| Controllo degli indirizzi email del database (`togli_email.py --verifica`) limitato a corsi, moduli e file per corso | basso | Anche sessioni, argomenti e file della cartella (il controllo della copia li vedeva già) | test «controllo del database» |

### Falsi allarmi (controllati, nessuna correzione)

- **Firma Android**: i nomi dei quattro secret coincidono nel controllo e
  nella scrittura della chiave; con un tag `v*` senza secret il passo esce
  con errore (e la release non parte, dipende dal job Android), un push
  normale prosegue con la chiave di prova e lo dichiara. I filtri sui
  percorsi non valgono per i tag.
- **Selettore di Google Drive**: l'esportazione lascia il file con gli a capo
  LF (attributo `eol=lf`, mentre gli altri file escono con CRLF per
  l'impostazione di git del PC) e la repo pubblica salva LF; l'impronta dello
  script coincide nel file del repository, nella copia esportata e nella
  cartella pubblica. Le altre pagine usano `'unsafe-inline'` (nessun dato
  preso dall'indirizzo finisce nel codice).
- **Filtro degli indirizzi email**: nessun dominio istituzionale tolto per
  errore (sono stati tolti solo indirizzi Gmail, Libero e Tiscali); il filtro
  lavora su tutti i campi dei file, anche quelli nuovi; nei file pubblici
  del database restano solo domini di atenei, ospedali ed editori.
- **`SECURITY.md`**: link corretti, unico indirizzo quello pubblico
  dell'assistenza.
- **Dependabot**: è configurato solo nella repo privata, da cui vengono le
  modifiche esportate: le sue pull request si uniscono lì e arrivano alla
  pubblica con l'esportazione. Nella pubblica gli avvisi funzionano senza la
  configurazione.
- **Ultime esecuzioni della repo pubblica** (commit 49f94255): «App» e
  «Pagina di download» riuscite; «Test trascrizione» fallita nel controllo
  dei link dei modelli (il filtro dei silenzi è in un'altra repo di Hugging
  Face), già corretto nel giro 2 e non ancora pubblicato; nessun errore dovuto
  alle modifiche di sicurezza.
- **Espressioni `${{ }}` rimaste nei comandi del workflow dell'app**: numero
  dell'esecuzione e versione calcolata dal job di test (valori interni).

### Resti e cose da valutare nei giri successivi

- Database: una decina di link copiati dalle pagine degli atenei puntano a
  file sul PC di chi ha scritto la pagina e ne contengono il nome utente
  (avvisi del controllo della copia); si potrebbero togliere nella build.
- La cronologia della repo pubblica contiene ancora i percorsi tolti in
  questo giro (non sfruttabili; riscriverla non è proporzionato).
- `togli_email.py --verifica` impiega più di un minuto (espressione con
  ricerca all'indietro su tutto il testo): stessa tecnica del controllo della
  copia se serve più veloce.

### Per l'utente

- Esportare la copia pubblica solo controllando il codice d'uscita dello
  script (0 = pronta), senza pipe dopo il comando.
- Nella repo pubblica tenere gli avvisi di Dependabot, non gli aggiornamenti
  automatici (le loro pull request verrebbero sovrascritte dall'esportazione).

## Giro 4 — App

26/10/2026, dopo il commit f633a4d6 (giro di conferma, con prove che
tentano davvero l'aggiramento). Test: `app/test/sicurezza_g4_app_test.dart`;
`IncomingShare.cleanName` provato anche sulla JVM (Kotlin compilato con
`android.jar`).

Controllati: tutte le azioni e i payload che l'app accetta da un tocco su
una notifica (recensione, sostegno, «Com'è andata?», prove, sezioni,
registratore, Focus, anni precedenti) e da dove possono arrivare su ogni
sistema; codice dei widget e rotta `registra:avvia` dopo il giro 3;
`ExclusionFilter.isSafePattern` con i casi noti di backtracking
catastrofico misurati su testi di 10.000 caratteri; `MediaGuard` con
scalette travestite (BOM UTF-8/16/32, spazi iniziali, `.m3u8` rinominati,
intestazioni finte davanti) e le opzioni di mpv/FFmpeg in media_kit 1.2.6;
nomi dei file condivisi (`IncomingShare.kt`, `IncomingFiles.parse`),
percorsi degli allegati nei registri della sincronizzazione e
`gunzipLimited`.

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| Android: le azioni delle notifiche che cambiano dati («Più tardi», «Non chiedere più», «Recensisci», «Dona», «Non ricordarmelo per questa prova») si accettavano da qualsiasi intent con l'azione di flutter_local_notifications arrivato a MainActivity (esportata): un'altra app installata poteva spegnere le richieste di recensione e sostegno o i promemoria dell'esito di qualsiasi prova (gli id sono numeri in sequenza) | basso | Le notifiche di recensione, sostegno ed esito partono con un codice casuale di 128 bit nel payload (`RemindersService.signedPayload`, impostazione `notif_code`, mai nei backup né sincronizzata); le azioni che cambiano dati valgono solo con quel codice (confronto in tempo costante), altrimenti il tocco apre al massimo una schermata. Vale su ogni sistema e anche per i pulsanti premuti ad app chiusa | test gruppo 1 (14 prove rosse senza il controllo) |
| Filtri delle esclusioni: espressioni ammesse da `isSafePattern` (due quantificatori, o tre ancorati) costano fino al cubo della lunghezza del testo: su 10.000 caratteri da 0,7 s a circa un minuto ciascuna (`.*a.*b`, `^.*.*.*x`, `[a-z]*[a-z]*!`), e gruppi con alternative in sequenza moltiplicano i percorsi (`.*(a\|a\|a\|a)(a\|a\|a\|a).*x`). Un nome lunghissimo in un data pack o in un backup bloccava l'app | basso | Testi confrontati sui primi 150 caratteri (`maxTextLength`; i nomi degli insegnamenti sono più corti), al massimo 2 percorsi di alternative con due o più quantificatori (30 senza), al massimo 12 filtri usati come espressioni (gli altri come testo) | test gruppo 2: ogni espressione ammessa sotto i 50 ms su 10.000 caratteri (misurato: al massimo pochi ms) |
| Lettore multimediale: una scaletta di testo in UTF-16 o UTF-32 con il BOM superava `MediaGuard` (i byte zero dei caratteri sembrano un'intestazione binaria), e mpv può convertire questi testi e leggerli come scaletta | basso | Testo riconosciuto anche in UTF-16 e UTF-32 con il BOM; in più il lettore delle registrazioni e dei documenti (`MediaGuard.newPlayer`) ha `access-references=no` e `load-unsafe-playlists=no` (mpv non segue i riferimenti dei file, scalette comprese) e FFmpeg con il solo protocollo `file` | test gruppo 3 (BOM rossi prima); suoni WAV veri dell'app e intestazioni di M4A, MP4, MP3, OGG, FLAC e WebM ancora apribili |

Corretto anche, senza essere una falla: il test «Whisper: Scarica due volte»
(`crash_r2_async_test.dart`) aspettava un numero fisso di giri (120) per lo
stato dei modelli, che si legge con un centinaio di operazioni sui file in
fila (circa 92 giri a PC scarico): con il PC carico la sezione dei modelli
non c'era ancora. Ora aspetta la sezione.

### Falsi allarmi (controllati, nessuna correzione)

- **Pulsanti delle notifiche ad app chiusa** (Android): passano dal
  ricevitore non esportato di flutter_local_notifications; nessuna altra app
  può mandarli. Gli altri tocchi aprono solo una schermata; `registra:avvia`
  da una notifica resta `registra`, anche con un codice nel payload.
- **iPhone, iPad, Mac e Windows**: i tocchi sulle notifiche arrivano solo
  dal sistema (su Windows un programma dell'utente stesso potrebbe già fare
  ogni cosa che fa l'app).
- **Codice dei widget** (giro 3): 128 bit da `SecureRandom`, confronto in
  tempo costante, rotta ridotta a `registra` dalle app recenti e
  nell'attività ricreata: invariato.
- **Intestazione binaria finta seguita da una scaletta**: mpv e FFmpeg
  riconoscono le scalette solo all'inizio del file (dopo BOM e spazi);
  con byte binari davanti il file si apre come audio o video o non si apre.
  Le opzioni nuove del lettore coprono comunque i riferimenti.
- **Opzioni del lettore e file veri**: il file aperto lo legge mpv con il
  suo accesso ai file, quindi `protocol_whitelist=[file]` di FFmpeg riguarda
  solo i file indicati dentro un altro; le registrazioni (`.m4a`, `.wav`,
  `.mp3`) e i video locali non hanno riferimenti. I suoni dell'app usano un
  altro lettore (asset dell'app).
- **«Condividi → UniNotes» e «Apri con»**: nomi con `/`, `\`, `..`,
  `%2e%2e`, caratteri di controllo e nomi riservati di Windows restano nella
  cartella della cache (solo l'ultimo pezzo del nome, prefisso con l'ora);
  `%2F` già decodificato da `Uri` si toglie con il resto del percorso;
  autorità con «@», porta o maiuscole non arrivano ai fornitori dell'app
  (Android li cerca con lo stesso nome); solo `content://`. In Dart il nome
  diventa un nome valido su ogni sistema (`NotesStore.safeName`, nomi
  riservati su Windows) e la sincronizzazione delle cartelle rifiuta quelli
  riservati arrivati dal cloud.
- **Percorsi degli allegati nei registri**: relativi con `..` o `\`, unità
  (`C:`), UNC, `file:`, assoluti fuori dalla cartella degli appunti o con
  `..` dentro: diventano vuoti; quelli codificati (`%2e%2e`) restano nomi di
  cartella dentro gli appunti. I collegamenti simbolici non arrivano dalla
  sincronizzazione (OneDrive e Google Drive non li portano).
- **`gunzipLimited`**: bomba, membri concatenati, gzip dentro gzip e file
  troncati restano entro il limite o si ignorano senza eccezioni.

### Resti e cose da valutare nei giri successivi

- FileProvider di open_filex (`root-path`): invariato, da provare su un
  telefono (passi nel giro 2).
- Le notifiche di recensione, sostegno ed esito già mostrate prima
  dell'aggiornamento non hanno il codice: i loro pulsanti aprono solo
  l'app (quelle future si ripianificano con il codice all'avvio).

### Per l'utente

Nessuna azione esterna. Da provare su un dispositivo vero: pulsanti
«Più tardi», «Non chiedere più», «Recensisci» e «Non ricordarmelo per questa
prova» su Android (app aperta e chiusa), iPhone e Windows dopo
l'aggiornamento; riproduzione di una registrazione `.m4a` e `.wav` e di un
video `.mp4` nel lettore su Windows, Android, iPhone e Mac.

## Giro 4 — Database e strumenti

26/10/2026, dopo il commit f633a4d6. Test: `app/test/sicurezza_g4_repo_test.dart`
(controlli statici e prove che eseguono Python, saltate se `python` non c'è; i
controlli sui file della sola repo privata si saltano nella copia pubblica).
Script: `python tools/db_builder/togli_email.py --verifica` (ora controlla anche
i link a file locali e i parametri di accesso) e il controllo della copia
pubblica con `--verifica`.

Cercati nel database pubblico (corsi, moduli, sessioni, argomenti: circa 3,4
milioni di testi diversi): link a file del computer di chi ha scritto la pagina,
numeri di cellulare, codici fiscali, matricole, indirizzi di casa, elenchi di
studenti (graduatorie, esiti), parametri di accesso e di sessione nei link
(`token`, `sid`, `jsessionid`, `pwd`, `key`, `sig`, `code`…), password scritte nei
testi, link a Google Drive, OneDrive, Dropbox e simili, inviti a gruppi
(WhatsApp, Telegram, Discord) e a riunioni, profili social, IBAN, carte,
chiavi API, indirizzi IP.

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| Link a file del computer di chi ha scritto la pagina dell'ateneo (`file:///…`) copiati nei testi dei libri: 12 testi diversi in 9 atenei, tre con il nome utente di una persona nel percorso (segnalati dal controllo della copia come avvisi, già nella copia pubblica) | basso | `pulizia.senza_percorsi_locali` nella build (`build_db.py`, `dividi_per_corso.py`, unione dei moduli) e in `togli_email.py` (file esistenti corretti, impronte di `meta.json` e file per corso rigenerati, `sync_assets.py` eseguito): il link diventa «[link non disponibile]» e il resto della citazione resta. Riconosce `file:` (anche maiuscolo), percorsi di disco con `Users` o `Documents and Settings`, percorsi con spazi prima di `%20`; non tocca i link web | test gruppo «link a file locali» (prove sul filtro e sul database) |
| Controllo della copia pubblica: i percorsi con il nome dell'utente nel database erano solo un avviso | basso | Ora bloccano la pubblicazione (codice d'uscita 1), come ogni link `file:` nel database | test gruppo «controllo della copia pubblica»; esportazione di prova dell'ultimo commit: bloccata con i 70 problemi attesi |
| Parametri di accesso nei link copiati dalle pagine degli atenei: il token (JWT, scaduto il 18/08/2025) del proxy di una biblioteca (Bologna), un `jsessionid` (Parthenope), due identificativi di sessione EBSCO con `bdata` (Politecnico di Milano, Pisa), il codice di una riunione Zoom `pwd` (Bologna) | basso | `pulizia.senza_parametri_di_accesso` (stesse tre posizioni della build): toglie solo il parametro, il collegamento resta. Nomi di sessione e accesso con valore da 16 caratteri, `pwd`, `password`, `passwd` da 4; `sid=12`, `code=`, `key=`, `sig=`, `auth=` e simili restano. Nel controllo della copia pubblica un parametro così nel database blocca | test gruppo «parametri di accesso e di sessione» |
| Password scritte nei testi: la parola d'ordine di un video riservato (Bologna), la chiave di iscrizione al corso su Moodle (Torino) e un'altra password in un elenco di argomenti (Genova) | basso | Stesso filtro: «Password: …» (solo con i due punti) diventa «Password: [rimossa]», una voce di `argomenti` che era solo una password si toglie | test gruppo «parametri di accesso e di sessione» |
| `togli_email.py --verifica` lento (38 s a file in cache, 95 s a freddo) | basso | Stessa tecnica del controllo della copia: ogni file letto una volta come byte, ricerca partendo da «@», dai prefissi dei percorsi e da `nome=` (testo in minuscolo, `bytes.find`), 8 processi: 9 s con in più i controlli nuovi (6 s solo email e percorsi) | test «controllo veloce del database» (prova su una cartella finta: trova gli indirizzi e i link, non i domini istituzionali, non ripete i dati) |

Per misurare: `time python tools/db_builder/togli_email.py --verifica` (database
pulito: 9 s, prima 38 s con i soli indirizzi email).

### Falsi allarmi (controllati, nessuna correzione)

- **Numeri di cellulare**: nessuno. Le 444 corrispondenze di un'espressione
  larga (3xx seguito da 6 o 7 cifre) erano ISBN, indirizzi di riunioni Zoom,
  identificativi (GUID) nei link; con prefisso +39/0039 o la parola
  «tel/cell/whatsapp» vicino: zero.
- **Codici fiscali, IBAN, carte, chiavi API, indirizzi IP privati**: zero veri
  (due falsi allarmi: un DOI e un GUID).
- **Matricole**: 1.919 testi con `MATRICOLA=` sono l'identificativo del docente
  nell'indirizzo pubblico della pagina dell'ateneo (Università della Campania),
  usato come fonte del programma; nessuna matricola di studenti.
- **Indirizzi di casa**: sei testi sono sedi di corsi e indirizzi di case
  editrici.
- **Elenchi di studenti**: le liste di nomi sono gli autori delle bibliografie;
  «graduatoria» compare nei requisiti di ammissione dei corsi.
- **Link a Google Drive, OneDrive, fogli pubblicati sul web**: 53 testi in 18 file,
  condivisi dai docenti per gli studenti e scritti nelle
  pagine degli atenei (dispense, orari): informazione didattica, restano.
- **Parametri `sig=` (Google Libri), `key=` (catalogo di Milano), `code=` (codice
  insegnamento a Roma La Sapienza), `auth=LOCAL` (catalogo di Siena)**: non sono
  credenziali.
- **Credenziali dell'immagine di laboratorio** del corso di Roma Tor Vergata:
  utente e password predefiniti di una macchina virtuale locale, parte
  dell'istruzione.
- **Inviti e riunioni**: nessun gruppo WhatsApp, Telegram o Discord; i link di
  riunione Zoom (senza il codice), Meet, Teams e Webex sono scritti dagli atenei
  nelle note degli esami (vedi i resti).

### Resti e cose da valutare nei giri successivi

- Due voci di `argomenti` in `moduli/unito.json` sono solo l'indirizzo della
  stanza personale Webex di un docente (non sono argomenti); un indirizzo Meet
  nel luogo di un esame (Cassino) e un link a un team di Teams in due libri
  (Napoli): inviti a riunioni pubblicati dagli atenei, non credenziali; si
  potrebbero togliere nella build.
- Gli input della build (`database/contrib/auto`, fuori dal repository) hanno
  ancora i testi originali; la build li filtra, quindi i file pubblici sono
  puliti.
- `argomenti.py` e il file delle sessioni non applicano i filtri (nessuna
  occorrenza, ma il controllo del database e quello della copia pubblica li
  guardano).
- La cronologia della repo pubblica contiene ancora le versioni precedenti dei
  file (dati già pubblicati dagli atenei, token scaduto): riscriverla non è
  proporzionato.

### Per l'utente

- Dopo il commit, esportare la copia pubblica (senza pipe, controllando il
  codice d'uscita): il controllo ora blocca con il database vecchio e passa
  con quello corretto.
- Per rifare la raccolta del database non serve altro: la build applica già i
  filtri nuovi.

## Giro 5 — Conferma finale

26/10/2026, dopo il commit 3ac0d823 (un solo controllo, con prove di
aggiramento vere). Test: `app/test/sicurezza_g5_test.dart`.

Prima la build automatica su Linux, ferma in due test che sul PC passavano;
poi ricontrollate a occhi nuovi le correzioni del giro 4 (codice delle
notifiche, limite dei testi dei filtri delle esclusioni, opzioni del lettore
multimediale, nomi dei file condivisi) e guardate a fondo le parti che nessun
giro aveva preso insieme: indirizzi e collegamenti verso l'app su tutti i
sistemi, condivisione verso altre app e file temporanei, PDF esportati,
appunti di sistema, lettore dello schermo nelle sezioni nascoste, notifiche e
Live Activity sulla schermata di blocco.

| Falla | Rischio | Correzione | Verifica |
|---|---|---|---|
| Build su Linux, test «script aperti con il programma predefinito»: il test usava un percorso di Windows (`C:\…`) anche simulando il Mac, e su Linux quel percorso è relativo. Una prima correzione nell'app (percorso completo «per Windows o per Unix») avrebbe riaperto un difetto già corretto: su Android, Mac e Linux un libro con un percorso del PC arrivato da un backup passava il controllo e «Apri» apriva la cartella di lavoro dell'app | basso (non pubblicata) | Il controllo resta con le regole del sistema su cui gira l'app, che è quello che apre il file (`ExternalLauncher.pathContext`, sostituibile nelle prove); il test simula le regole del sistema che prova | test gruppo 1 (`C:\…`, `D:x`, `C:relativo`, `\?\`, `\.\`, `//server` su ognuno dei due sistemi) e `sicurezza_g2_app_test.dart` gruppo 12 |
| Build su Linux, prova a caso del registratore: «Indietro» arrivato quando la pagina in cima era stata appena aperta e non ancora disegnata (una pagina aperta dopo un fotogramma, come il registratore aperto da un widget o da una notifica, resta così fino al fotogramma dopo). In debug l'asserzione di Flutter `scope != null` (`ModalRoute.willPop`) ferma l'app; nella build pubblicata la pagina si chiudeva senza sentire i suoi `PopScope` | basso | `BackGuard` (installato prima di `runApp`, anche nella prova a caso): con la pagina in cima non ancora costruita l'«Indietro» passa al fotogramma successivo (al massimo 3 volte di fila) | test gruppo 2: lo stesso errore senza la guardia; con la guardia la pagina si chiude al fotogramma dopo e un `PopScope` che non vuole chiudersi viene rispettato |
| Filtri delle esclusioni (giro 4): i testi si confrontavano solo sui primi 150 caratteri anche con i filtri delle Impostazioni (`inglese`, `\bOFA\b`, `facoltativ`…), che non hanno quantificatori e costano poco: un insegnamento con il nome lungo (nel database circa 190 nomi su 270.000 superano i 150 caratteri) e «Inglese» in fondo non era più escluso | basso (funzione) | Filtri senza quantificatori (testo semplice o espressioni come quelle delle Impostazioni) su tutto il testo, fino a 2.000 caratteri; quelli con quantificatori restano sui primi 150 (su 200 il caso peggiore supera già i 70 ms) | test gruppo 3; test del giro 4 sui tempi invariato (sotto i 50 ms) |
| Su Android un'altra app può aprire l'attività principale (esportata) con un indirizzo qualsiasi: Flutter lo passava al Navigator come percorso e, non essendoci percorsi con nome, l'unico effetto era un errore con il testo scelto da quell'app nel registro degli errori (che ha un limite di dimensione e resta sul dispositivo) | basso | `AppLinkGuard` dichiara gestiti tutti gli indirizzi, non solo `uninotes://` (quelli veri li gestisce il codice nativo) | test gruppo 4 |

### Falsi allarmi (controllati, nessuna correzione)

- **Codice delle notifiche** (giro 4): 128 bit da `Random.secure`, nel
  database dell'app, fra le impostazioni mai esportate né ripristinate e
  fuori dall'elenco di quelle sincronizzate; su Android sta solo negli extra
  delle `PendingIntent` (non negli extra della notifica, che le app con
  l'accesso alle notifiche possono leggere) e nelle preferenze private del
  pacchetto delle notifiche. Tocco all'avvio, tocco con l'app aperta e
  pulsanti premuti ad app chiusa passano tutti dallo stesso controllo; senza
  il codice si apre al massimo una schermata (prova, sezione, registratore
  senza avviarlo).
- **Lettore multimediale** (giro 4): l'app passa sempre un percorso locale
  (`Uri.file`, con spazi e accenti codificati), mai un `content://`: i file
  arrivati da altre app sono già copiati nell'app. Il file aperto lo legge
  mpv, quindi l'elenco dei protocolli di FFmpeg non lo riguarda (da provare
  comunque sui dispositivi, come scritto nel giro 4).
- **Nomi dei file condivisi** (giro 4): un nome con caratteri di direzione del
  testo (es. `U+202E`) può sembrare un PDF, ma «Apri» guarda i caratteri veri
  e blocca i programmi.
- **Collegamenti `uninotes://` su iPhone, iPad e Mac**: una pagina web o
  un'altra app può aprirli, ma portano solo a una schermata; l'avvio della
  registrazione dal widget c'è solo su Android, con il codice segreto; l'esito
  del comando Focus cambia solo il messaggio mostrato. Windows: avviata da un
  collegamento l'app parte senza argomenti (giro 1).
- **Condivisione verso altre app**: si condividono solo i file scelti
  (appunto, registrazione, trascrizione, file del lettore) con il loro titolo.
  Su Android il pacchetto copia il file nella cache dell'app fino alla
  condivisione successiva; «Elimina tutti i dati» svuota la cache.
- **PDF esportati**: autore «UniNotes», titolo dell'appunto, nessun nome
  utente né percorso.
- **Appunti di sistema**: si scrivono solo su richiesta (Copia, prompt per
  l'AI) e si leggono solo con la finestra della richiesta all'AI aperta.
- **Lettore dello schermo**: le sezioni nascoste sono fuori dall'albero
  dell'accessibilità (`Offstage`).
- **Live Activity e notifiche sulla schermata di blocco**: nome
  dell'insegnamento, tempo e stato della registrazione (indicatore voluto);
  «Pausa» e «Salva» funzionano senza sbloccare come i pulsanti della notifica
  di Android; le Live Activity non sono ancora nel progetto di Xcode.
- **Altri percorsi da un altro sistema** (sincronizzazione, backup, cestino,
  cartelle remote): si controllano con le regole del sistema su cui gira
  l'app o senza dipendere dal sistema (nomi con `/`, `\` e `:` rifiutati), e
  un percorso del PC sul telefono non è mai completo.

### Esito

Nessuna falla vera trovata in questo giro: i difetti corretti sono una
regressione non pubblicata, un caso limite di Flutter, una regressione di
funzione e un irrobustimento. Nessuna azione non voluta possibile per un'app
terza, nessun file o dato manipolato che cambi qualcosa, nessun dato
personale esposto: la caccia si chiude.

### Per l'utente

Nessuna azione esterna. Restano da provare su un dispositivo vero le voci dei
giri precedenti (FileProvider di open_filex, lettore multimediale, pulsanti
delle notifiche); in più «Indietro» subito dopo il tocco sul widget
«Registra lezione» con l'app aperta.
