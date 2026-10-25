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
