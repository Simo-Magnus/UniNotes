# Avvio dell'app ed errori

Come UniNotes si avvia e cosa fa quando qualcosa va storto (codice in
`app/lib/main.dart`, `app/lib/core/database/app_database.dart`,
`app/lib/core/router/error_screens.dart`, `app/lib/core/services/error_log.dart`).

## Avvio

1. Gestione globale degli errori (`installGlobalErrorHandlers`).
2. Controllo dell'installazione e, se servono, le domande sui dati di
   un'installazione precedente.
3. Apertura del database, servizi e preferenze. Se non riesce (database non
   apribile, disco pieno, permessi) compare la schermata «UniNotes non si è
   avviato» con la spiegazione e «Riprova», invece di una finestra vuota.
4. Prima schermata, poi sincronizzazione, promemoria e sessione Focus: un
   servizio che non parte non ferma gli altri.

Su Windows può esserci una sola copia dell'app aperta: avviarla di nuovo
riporta in primo piano la finestra già aperta (anche dall'area di notifica).
Se la finestra non si può creare perché mancano o sono danneggiati i file
dell'app (es. `data\app.so`, `flutter_assets`), compare l'avviso «UniNotes
non si è avviato… Reinstalla UniNotes» invece di una chiusura senza
spiegazioni (`windows/runner/main.cpp`).

Impostazioni native senza le quali il sistema chiude l'app (controllate da
`app/test/crash_r2_nativo_test.dart`): su iOS e macOS le chiavi d'uso di
microfono, riconoscimento vocale, calendario e, su iOS, «Salva immagine/video»
del foglio Condividi (`NSPhotoLibraryAddUsageDescription`); l'identificativo
della sincronizzazione in background fra quelli permessi; su Android il
servizio del registratore di tipo `microphone`, mai riavviato dal sistema
all'accensione, e `android:exported` su ogni componente.

## Database

- Le istruzioni dello schema (tabelle, indici, colonne) si eseguono solo per
  ciò che manca: un database di una versione vecchia, già in parte
  aggiornato o riaperto da una versione precedente dell'app si apre senza
  errori.
- A ogni apertura tabelle, indici e colonne mancanti (database parziale) si
  ricreano, senza toccare i dati.
- L'aggiornamento è provato da ogni versione storica dello schema (1–13, con
  dati realistici: ogni tabella e colonna di oggi, nessuna riga persa,
  identificativi della sincronizzazione unici, seconda apertura identica) e
  da un database di una versione più recente (colonne e tabelle sconosciute
  restano): `test/crash_r2_tempo_test.dart`.
- Un file danneggiato (non è un database SQLite o è corrotto) non si
  elimina: si rinomina in `university_manager.db.danneggiato-<data>` nella
  cartella di supporto dell'app e l'app riparte con un database nuovo,
  avvisando lo studente (i dati si recuperano da un backup esportato o
  dalla sincronizzazione). Errori passeggeri (disco pieno, file bloccato)
  non spostano mai il file.
- Con il disco pieno all'avvio i dati si leggono lo stesso; le scritture
  danno errore finché non si libera spazio.

## Registro degli errori

`errori.log` nella cartella di supporto dell'app (con la copia precedente
`errori.log.1`, al massimo circa 1 MB in tutto): eccezioni non gestite,
errori dei widget, avvio non riuscito. Resta sul dispositivo, non si invia a
nessuno; lo stesso errore ripetuto si annota una volta ogni 10 secondi e al
massimo 300 voci per avvio. «Elimina tutti i dati» (voce del database) lo
cancella insieme alle copie danneggiate del database.

Un widget che non si costruisce mostra «Qualcosa non ha funzionato» con
«Torna indietro» (se c'è una schermata a cui tornare) al posto della
schermata rossa o grigia.

## Operazioni in corso, doppi tocchi e dialoghi

Controllati il 22/10/2026 (test in `app/test/crash_r2_async_test.dart`):

- un pulsante che avvia un'operazione si blocca dal primo tocco, non dal
  fotogramma dopo: due tocchi ravvicinati non salvano due volte (nuovo
  insegnamento, voti dell'anno), non aprono due accessi o due
  sincronizzazioni (pulsanti di Collegamenti e Impostazioni, interruttori di
  notifiche e calendario) e non scaricano due volte lo stesso modello
  (Whisper, Parakeet, ffmpeg); la seconda chiusura di un modulo non toglie
  più la pagina sotto;
- un riquadro d'attesa chiuso con Indietro («Importa da Drive») ferma
  l'attesa come «Annulla» e non chiude, alla fine, la pagina sotto; la
  richiesta all'AI che trova la risposta negli appunti mentre il riquadro
  si sta chiudendo non la salva e non chiude altro;
- una sessione Focus avviata poco dopo l'apertura dell'app aspetta la
  lettura di quella rimasta aperta da una chiusura (che continua, invece di
  essere sovrascritta);
- «Registra» con i dati non leggibili mostra i comandi e il motivo invece
  della rotella infinita, e «Registra» che non parte lo dice; una modifica
  nel dettaglio della prova non salvata (es. disco pieno) lo dice invece di
  sparire;
- sul PC «Esci» chiude l'app anche se l'icona dell'area di notifica non si
  toglie (prima la finestra non si chiudeva più).

## Dati letti da fuori (secondo giro, 22/10/2026)

Test in `app/test/crash_r2_dati_test.dart` e `crash_r2_dati_oauth_test.dart`.

- `asInt` (lettura tollerante di database e JSON) tratta infinito e NaN come
  «assente» invece di lanciare (un REAL infinito in una colonna intera
  rompeva la lettura degli insegnamenti).
- L'ora di una prova non valida («99:99», numeri enormi) vale come giornata
  intera (`Exam.dateTime`), come già nell'agenda.
- Tempi infiniti nei dati accanto alla registrazione e nell'output di
  Whisper non fanno perdere segnalibri, trascrizione e durata.
- Un file `.xopp` senza pagine non lancia più quando si salta a una pagina o
  si riapre alla posizione salvata.
- Evidenziazioni dei PDF: scrittura sicura (file temporaneo e rinomina); un
  file illeggibile (altra versione, scritto a metà) resta in una copia
  `<nome>.danneggiato` prima che il primo salvataggio lo sovrascriva.
- Coda dei pulsanti delle notifiche premuti ad app chiusa: una voce
  rovinata si salta, le altre restano.
- Filtri di esclusione con quantificatori annidati (`(a+)+`, scritti a mano
  nelle versioni con i filtri avanzati, sincronizzati o in un backup): si
  usano come testo semplice, perché le espressioni regolari di Dart tornano
  indietro provando ogni combinazione e su 30 caratteri bloccavano l'app.
- Ritorno dall'accesso nel browser: una richiesta estranea con byte non
  UTF-8 nella query (`%FF`) si scarta con 400 e l'accesso continua.
- Collegamenti `uninotes://…` con l'app aperta (tocco su un widget): Flutter
  li inoltrava al Navigator, che non ha percorsi con nome e lanciava «Could
  not find a generator for route»; `AppLinkGuard`
  (`core/router/app_link_guard.dart`) li dichiara gestiti.

## Disegno, impaginazione e risorse (secondo giro)

La prova a tappeto `app/test/crash_r2_layout_test.dart` apre le schermate
principali e ~45 riquadri e fogli con database vuoto, pieno di casi limite
(CFU zero, infiniti e NaN, nomi lunghissimi, voti e durate fuori scala) e con
migliaia di righe, a 320×568 e 1920×1080, con caratteri ×1 e ×3, e raccoglie
ogni eccezione. Nella suite normale fa poche combinazioni (circa un minuto e
mezzo); con `CRASH_R2_FULL=1` fa tutte (database con 600 insegnamenti, quattro
combinazioni, input da centinaia di migliaia di caratteri), da lanciare a parte.

- Un menù con un valore che non è tra le voci (insegnamento nascosto dal
  filtro di anno o percorso) si rompe: `CourseDropdown` controlla l'elenco
  mostrato, non tutti gli insegnamenti.
- Formule: oltre `kMaxFormulaChars` (3000) restano testo. Il disegno cresce
  più che linearmente (16 000 caratteri: da 4 a 18 secondi di interfaccia
  ferma; 200 000: senza fine).
- Istogramma delle ore: con durate fuori scala (2^40 minuti, dati importati)
  le tacche erano miliardi e l'interfaccia si fermava; il passo ora cresce
  di dieci in dieci.
- Avanzamento di trascrizioni e download: `WhisperProgress.fraction` e i
  lavori in background non passano mai NaN, infiniti o valori fuori 0–1
  (`LinearProgressIndicator`, `floor()`); l'anello di avanzamento ignora NaN.
- Home: gli argomenti di tutti gli insegnamenti si leggono con una sola query
  (`StudyRepository.topicsByCourse`), non una per insegnamento; il conteggio
  dei file degli appunti (`NotesStore.count`) non legge più data e
  dimensione di ogni file.
- Caratteri grandi: elenchi vuoti (`EmptyState`) e foglio «Stato» della prova
  scorrono; menù «Tipo di prova» e «Modalità d'esame» a tutta larghezza;
  cursore «Difficoltà», passo dell'onboarding, intestazione delle card, voto
  nei voti dell'anno e voce «Attività» del cronometro cedono spazio invece di
  uscire dal riquadro.

## Rete e download (terzo giro, 22/10/2026)

Test in `app/test/crash_r3_rete_test.dart` (server HTTP locali su
127.0.0.1: risposte lente, troncate, HTML, 416/206 sbagliati, 429, TLS).

- `FileDownloader` (modelli Whisper e Parakeet, whisper.cpp, ffmpeg): limite
  di attesa senza dati (`networkIdleTimeout`, 60 s) anche per la risposta e
  per ogni pezzo, non solo per il collegamento: una rete caduta senza errore
  non lascia il download appeso. Una pagina HTML al posto del file (Wi‑Fi
  con pagina di accesso) è un errore chiaro e non sovrascrive la parte già
  scaricata. 416 con una dimensione diversa dalla parte e 206 con un
  intervallo diverso da quello chiesto: si riparte da zero invece di
  rinominare o allungare un file sbagliato. Byte ricevuti diversi da quelli
  annunciati: errore (la parte resta per riprendere). Certificato non valido,
  disco pieno, cartella non scrivibile, 429/503 con `Retry-After`: messaggi
  chiari invece di eccezioni grezze. La scrittura aspetta il disco pezzo per
  pezzo (niente dati accumulati in memoria).
- Un solo download per file in tutta l'app: un secondo download dello stesso
  file (doppio tocco, scheda e seconda passata) aspetta il primo e, se è
  riuscito, non riscarica.
- whisper.cpp e ffmpeg (Windows): una sola installazione alla volta (due
  modelli scaricati subito chiedevano entrambi whisper.cpp sullo stesso
  archivio); estrazione in una cartella o in un file temporaneo poi
  rinominato, così un'estrazione interrotta non lascia un programma a metà
  che sembra installato; archivio non valido = errore del download.
- Microsoft Graph e Google Drive: un corpo non JSON in una risposta 2xx è un
  errore di rete (stato 0, la sincronizzazione si ferma e riprova), non una
  FormatException per ogni file. Con 429/503 (e 403 «rate limit» di Drive) la
  sincronizzazione si ferma al primo file invece di riprovare con tutti.
- Accesso OAuth: una risposta del server dei token con byte non UTF-8 non è
  più una FormatException.
- Catalogo: certificato non valido = «senza rete» (si usa la copia salvata);
  i download «recenti» (15 minuti) si contano con un orologio monotono, non
  con quello del sistema che può essere spostato indietro.

## Navigazione e stato nel tempo (terzo giro, 22/10/2026)

Test in `app/test/crash_r3_navigazione_test.dart`.

- Chiusura dopo un'attesa: `popIfCurrent` (`core/router/safe_pop.dart`)
  chiude la pagina o il riquadro solo se è in cima; se nel frattempo se n'è
  aperta un'altra sopra (notifica, widget) toglie solo la propria; se si sta
  già chiudendo (Indietro, gesto «indietro», Esc durante l'attesa) non fa
  nulla. Prima `if (mounted) Navigator.pop(context)` toglieva la pagina sotto
  (la pagina in uscita è ancora montata durante l'animazione) o chiudeva la
  pagina aperta dalla notifica al posto del modulo. Usato da nuovo
  insegnamento, voti dell'anno, modulo della prova, modulo del libro, nota,
  registratore e registrazione, dettaglio di prova e insegnamento dopo
  «Elimina», «Cambia corso», fine della sessione Focus. Il registratore non fa
  più `pushReplacement` da una pagina che non è in cima (sostituiva quella
  sotto); il modulo della prova non propone avvisi e calendario se si sta già
  chiudendo; il riquadro «Elimino i dati…» si chiude anche con una pagina
  aperta sopra (prima restava per sempre).
- Sessione Focus: la schermata conta come aperta dalla richiesta, non dal
  fotogramma dopo: due richieste ravvicinate (riquadro e notifica) ne aprono
  una sola.
- Giorno che cambia con l'app aperta o ripresa dopo giorni (`DayWatcher`):
  a mezzanotte (controllo almeno ogni ora, per i PC in sospensione) e a ogni
  ripresa le schermate rileggono i dati («oggi», «domani», conti alla
  rovescia) e, se è iniziato un nuovo anno accademico, arriva la domanda
  come all'avvio (una sola alla volta).
- Stato degli insegnamenti: una scrittura non riuscita in
  `syncCourseStatuses` (disco pieno, sola lettura) va nel registro e non
  impedisce più la lettura: Home, Insegnamenti, Studio, Libri, Esami non
  mostrano più solo «Errore».
- Token rifiutato (401) che l'app crede ancora valido (orologio spostato
  indietro, accesso revocato): OneDrive e Google Drive lo dimenticano e
  ripetono la richiesta una volta con uno nuovo, invece di fallire fino alla
  scadenza segnata.
- Calendario: un segno di `syscal_writers` con l'orario nel futuro vale come
  scritto adesso (vedi `docs/notifiche.md`).

## Memoria, sessioni lunghe e filo dell'interfaccia (terzo giro, 24/10/2026)

Prove in `app/test/crash_r3_memoria_test.dart` (veloci nella suite; con
`CRASH_R3_LONG=1` le dimensioni vere e le misure: 4 ore di lezione = 2600
frasi, 5000 paragrafi, 2000 file).

- Trascrizione dal vivo di ore: testo in lettura a blocchi di 40 frasi e,
  in modifica, nel campo solo il blocco toccato (vedi `docs/registratore.md`,
  «Modificare il testo mentre si registra»). Per ogni parola: 115 → 25 ms;
  per tasto in modifica: 145 → 27 ms (PC, 2600 frasi).
- Controllo ortografico in lettura (`ReadingSpellChecker`): a 4000 testi la
  memoria si svuotava tutta; con più frasi o blocchi di così sullo schermo
  (lezioni di oltre ~6 ore, documenti lunghi) si ricontrollava tutto senza
  fine, ridisegnando ogni 25 controlli, e durante la registrazione ogni
  parola confermata aggiungeva una versione nuova della frase in corso. Ora
  escono per prime le versioni non più mostrate e mai i testi usati
  nell'ultimo disegno. Nel campo di modifica (`SentenceSpellCheck`) il limite
  cresce con il numero di frasi.
- Documenti lunghi (`MarkdownLiteView`: trascrizioni, riassunti, note):
  oltre 300 blocchi si mostrano in una lista pigra; prima 5000 paragrafi
  fermavano l'interfaccia ~3,2 s all'apertura e a ogni ridisegno del
  controllo ortografico, ora ~0,4 s. La ricerca porta in vista anche un
  risultato in un blocco non ancora costruito; Ctrl+A seleziona i blocchi
  costruiti. Il testo si analizza una volta per testo, non a ogni disegno.
- Forma d'onda della registrazione: `BytesBuilder(copy: false)` faceva un
  array per ogni livello (10 al secondo): ~7,5 MB in 4 ore invece di 144 KB.
- Ricerca nelle trascrizioni (Registra → lente) e negli appunti del corso:
  il testo in minuscolo si calcola una volta per file, non per ogni lettera
  scritta su tutte le trascrizioni.
- Cartella con migliaia di file (File → cartella): oltre 150 voci lista
  pigra nella card (prima tutte le righe e la dimensione di ogni file
  all'apertura).
- Taglio del WAV con l'originale sparito: il file di destinazione non resta
  aperto (su Windows non si cancellava più).

## Testo, input e accessibilità (terzo giro, 22/10/2026)

- **Coppie surrogate.** Flutter rifiuta ogni stringa con una metà spaiata di
  un carattere fuori dal piano base (emoji, ideogrammi rari) con `string is
  not well-formed UTF-16` appena la disegna: la schermata diventa rossa.
  Nasce da un taglio con `substring` in mezzo a una coppia o da dati letti da
  fuori (un `&#xD800;` in un XML, un `\ud800` in un JSON, un file UTF-16
  troncato). Rimedi in `lib/utils/safe_text.dart`: `safePrefix`, `safeSlice`,
  `cutBefore`/`cutAfter` per tagliare, `wellFormed` e `wellFormedJson` per
  ripulire (la metà spaiata diventa U+FFFD).
- Tagli corretti: frammenti attorno alla parola cercata (`searchSnippet`, ricerca
  negli appunti), paragrafi lunghi, celle e descrizioni del lettore, nomi
  accorciati dei file estratti dal lettore.
- Il lettore ripulisce ogni documento una volta sola, alla consegna
  (`parseDocument`, `findTranscript`, scalette: `lib/features/reader/
  reader_well_formed.dart`). Anche i dati JSON accanto alle registrazioni, i
  segnalibri e le evidenziazioni passano da `wellFormedJson`.
- `findFolded` non cerca una metà di emoji (il campo può passare da lì mentre
  si compone): l'evidenziazione spezzerebbe la coppia.
- **Campi di testo.** «Trova nel testo» (`FindBar`) ha un tetto di 500
  caratteri (`TextLimits.findQuery`): una pagina incollata ripiegava e
  confrontava megabyte a ogni tasto. Le ricerche con `.*+?()[]` non sono
  espressioni regolari (testo semplice) e i filtri scritti dall'utente con
  alternative sovrapposte e quantificatore, come `(a|aa)+`, si usano come
  testo (`ExclusionFilter`).
- Dopo l'apertura della ricerca, fuoco e selezione partono un fotogramma dopo:
  se la schermata si è già chiusa non si toccano più (controller eliminato).
- **Controllo ortografico di Windows e macOS**: gira sul filo
  dell'interfaccia; le righe oltre 20000 caratteri non si controllano e a ogni
  richiesta se ne mandano al massimo 100000 caratteri (le altre al controllo
  dopo; quelle già viste sono in memoria).
- **Lettore di schermo**: le schermate principali si aprono con
  `tester.ensureSemantics()` e nomi ostili (emoji, destra-sinistra, controlli
  bidi, nullo, a capo di Windows, righe enormi) senza asserzioni
  (`test/crash_r3_testo_test.dart`).

## File system e percorsi (terzo giro, 24/10/2026)

Test in `app/test/crash_r3_file_test.dart`.

- **Nomi scelti dall'utente** (`NotesStore.safeName`): su Windows i nomi
  riservati (`CON`, `aux.txt`, `COM1`…) prendono un «_» dopo il nome (la
  sincronizzazione li rifiutava e altri programmi non li cancellano); i punti
  e gli spazi iniziali si tolgono (un file `.nota.md` spariva dagli elenchi e
  una cartella `.eliminati` era il cestino); il taglio a 90 caratteri non
  spezza le emoji e non lascia punti finali. Rinominando una lezione, su
  Windows il nome si accorcia perché il percorso resti sotto i 260 caratteri
  (`fitToPath`); il nome davvero dato ai file arriva agli allegati di Studio.
  Libri (`BookLibrary.uniqueName`), file ricevuti da fuori e file `.ics`
  seguono le stesse regole; le estensioni sono al massimo di 16 caratteri.
- **Cartelle che spariscono o non si leggono**: elenco degli appunti, conteggio,
  Home, cestino e pulizie mostrano quanto hanno letto invece di rompere la
  schermata; un file tolto durante l'elenco (tipo «non trovato») si salta.
  `renameCourse` non lancia mai (il nome nel database è già cambiato). Se la
  cartella degli appunti scelta non si può creare si usa quella predefinita;
  un'unità di rete che non risponde entro 4 secondi vale «non raggiungibile».
  I percorsi esterni di libri e allegati si controllano con
  `fileExistsQuick` (5 secondi) per non fermare la schermata.
- **Copie e scritture**: `copyFileSafely` (via `.part`) per riassunti allegati
  e file ricevuti; `writeStringAtomic`/`writeBytesAtomic` tolgono il `.part`
  se la scrittura fallisce (disco pieno) e sono usate per la trascrizione
  salvata, il PDF esportato e l'«Annulla» del testo dell'AI.
- **Cestino e orologio**: dopo i 30 giorni un elemento si cancella solo se è
  visto scaduto da almeno 3 giorni (`RecycleBin.grace`, annotazione
  `.scaduto` nella sua cartella): un orologio portato avanti per errore e poi
  corretto non svuota più il cestino.
- **Temporanei**: all'avvio si tolgono le cartelle di lavoro (`whisper_*`,
  `parakeet_*`, `uninotes_live_*`, `uninotes_onda_*`, `uninotes_taglio_*`)
  più vecchie di 6 ore; mai `uninotes_cestino_*` (contiene un audio).

## Canali nativi e motori insieme (quarto giro, 24/10/2026)

- **Contratto dei canali**: `test/crash_r4_canali_test.dart` tiene la tabella
  di tutti i canali dell'app (widget, focus, speech, incoming,
  registrazione, live_activity, calendario, sincronizzazione, apri_con,
  audio, disinstalla, spellcheck, notifiche): per ogni metodo chiamato da
  Dart controlla che il lato nativo di ogni piattaforma da cui la chiamata
  parte lo gestisca (Kotlin, Swift di iOS e macOS, C++ di Windows), che gli
  argomenti letti dal nativo abbiano gli stessi nomi, che i metodi mandati
  dal nativo abbiano chi li riceve in Dart. Una chiamata nuova in Dart senza
  la sua riga in tabella fa fallire il test. Controlla anche i tipi: su
  Android i numeri si leggono come `Number` (un int di Dart arriva come Int
  o Long), su Windows come int32 o int64, niente `as!`/`try!` in Swift.
- **Database con due motori (Android)**: sqflite tiene una sola connessione
  per file in tutto il processo, condivisa fra l'app e il motore senza
  interfaccia della sincronizzazione in background. Un motore chiuso a metà
  di una transazione (attività chiusa con «Indietro» durante una
  sincronizzazione, processo ancora vivo) lasciava la transazione aperta e
  ogni lettura del motore successivo in coda per sempre: l'app riaperta
  restava ferma all'avvio (in release sqflite non la annulla da solo).
  Ora aprendo si annulla, tranne quando il motore senza interfaccia è vivo e
  ci sta lavorando (`AppDatabase.rollbackOrphanOnOpen`, chiesto con `busy`
  sul canale della sincronizzazione).
- **Pulsanti delle notifiche ad app chiusa**: il motore in background dei
  pulsanti resta vivo finché vive il processo; la coda si rilegge prima di
  aggiungere un pulsante (prima, dopo che l'app l'aveva presa, il pulsante
  successivo rimetteva in coda anche quelli già eseguiti).
- **Attività nuova prima della distruzione della vecchia (Android)**: la
  vecchia toglie solo i suoi avvisi (file condivisi, pulsanti della notifica
  della registrazione), non quelli appena messi dalla nuova.

## Ricontrollo delle correzioni dei giri precedenti (quarto giro, 24/10/2026)

Errori nuovi introdotti dalle correzioni dei primi tre giri. Test in
`app/test/crash_r4_ricontrollo_test.dart`.

- **Scrittura sicura con la copia nuova bloccata** (`writeStringAtomic`): se
  la rinomina del `.part` falliva, l'originale si cancellava per riprovare e,
  fallita anche la seconda rinomina (antivirus, indicizzazione o client di
  sincronizzazione che tiene aperto il file appena scritto), si cancellava
  anche il `.part`: file perso. Ora dopo aver tolto l'originale il `.part` si
  copia al suo posto e non si cancella mai finché è l'unica copia.
- **Cartella degli appunti di ripiego e sincronizzazione**
  (`NotesStore.rootWithFallback`): con la cartella scelta non raggiungibile
  (disco scollegato, unità di rete che non risponde entro 4 secondi,
  cartella non creabile) si usa quella predefinita; la sincronizzazione
  prendeva quella come radice e i file della cartella scelta, che lì non ci
  sono, risultavano «eliminati qui»: finivano nel cestino del servizio e
  sparivano dagli altri dispositivi. Ora appunti e registrazioni non si
  sincronizzano finché la cartella scelta non torna, e l'esito lo dice.
- **Nomi delle cartelle degli insegnamenti cambiati** (`safeName` del terzo
  giro): punti iniziali tolti e punti finali tolti dopo il taglio a 90
  caratteri davano un altro nome a cartelle già esistenti (22 insegnamenti
  del database dei corsi, es. «… Pubbliche e Private C.I. …»; su Android,
  iOS e macOS il punto finale resta nel nome): registrazioni e appunti
  sparivano dall'app. La cartella col nome di prima prende quello nuovo al
  primo accesso (se quella nuova non c'è ancora).
- **Pagine HTML vere mostrate come testo** (`htmlNesting`): il conteggio
  dell'annidamento contava i `<p>`/`<li>`/`<td>` senza chiusura (che il
  parser chiude da solo) e i «i<n» dentro gli script; una pagina salvata dal
  browser superava i 1000 livelli e diventava un unico paragrafo con il
  codice. Ora non contano commenti, contenuto di script e stili ed elementi
  a chiusura implicita; l'annidamento vero oltre il limite resta testo.
- **Registro degli errori vuoto** (`ErrorLog.read`): una voce troncata a metà
  di una lettera accentata rendeva illeggibile tutto il file; ora i byte non
  validi diventano «�».
- **«Annulla» del testo dell'AI**: il testo di prima si teneva decodificato
  (un file non UTF-8 tornava con «�»); ora si tengono i byte. La nota
  modificata nell'editor si salva con `writeStringAtomic`.

## Aggiornamento dalle versioni precedenti (quarto giro, 24/10/2026)

Ricostruito dalla storia di git (4–24 ottobre 2026: la versione indicata nel
`pubspec.yaml` è sempre `2026.9.0`, quindi le versioni si distinguono solo per
data e per commit). Test in `app/test/crash_r4_aggiornamento_test.dart`: ogni
resto elencato sotto si ricostruisce nei test e si legge senza errori.

- **Windows, cartella dei dati**: fino al 10/10 l'eseguibile era
  `university_notes.exe` con azienda e prodotto «University Notes», quindi i
  dati stavano in `%APPDATA%\University Notes\University Notes`; con il nome
  UniNotes il sistema dà `%APPDATA%\UniNotes\UniNotes` e l'app si vedeva
  vuota. Ora `LegacyData.migrateWindowsSupportDir`
  (`lib/core/services/legacy_data.dart`, chiamata all'inizio di
  `_openServices`, prima del controllo dell'installazione) sposta database,
  libri, materiali, allegati, evidenziazioni, modelli, cache e stato della
  sincronizzazione nella cartella nuova, se lì non c'è già un database (mai
  due database insieme); il database passa per ultimo, così un'interruzione
  si riprende al riavvio. Non si portano `flutter_secure_storage.dat`
  (cifrato con una chiave che Windows tiene sotto il nome del vecchio
  eseguibile: gli account cloud vanno ricollegati) e
  `shared_preferences.json`.
- **Appunti**: la cartella delle risposte dell'AI si chiamava `Claude`. Se
  esistono sia `Claude` sia `AI` (la sincronizzazione riporta `Claude` da un
  dispositivo con l'app vecchia) i file di `Claude` si portano in `AI` senza
  sovrascrivere (` (2)` se il nome c'è già) e `Claude` si toglie quando
  resta vuota; prima quei file non comparivano in nessuna schermata.
  Registrazioni `.flac`/`.wav` senza dati accanto, dati accanto con solo
  alcuni campi, residui `.part`, il manifesto `.appunti.json` e i cestini
  `.cestino-onedrive`/`.cestino-googledrive`: elenchi, conteggi e
  ridenominazione funzionano come prima.
- **Registrazioni in corso**: la sessione ricorda il percorso assoluto della
  cartella `Registrazioni` di allora. Se la cartella degli appunti è
  cambiata (versione che salvava altrove, unità sparita, cartella scelta) la
  registrazione si salvava dove l'app non guarda, o dava «Recupero non
  riuscito» a ogni avvio. `currentTargetDir` (recording_save.dart) usa la
  cartella del corso in quella attuale (il corso si trova per id o per
  nome); vale anche per il ripristino dal cestino di una registrazione
  rimasta.
- **Cestino «Eliminati di recente»**: il formato di `info.json` non è mai
  cambiato; voci senza elenco dei file, illeggibili o già scadute si
  gestiscono (prova nel test).
- **Sincronizzazione**: la cartella predefinita sul servizio era «University
  Notes» e il file `onedrive_sync_state.json` della prima versione ha lo
  stesso formato degli attuali. Un file di stato rovinato accanto agli altri
  non ferma più la lettura degli altri (prima faceva scegliere la cartella
  «UniNotes», vuota, e non seguiva la rinomina della cartella: tutti i file
  diventavano conflitti). «Scollega» toglie il collegamento anche se il
  portachiavi non risponde.
- **Backup `.json`**: un backup di una versione senza profilo e anni del
  piano (schema 5 o prima) non cancella più il percorso scelto adesso: si
  svuotano solo le tabelle presenti nel file. Copie `.db` di ogni versione
  dello schema (1–13) si convertono in backup e si ripristinano.
- **Impostazioni**: tutte le chiavi del codice e quelle storiche (gruppi
  degli studenti, Gemini e Antigravity, percorsi per ateneo, mappa offline…)
  con ventidue forme di valore diverse non fanno lanciare nessun lettore e
  non rompono le sezioni dell'app. Le chiavi tolte restano come righe
  inerti.
- **Resto verificato senza modifiche**: cache del catalogo (`meta.json` con
  `community`, registro `ateneo.json` di altri formati, cartelle `corsi`,
  `moduli`, `community`, altri corsi in `per_corso`), modelli Whisper con
  nomi vecchi (`ggml-base.en`, `distil-large-v3`, il modello integrato di
  Windows), archivi e cartelle a metà (`whisper.zip`, `bin.part`), posizione
  e segnalibri del lettore con la chiave del percorso assoluto, file
  recenti in altre forme, chiave di Gemini e impostazioni di Antigravity,
  caselle di sincronizzazione scritte dalle prime versioni, controllo
  dell'installazione con preferenze di altro tipo.
- **Limiti noti**: sotto Windows, dopo il passaggio di cartella, posizione
  del lettore, segnalibri ed evidenziazioni dei file dentro l'app (libri,
  materiali) erano legati al vecchio percorso assoluto e non si ritrovano
  (le chiavi sono un'impronta di quel percorso); un modello o una cache
  rimasti con nomi non più usati occupano spazio ma non danno errori.

## Prova a caso dell'interfaccia (quarto giro, 24/10/2026)

`app/test/crash_r4_monkey_test.dart` apre l'app vera (`UniversityNotesApp`:
onboarding o AppShell) con tre database preparati — vuoto (primo avvio),
piano reale (PoliTO, esami finali, prove in itinere, Studio, libri con file,
appunti, trascrizioni e registrazioni WAV finte), casi limite (nomi con
emoji, destra-sinistra, righe enormi, CFU strani, date del 1970, file
rovinati) — e con un generatore a seme fisso esegue azioni a caso: tocchi e
pressioni lunghe sugli elementi toccabili davvero (prova del tocco), tocchi in
punti a caso, scorrimenti e lanci, testo casuale nei campi (emoji, 20000
caratteri, numeri strani, date impossibili), «Indietro», Esc, Tab, frecce,
Pagina giù, finestra da 320×568 a 1920×1080, caratteri ×1/×1,3/×2, tema
chiaro/scuro, attese. Dopo ogni azione raccoglie errori di Flutter ed
eccezioni non gestite e si ferma con scenario, seme, passo e ultime 40 azioni.

- **Niente risorse vere**: selettore dei file finto (annulla o dà file di
  prova, anche vuoti o rovinati), percorsi di sistema in una cartella
  temporanea, link, «Condividi», «Apri con», microfono, notifiche, calendario
  e cloud finti. Si saltano i pulsanti che userebbero account o dati veri
  («Accedi…», «Collega…», «Elimina tutti i dati», Esplora file, appunti di
  sistema di Windows).
- **Giri**: nella suite normale tre semi e 360 azioni (~20 s); giro lungo
  con `CRASH_R4_MONKEY=1` (`CRASH_R4_SEEDS`, `CRASH_R4_ACTIONS`,
  `CRASH_R4_SCENARIO`, `CRASH_R4_SEED` per riprodurre un seme,
  `CRASH_R4_TRACE=1` per vedere ogni azione).
- **Trovati e corretti** (prove mirate nello stesso file, gruppo «casi
  trovati dalla scimmia»):
  - grandezza del testo del sistema cambiata con l'app aperta: `AppTextScaler`
    dava a Flutter un `textScaleFactor` che seguiva subito il sistema, il
    MediaQuery vecchio e il nuovo risultavano uguali e i testi restavano
    impaginati con la grandezza di prima («debugSize == size» al primo
    cambio di colore); ora è il valore fisso del momento;
  - `setState(() => _future = _load())` (la freccia restituisce il Future):
    Impostazioni → Calendario e Notifiche, OneNote, Google Drive, Whisper,
    Eliminati di recente;
  - Pagina giù/su e frecce con il fuoco fuori dalle liste e più liste
    verticali nella pagina (telefono e tablet con tastiera):
    `SafeScrollAction` (`lib/core/router/safe_scroll_action.dart`);
  - barra della posizione del lettore di una registrazione con il lettore
    di schermo: mancavano `increasedValue`/`decreasedValue`;
  - Studio → «Cambia insegnamento» aperto mentre la finestra passa da
    stretta a larga (o il tablet ruota): la shell ricrea Studio e la scelta
    chiamava `setState` su quello eliminato;
  - Esami → Medie in colonna stretta con i caratteri grandi: «30 e lode»
    occupava tutta la riga di ListTile (ora al massimo 96 px, rimpicciolito);
    Libri: la scheda di un libro senza file decide dove mettere «Aggiungi»
    anche dalla sua larghezza (sotto il testo se è sotto i 480 px), non solo
    da quella della finestra;
  - modulo dell'insegnamento con il nome cancellato e scorso in basso: il
    campo fuori dalla lista non viene controllato da `validate()` e `_save`
    finiva su un `!` nullo; ora un messaggio.
- **Asserzioni di Flutter** (solo in debug, pila senza codice dell'app;
  contate a parte dalla prova): volo di un Hero (SnackBar) deviato quando,
  durante l'apertura di una pagina, un tocco arriva alla pagina sotto; TabBarView
  che cambia scheda mentre si ricostruisce durante un lancio; DropdownButton
  che chiude il menu mentre si ricostruisce o con un menu più alto della
  finestra; riconoscitore del doppio tocco chiuso durante una ricostruzione
  (selettore dell'ora); frecce su/giù e posizione del cursore di un campo
  con l'impaginazione scaduta. In release non chiudono l'app.
- I «testi fuori spazio» (RenderFlex overflowed) si contano e si stampano
  ma non fermano la prova: non sono crash.
