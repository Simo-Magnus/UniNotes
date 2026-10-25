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
  un'unità di rete che non risponde entro 15 secondi vale «non raggiungibile»
  (4 fino al quinto giro, vedi sotto).
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
  (disco scollegato, unità di rete che non risponde entro 15 secondi,
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

## Quinto giro: resti dei giri precedenti (24/10/2026)

Test in `app/test/crash_r5_resti_test.dart` (rossi sul codice del commit
84ee405d, verdi dopo).

- **Insegnamento a scelta archiviato troppo presto**: eliminando una prova
  in itinere o un esonero di un insegnamento a scelta senza esame finale,
  l'insegnamento si archiviava anche se gli restavano altre prove. Regola
  decisa dall'utente: si archivia (con l'avviso «… è un insegnamento a scelta
  e questa è la sua ultima prova» e «Annulla») solo quando non gli resta
  NESSUNA prova, né esame finale né prove in itinere / esoneri
  (`wouldDropElective`/`dropElectiveWithoutExam`, `docs/esami.md`).
- **Rinomina della cartella di un insegnamento con la cartella in uso**
  (`NotesStore.renameCourse`): gli appunti restavano col nome vecchio e
  sparivano dall'app. Ora la rinomina resta in sospeso (impostazione
  `notes_pending_course_renames`, nome nuovo → nome sul disco): l'app usa la
  cartella col nome di prima (anche per le registrazioni nuove), riprova a
  ogni accesso e, se la cartella col nome nuovo c'era già, mostra anche i
  file rimasti in quella vecchia durante l'unione (che ora prosegue file per
  file e dà « (2)» ai nomi già presenti). Modulo dell'insegnamento e
  «Rinomina» lo dicono con `NotesStore.renamePendingNote`.
- **Unità che si sveglia** (`NotesStore._reachable`): con 4 secondi un disco
  USB o di rete in risparmio energetico mandava nella cartella di ripiego
  (vuota) e le registrazioni nuove si salvavano lì. Ora il primo controllo
  aspetta fino a 15 secondi; «raggiungibile» si ricorda per 2 minuti, «non
  raggiungibile» risponde subito e si ricontrolla dietro le quinte al
  massimo ogni 20 secondi (un controllo alla volta per unità). Quando si
  passa alla cartella di ripiego si annota il momento
  (`notes_fallback_since`); quando quella scelta torna, i file salvati da
  allora nella cartella di ripiego (e gli elementi del cestino eliminati da
  allora) si spostano nella stessa posizione di quella scelta, senza
  sovrascrivere (« (2)»), con `moveFile` (anche fra dischi diversi; un file
  in uso resta e si riprova). Gli allegati di Studio che li indicavano
  seguono il percorso nuovo. Gli appunti più vecchi della cartella
  predefinita restano dove sono.
- **Percorsi degli allegati con la cartella di ripiego** (`DataSync`): si
  traducevano rispetto alla cartella di ripiego e quelli della cartella
  scelta andavano agli altri dispositivi come assoluti. Ora la radice dei
  percorsi è sempre la cartella scelta (`NotesStore.syncRoots`, anche se ora
  non raggiungibile) e i file della cartella di ripiego si scrivono relativi
  come se fossero già in quella scelta.
- **Ripristino da «Eliminati di recente» dopo il cambio della cartella degli
  appunti** (`RecycleBin.currentOrigin`): le voci ricordano il percorso
  assoluto d'origine e i file tornavano nella radice di prima. Un file di un
  insegnamento (`…/<insegnamento>/<Registrazioni|Trascrizioni|Riassunti|
  Appunti|AI>/<file>`) torna nella stessa cartella della radice attuale;
  vale anche per «Annulla» del ripristino.
- **«Elimina tutti i dati» su Android**: aspetta anche la sincronizzazione
  del motore in background (`CloudDriveService.busyElsewhereNow`, fino a
  `syncWait`) e per tutta l'eliminazione nessuna sincronizzazione parte
  (`CloudDriveService.hold`, anche quella chiesta dal lavoro periodico di
  Android all'app aperta); resta acceso dopo un'eliminazione riuscita
  (database chiuso, app da riaprire), si spegne se l'eliminazione fallisce.
- **Tocco su un widget Android durante l'avvio** (`MainActivity.onNewIntent`):
  se Dart non è ancora partito il motore scarta il messaggio `route` e il
  tocco andava perso. Ora l'invio ha una risposta: «non gestito» o errore
  rimettono la schermata in `pendingRoute`, che l'app legge con `takeRoute`
  all'avvio e a ogni ritorno in primo piano (con Dart partito ma senza
  ascolto il messaggio resta in coda nel motore). Il test controlla il
  sorgente Kotlin.
- **Percorsi relativi** (`ExternalLauncher.unsafePathReason`): «Apri cartella»
  di un libro con un percorso relativo apriva la cartella di lavoro del
  programma (`p.dirname('libro.pdf')` = «.»). Ora `openPath` e `openWith`
  rifiutano i percorsi relativi con «Percorso incompleto…».
- **Caricamenti su reti molto lente** (`ioTransport`): il corpo doveva
  partire tutto entro il tempo di «almeno 32 KB/s». Ora si invia a pezzi da
  16 KB e scade solo se un pezzo non parte entro `networkIdleTimeout`
  (60 secondi); dopo l'ultimo pezzo si aspetta la risposta per
  `networkIdleTimeout` più il tempo di al massimo 512 KB rimasti nella
  memoria della connessione.
- **Minori**: pagina HTML troppo annidata mostrata come testo
  (`parseHtmlSafe`) con «&amp;» alla lettera (le entità si raddoppiavano);
  `WavWriter.duration`/`dataBytes` contavano anche i pezzi non scritti dopo
  un errore (disco pieno, limite dei 4 GB): ora solo quelli scritti, e dopo
  un errore i pezzi nuovi non si contano.
- **Da provare su dispositivo**: disco USB o di rete addormentato (Windows),
  rinomina di un insegnamento con la cartella aperta in Esplora file o in
  sincronizzazione, tocco sul widget degli esami ad app chiusa (Android),
  caricamento di una registrazione grande su una rete lenta.

## Testi ed elementi che escono dal loro spazio (quinto giro, 24/10/2026)

Un «A RenderFlex overflowed by N pixels» è un difetto d'aspetto in release (testo
tagliato, pulsante fuori dal riquadro) e le strisce gialle e nere in debug. La
prova a caso del quarto giro li contava ma non si fermava (circa 29 prove su 36
ne avevano). Dal quinto giro **un overflow è un errore della prova**.

**Raccolta nella prova a caso** (`test/crash_r4_monkey_test.dart`):
- `OverflowSpot` registra per ogni overflow il widget dell'app responsabile
  (file:riga dal «relevant error-causing widget»), il lato, i pixel, la
  finestra, la scala dei caratteri, il tema, la schermata (i widget dell'app
  sopra l'elemento) e l'azione che l'ha mostrato. A fine prova stampa una riga
  `OVERFLOW|file:riga|widget|lato|volte|pixel max|finestre|caratteri|temi|schermate|azione`
  per luogo; il riepilogo di tutto il giro si ottiene con
  `grep "^OVERFLOW|"` sull'output.
- Senza opzioni un overflow ferma la prova con il messaggio completo. Con
  `CRASH_R5_COLLECT=1` si raccolgono senza fermarsi (per fare l'elenco). Gli
  errori di layout riportano anche `constraints:` e `creator:`.
- `CRASH_R5_FULL=1` aggiunge a `test/crash_r2_layout_test.dart` (tutte le
  schermate e i riquadri con i dati limite) le finestre 568×320 (orizzontale)
  ×2, 360×640 ×1,3, 768×1024 ×2 e 1366×768 ×2: zero overflow.
- Nei test il carattere è Ahem (ogni lettera è un quadrato largo quanto il corpo):
  è circa il doppio più largo dell'IBM Plex, quindi la prova è più severa della
  realtà; con i caratteri ×2 è come un ×4 vero.

**Luoghi trovati e corretti** (3 giri di raccolta da 36 prove × 1200 azioni, poi
il giro finale senza nessun overflow):

| Luogo | Causa | Correzione |
| --- | --- | --- |
| Foglio «Altro» della barra in basso (`app_shell.dart`) | colonna di voci non scorrevole in un foglio basso (320 px in orizzontale) | `SingleChildScrollView` |
| Foglio «Nuova prova» (`exams_screen.dart`), segnalibro del registratore e del lettore, «Allega a…» (`attachments.dart`) | stessa causa | `SingleChildScrollView` |
| Modulo del libro, «Stato di possesso» (`book_form.dart`) | menu a tendina a mezza larghezza con voce lunga | `isExpanded` e puntini |
| Riquadro dell'anno mostrato (`YearStatusBanner`), riquadro «Anni precedenti» (`PreviousYearsBanner`) | testo e pulsante («Segna come completato») sulla stessa riga | `AdaptiveActionRow`: una riga se c'è posto, il pulsante sotto se no |
| Menu «Cambia anno» (`year_widgets.dart`) | etichetta di stato non comprimibile | `Flexible` e puntini |
| Chip «Da aggiungere» (`MutedChip`) e riga dei libri senza file (`books_screen.dart`) | chip più largo della riga | chip con puntini, `TrailingRow` |
| Riga di un esame in «Anni precedenti» (`previous_years_screen.dart`) | soglia fissa (560 px) per mettere il selettore accanto al testo, ma il selettore cresce con i caratteri | soglia moltiplicata per la scala dei caratteri |
| Intestazione di sezione con pulsante (`SectionHeader`, «Segna tutti come sostenuti») | pulsante a destra senza limite | massimo il 60% della riga, la scritta va a capo |
| Titolo delle sessioni con casella e «Aggiungi» (`sessions_tab.dart`) | titolo e pulsante senza posto | il titolo è `Flexible` con puntini |
| Intestazione della materia nelle sessioni | riepilogo «N sessioni · tempo» senza limite | massimo metà riga |
| Pulsanti «Segna», registra, «Salva» (`recorder_screen.dart`) | tre colonne senza limite con scritte larghe | i laterali dividono lo spazio, scritte con puntini |
| Pulsante degli avvisi in basso («Aggiungi nota», «Annulla») | `SnackBarAction` di Flutter dà alla scritta larghezza illimitata e misura l'ingombro senza la scala dei caratteri | `AppSnackBarAction` (un vero `SnackBarAction` dentro un limite del 55% dello schermo, la scritta va a capo), usato nei 6 avvisi con pulsante |
| Selettore dell'ora | quadrante e campi di misura fissa, caratteri ×2 e finestra bassa | `showSafeTimePicker`: caratteri ×1,3 (×1 con finestra più bassa di 420 px) solo nel selettore |
| Intestazione dell'insegnamento negli esami sostenuti (`taken_exams_tab.dart`) | badge «Voto finale» senza limite | `TrailingRow` |
| Formati supportati (`files_screen.dart`) | etichetta della famiglia di formati non comprimibile | `Flexible` e puntini |
| Riquadri «Eliminare la prova/la registrazione?», «Esame a scelta», «Segnare tutti come sostenuti?», voto (`GradeDialog`) | contenuto più alto della finestra (320 px in orizzontale) | `AlertDialog(scrollable: true)` |
| Formula in linea più larga della riga (`MathFormula`) | una formula in una riga di testo non si spezza | `FittedBox(scaleDown)` (più stretta: invariata; non si legge: il testo di ripiego va a capo come prima) |

In più, in via preventiva, `scrollable: true` su altri 26 riquadri con
contenuto a colonna (nessun cambiamento dove lo spazio basta; aiuta anche con
la tastiera a schermo).

**Esito**: due giri lunghi consecutivi (36 prove × 1200 azioni = 43.200 azioni
ciascuno, tre scenari, 12 semi, finestre da 320×568 a 1920×1080, caratteri
×1, ×1,3 e ×2, tema chiaro e scuro) senza errori e senza overflow; suite
completa 1593 superati, 4 saltati.

**Strumenti nuovi**: `lib/widgets/adaptive_row.dart` (`AdaptiveActionRow`,
`TrailingRow`), `lib/widgets/app_snack_action.dart` (`AppSnackBarAction`),
`showSafeTimePicker` in `lib/widgets/date_pick.dart`. Chi aggiunge una riga con
un pulsante o un'etichetta a destra deve usarli (o un `Flexible`/`Expanded` con
puntini): la prova a caso e `test/crash_r5_layout_test.dart` falliscono al
primo overflow.

**Altri errori trovati dalla stessa prova**:
- `_BooksButton._open` (`topics_tab.dart`): dopo aver toccato un libro nel
  foglio si usava il `context` del pulsante senza controllare `mounted`; con
  la finestra ridimensionata a foglio aperto il pulsante non c'era più e
  `openBook` falliva con «Looking up a deactivated widget's ancestor is
  unsafe». Ora `if (context.mounted)`.

**Sospetti non confermati** (non riprodotti con lo stesso seme né con prove
mirate, pila solo di Flutter, solo con le asserzioni di debug):
- `RRect argument contained a NaN value` nell'indicatore del valore del
  cursore della durata Focus (`focus_setup.dart`), una volta, subito dopo un
  cambio di finestra e di caratteri;
- `offset.isFinite` nell'albero semantico (`_BoxEdge`), una volta, con la prova
  a caso e il lettore di schermo acceso;
- «Trailing widget consumes the entire tile width» in una scheda di libro
  (`book_tile.dart`) dopo un ridimensionamento 360→1920 con la schermata Libri;
  `test/crash_r5_layout_test.dart` prova ora la scheda in colonne da 280 a
  1200 px e la schermata con la finestra che cambia, senza errori.
  Se si ripresentano, i resoconti ora hanno `constraints:`.

**Test**: `test/crash_r5_layout_test.dart` (avvisi, registratore, righe con
pulsante, intestazioni, riquadri degli anni, fogli, riquadri, selettore
dell'ora, schede dei libri, formule), con 320×568, 568×320 e 1920×1080,
caratteri ×1 e ×2 e tema chiaro e scuro (`CRASH_R5_FULL=1`: tutte le sei
finestre e anche ×1,3).

## Sesto giro: codice nativo cambiato di recente (25/10/2026)

Ricontrollo di Swift (iOS e macOS), Kotlin e C++ del runner Windows
cambiati dopo il quarto giro: risposte ai canali mancanti o doppie,
riconoscitori lasciati aperti, lavoro pesante sul filo principale.

- **Riconoscitore di Apple fermato durante la preparazione** (iOS/macOS 26,
  `LiveSpeech.swift`, uguale nei due runner): se lo «stop» o una nuova
  sessione arrivavano mentre il modello della lingua si scaricava (o Dart
  smetteva di aspettare dopo 45 s), al termine del download partiva lo
  stesso un `SpeechAnalyzer` con un flusso d'audio che nessuno chiudeva più
  (modello in memoria, attesa dei risultati per sempre); su iPhone partiva
  anche SFSpeechRecognizer di riserva, a registrazione già finita. Ora
  `begin` ricontrolla lo stop dopo ogni attesa, chiude l'analisi se è stata
  fermata mentre partiva e, se l'avvio fallisce, chiude flusso e risultati;
  `cancel` chiama `cancelAndFinishNow()` (la fine del flusso da sola non
  chiude l'analisi, dice la documentazione di Apple); niente riserva dopo
  uno stop. `start` risponde sempre, anche senza l'oggetto del canale.
- **`support` senza limite di tempo**: da iOS/macOS 26 chiede al sistema le
  lingue di SpeechAnalyzer; senza risposta il testo dal vivo restava «in
  avvio» e il recupero a fine lezione (che aspetta l'avvio) non finiva.
  Ora `SystemSpeech.kSupportTimeout` (15 s): poi «non disponibile» e si
  passa al motore successivo.
- **Pulsanti della Live Activity doppi** (`AppDelegate.swift`): l'osservatore
  dei comandi si aggiungeva a ogni motore creato senza togliere il
  precedente (scena chiusa dal sistema e riaperta): «Pausa» arrivava due
  volte e si annullava. Ora uno solo (token salvato e tolto).
- **«Apri in UniNotes» con un file di iCloud Drive** (`IncomingFiles`): la
  copia con la lettura coordinata (che scarica il file se non è sul
  telefono) girava sul filo principale; all'avvio aperto dal file iOS
  chiudeva l'app per il blocco (watchdog). Ora la copia è in background e
  Flutter riceve `available` quando i file sono pronti (i messaggi arrivati
  prima che Dart ascolti restano nel buffer del canale).
- **Permesso del calendario chiesto con l'attività che si chiude (Android)**:
  il `result` in attesa restava senza risposta (Dart in attesa per sempre).
  Ora `UniNotesCalendar.dispose()` in `cleanUpFlutterEngine` risponde con lo
  stato attuale.
- **Dettatura di Windows** (`live_speech.cpp`): eventi arrivati dopo la
  chiusura del riconoscitore (StartAsync o compilazione finiti dopo uno
  stop) non segnano più «in esecuzione» senza sessione né mandano «error»
  dopo «ended»; uno «stop» durante StartAsync risponde anche allo «start».
- **Controllati senza difetti**: `notification_identity.cpp` (COM già
  inizializzato dal filo principale, `HStringReference` valido per tutta la
  chiamata, ogni HRESULT controllato), `main.cpp` (AUMID prima di ogni
  finestra, mutex dell'istanza unica chiuso su ogni uscita),
  `focus_session.cpp`, `open_with.cpp`, `spell_check.cpp`,
  `flutter_window.cpp` (canali tolti prima del motore), `BackgroundSync.kt`,
  `RecordingNotification.kt`, `IncomingShare.kt`, `LiveSpeech.kt`, la Live
  Activity. `requestSync` urgente (`UniNotesCalendar.kt`): chiamata binder
  valida da qualsiasi filo e anche dal motore senza interfaccia; la quota
  dei lavori urgenti si applica nel sistema e non lancia nell'app; l'unica
  eccezione possibile è `IllegalArgumentException` di
  `SyncRequest.Builder.build()` con combinazioni vietate
  (`SCHEDULE_AS_EXPEDITED_JOB` con `SYNC_EXTRAS_EXPEDITED`, con la ricarica o
  periodica), già dentro un `try`.
- **Conferma dell'account del calendario (Android, 25/10/2026)**: la
  finestra `newChooseAccountIntent` (vedi `docs/notifiche.md`, «Caricamento
  immediato e conferma dell'account») risponde una volta sola: da
  `onActivityResult` (esito letto dal sistema, non dal codice della
  finestra), da `dispose()` con l'attività chiusa, subito con null se l'app
  non è in primo piano o l'avvio della finestra fallisce; una seconda
  richiesta fa rispondere la prima. Lato Dart una sola finestra alla volta
  (`confirmCalendarAccount` restituisce quella in corso) e ogni errore del
  canale vale «non aperta». Test: `test/crash_r6_calendario_account_test.dart`.

**Test**: `test/crash_r6_nativo_test.dart` (`support` senza risposta, con
`SystemSpeech` e con `LiveTranscriber`; controlli dei sorgenti Swift, Kotlin
e C++ per ogni caso sopra). Kotlin compilato con `kotlinc` e gli stub di R e
AndroidX, i C++ toccati con MSVC (`/W4 /WX`); lo Swift va compilato su un Mac.

## Sesto giro: regole di analisi (25/10/2026)

Ricerca sistematica con regole dell'analizzatore più severe, provate prima
su una copia di `lib/` e `test/` (avvisi in `lib` / `test`) e poi lasciate
in `app/analysis_options.yaml` solo se senza rumore. Test in
`app/test/crash_r6_lint_test.dart` (rossi sul codice del commit 259699fa,
verdi dopo).

**Attive da ora** (il codice è pulito; un falso positivo si annota sulla
riga con `// ignore: <regola>` e un motivo, o con `unawaited(...)`):

| Regola | Avvisi trovati | Esito |
| --- | --- | --- |
| `strict-casts` (opzione del linguaggio) | 2 / 0 | falsi positivi corretti con un tipo esplicito: `runIsolated` (errore dell'isolate già controllato `!= null`), `NoVideoControls` di media_kit (vale `null` senza tipo) |
| `unawaited_futures` | 4 / 5 | falsi positivi: `Map.remove` di un Future già atteso (scaricamenti, pulizia delle trascrizioni, controllo delle unità), dialogo di avanzamento dell'eliminazione, «browser» finto nei test OAuth, `openFocusScreen` nei test, zona della prova a caso |
| `avoid_dynamic_calls` | 0 / 4 | test: campi interni di sqflite (annotati), JSON dei test Outlook (tipizzato) |
| `cancel_subscriptions`, `throw_in_finally`, `avoid_void_async`, `unnecessary_statements`, `no_self_assignments`, `invalid_case_patterns`, `literal_only_boolean_expressions`, `test_types_in_equals` | 0 | nessun avviso: restano come guardia |

`use_build_context_synchronously`, `control_flow_in_finally`,
`null_check_on_nullable_type_parameter`, `unrelated_type_equality_checks`,
`collection_methods_unrelated_type` e `hash_and_equals` erano già attive
(flutter_lints): 0 avvisi.

**Provate e lasciate spente** (rumore senza casi veri, o casi veri già
coperti):

- `discarded_futures` (75 / 2): quasi tutti chiamate volute senza attesa
  (navigazione, `_load()` in `initState` con il `try` dentro, `cancel()`
  nei `dispose`, `.catchError` già presente). Ha trovato i due casi veri
  qui sotto, corretti; tenerla obbligherebbe a un `unawaited` su ogni
  apertura di pagina.
- `cast_nullable_to_non_nullable` (51 / 48): `riga['colonna'] as String` su
  colonne NOT NULL del database e JSON già controllato con `is`; i lettori di
  file esterni (evidenziazioni, segnalibri, OneNote) hanno già il `try` per
  voce.
- `avoid_slow_async_io` (202 / 36): consiglio di prestazioni, non di
  crash.
- `no_adjacent_strings_in_list` (32 / 13): controllate tutte, nessuna
  virgola mancante (testi lunghi a capo, migrazione v9 compresa).
- `avoid_catching_errors` (11 / 4): `ArgumentError`/`RangeError`/
  `StackOverflowError` presi apposta (fusi orari, ZIP, KFX, testo annidato).
- `only_throw_errors` (2 / 2): si rilancia un errore già preso.
- `unnecessary_null_checks` (3 / 5), `close_sinks` (0 / 6, StreamController
  dei test), `unsafe_variance` (6 / 0, callback di widget generici mai
  usati con un sottotipo), `avoid_futureor_void` (1 / 0),
  `missing_whitespace_between_adjacent_strings` (15 / 134, SQL e CSS).
- `strict-inference` e `strict-raw-types` (18 / 20): `const []`, `Map`
  senza argomenti di tipo; i `.cast<Map>()` su JSON dei lettori (canvas,
  Excalidraw, notebook) lanciano un TypeError già preso dal lettore («file
  non leggibile», prova con byte casuali in `reader_fuzz_test`).
- `avoid_returning_null_for_future`: tolta da Dart 3.3.

**Casi veri corretti** (`core/services/desktop_window.dart`):

- **Finestra che non si riapriva dall'icona dell'area di notifica**: con
  una registrazione in corso e la finestra chiusa con la X, il tocco
  sull'icona (o «Apri UniNotes») toglieva prima l'icona; se il sistema non
  la toglieva (`destroy` con errore, il caso già gestito in `_quit`)
  l'errore restava non gestito prima di `show()`, la finestra restava
  nascosta e anche «Esci» dal menu non arrivava a chiedere cosa fare della
  registrazione. Ora l'errore dell'icona si registra e la finestra si apre.
- **«Salva la registrazione» dall'icona senza risposta**: con la finestra
  nascosta un salvataggio non riuscito (disco pieno, cartella non
  scrivibile) era un errore non gestito senza nessun avviso. Ora arriva la
  notifica «Registrazione non salvata» (il file audio resta nell'app e al
  prossimo avvio si propone di salvarlo).

## Prova a caso estesa (sesto giro, R6-B, 25/10/2026)

La prova a caso del quarto giro raggiungeva poco o niente delle parti più
profonde (onboarding completo, lettore con i vari formati, registratore con un
flusso audio, Focus, Impostazioni e Collegamenti con i servizi collegati).
L'impianto ora sta in `test/support/monkey_harness.dart` (usato da
`test/crash_r4_monkey_test.dart`, tre scenari, e da
`test/crash_r6_monkey_test.dart`, nove scenari nuovi) e ogni scenario insiste su
una parte dell'app.

**Impianto** (`monkey_harness.dart`)
- `MonkeyScenario` = dati di partenza + `MonkeyArea` + `MonkeyOptions`.
  `MonkeyArea` dice da dove si parte (`sezione:Studio`, `registra`…), ci torna
  da sola quando la scimmia ne esce (barra e colonna di navigazione evitate al
  97%), preferisce certi pulsanti (`prefer`) e fa azioni sue con un peso
  (`actions`: audio finto, eventi del riconoscitore, scorciatoie da tastiera,
  minuti che passano, «Importa un backup», macro «registrazione completa»,
  «sessione Focus completa», «compila i campi e conferma», «elimina e annulla»).
  Aiuti per le azioni: `tapMatching`, `tapKey`, `tapIcon`, `tapAny`,
  `typeInField`, `shortcut`, `shows<T>()`.
- Finti che si rompono a comando (`MonkeyFakes`, `MonkeyChannels`): microfono
  (`FakeMic`: audio di vari livelli, silenzio, pezzi di lunghezza dispari, flusso
  che finisce, pausa del sistema, permesso negato, microfono occupato, ripresa che
  non riesce), riconoscimento vocale del sistema (canale `speech`: testo
  provvisorio e definitivo, errori, eventi di sessioni vecchie), Parakeet finto
  con motore VAD, conversione audio (canale `audio`: copia il file, ogni tanto
  `false` o un errore del sistema), `connectivity_plus`, OneDrive e Google Drive
  in memoria (rete assente, errori 503, file «dal sito»), calendario di sistema
  (accesso revocato, nessun calendario, scritture che falliscono), notifiche
  (permesso negato), selettore dei file con una coda di file da dare (backup
  validi, parziali, di versione futura), orologio del Focus
  (`AppServices(focusTimer: …)`: i minuti passano senza aspettarli), database
  azzerabile (primo avvio da capo nell'onboarding), file di prova di ogni formato
  del lettore (`fuzzCorpus()` più due varianti rovinate per ognuno).
- Ogni errore riporta ora il contesto (finestra, caratteri, tema, schermata,
  vincoli degli oggetti sopra l'errore); a fine prova `TOCCHI|scenario|seme|azioni|
  distinti|…` elenca quante volte è stato toccato ogni elemento, per vedere che
  cosa raggiunge una prova.

**Scenari** (`CRASH_R4_SCENARIO=<nome>`)

| Scenario | Dati | Dove insiste |
| --- | --- | --- |
| `onboarding` | database vuoto | primo avvio completo (aspetto, ateneo, corso, anno, AI, lingua delle lezioni, avvisi, calendario, esclusioni); finito, database azzerato e di nuovo |
| `cambio_corso` | piano reale | Impostazioni → «Cambia corso» e i passi del percorso |
| `impostazioni` | piano (a volte con casi limite) + backup | tutte le sezioni e i dialoghi, calendario e notifiche finti, server finti, esporta/importa |
| `collegamenti` | piano | OneDrive, Google Drive, Whisper, Parakeet, AI con accesso finto che riesce e server che vanno e vengono |
| `lettore` | piano + file di prova di ogni formato (buoni e rovinati) | sezione File, apertura diretta, ricerca, pagine, zoom, segnalibri, «Apri con» |
| `registratore` | piano | registrazione con audio e testo dal vivo finti, correzione del testo, lingua, salvataggio, lettore, «Trascrivi con…» |
| `studio` | piano | Argomenti, cronometro, Focus (avvio, pausa, salta pausa, termina, minuti che passano), moduli, allegati |
| `esami` | piano | prove (aggiunta, modifica, elimina con «Annulla»), Anni precedenti, Voti dell'anno |
| `libri` | piano | elenco, schede, apertura nel lettore |

**Giri**: la suite normale (`crash_r6_monkey_test.dart`) fa un seme da 35 azioni
per scenario (circa 30 secondi); il giro lungo si lancia con
`CRASH_R4_MONKEY=1` e `CRASH_R4_SEEDS`, `CRASH_R4_ACTIONS`, `CRASH_R4_SCENARIO`,
`CRASH_R4_SEED`, `CRASH_R4_TRACE`, `CRASH_R5_COLLECT` come per il quarto giro.
Più `flutter test` insieme nella stessa cartella si bloccano a vicenda
(`build/native_assets/windows/sqlite3.dll`, cache del compilatore): per i giri
lunghi in parallelo si usano copie della cartella `app` con le giunzioni di `lib`,
`test` e `assets` (e il proprio `pub get --offline`).

**Casi trovati e corretti** (prove mirate in `test/crash_r6_trovati_test.dart`,
rosse sul codice del commit 259699fa, verdi dopo la correzione, salvo i due
segnati «non rossa»)

| Caso | Causa | Correzione | Test |
| --- | --- | --- | --- |
| Scelta della cartella di OneDrive/Google Drive senza rete, doppio tocco su una cartella: eccezione non gestita (`GraphException`) | `OneDriveFolderDialog` sostituiva il futuro dell'elenco prima che il `FutureBuilder` lo ascoltasse e l'errore di rete del primo restava senza ascoltatori | `_list()` aggancia un ascoltatore che ignora l'errore (lo mostra il `FutureBuilder`) | `scelta della cartella: doppio tocco senza rete` |
| Stessa cosa in `RevisionBuilder` (la base di quasi tutte le schermate): due `revision.bump()` di fila con un errore di lettura | come sopra | `RevisionBuilder._run` aggancia lo stesso ascoltatore (`lib/widgets/common.dart`) | `RevisionBuilder: due ricaricamenti di fila con un errore` |
| Lettore: avviso «Per la sezione completa usa OneNote» con «OneNote» e «Apri con…» sulla stessa riga: al testo restava larghezza 0, una lettera per riga, colonna alta 1547 px (overflow); a 320×568 ×2 l'avviso occupava tutta l'altezza | `Row` con testo `Expanded` e due `TextButton` senza limite | `AdaptiveActionRow` (i pulsanti vanno sotto il testo se non c'è posto) e l'avviso non supera un terzo dell'altezza (scorre) (`reader_screen.dart`) | `avviso del lettore con due pulsanti su un telefono` |
| Lettore di un file audio/video con la trascrizione in una finestra bassa: i comandi del lettore non scorrevano e spingevano fuori la trascrizione (176 px) | `Column` con i comandi non scorrevoli | i comandi occupano al massimo metà altezza e scorrono (`media_view.dart`) | `registrazione con trascrizione in una finestra bassa` |
| Lettore di una registrazione, 568×320 con i caratteri ×2: «Nessuna trascrizione» (158 px) e intestazione della trascrizione (19 px) più alte del riquadro; a 320 px i cinque pulsanti di avanti e indietro (8 px) e le due durate sotto la barra (0,75 px) uscivano | colonne e righe senza scorrimento né riduzione | `SingleChildScrollView`, intestazione al massimo metà del riquadro che scorre, `FittedBox(scaleDown)` per i pulsanti, durate con puntini (`recording_player_screen.dart`) | `registrazione con trascrizione in una finestra piccola` |
| «Trova nel testo» (lettore, registrazioni, appunti): esito («Nessun risultato») spingeva i pulsanti fuori, 218 px a 360 px ×2 | testo senza limite nella riga | `Flexible` con puntini (`find_bar.dart`) | `barra «Trova nel testo» stretta con i caratteri grandi` |
| Colonna di navigazione (nove voci) più alta della finestra con i caratteri ×2 (1280×800) o con finestre basse (70 e 38 px); la barra di «Registra» usciva di 8 px | `NavigationRail` non scorre | `LayoutBuilder` + `SingleChildScrollView` + `IntrinsicHeight` (`app_shell.dart`) | `sezioni con la colonna di navigazione e i caratteri grandi` |
| Registratore con il testo dal vivo acceso, 768×1024 ×2: «Trascrizione · dal vivo · sul dispositivo» usciva dalla scheda (120 px) | etichetta senza `Flexible` | `Flexible` con puntini (`recorder_screen.dart`) | `scheda della trascrizione dal vivo con i caratteri grandi` |
| Studio → «Nuova sessione», 320 px: menu «Attività» e le sue voci uscivano dal riquadro (63 e 196 px) | `DropdownButtonFormField` non espanso, voce con `Row` rigida | `isExpanded` e `Flexible` (`session_dialog.dart`) | `riquadro «Nuova sessione» in una finestra stretta` |
| Studio → «Ordine dei moduli», 360×640 ×2: riquadro più alto della finestra (130 px) | lista alta il 55% dello schermo in un riquadro non scorrevole | `scrollable: true` e lista al massimo il 40% (`module_order_dialog.dart`) | `riquadro «Ordine dei moduli» in una finestra bassa` |
| Scelta della cartella (OneDrive/Google Drive), 568×320 ×1,3: 4 px | altezza fissa di 420 px | `scrollable` e altezza al massimo metà schermo (`onedrive_card.dart`) | `scelta della cartella in una finestra bassa` |
| Studio → Sessioni, 375 px ×2: la casella dell'intervallo restava con 39,5 px e il suo contenuto fisso ne chiede 40 | `ChoiceBox` con spazio fisso | in uno spazio stretto resta solo la freccia (`study_widgets.dart`) | `casella di scelta in uno spazio strettissimo` |
| Impostazioni → Il mio percorso, 1280 px ×2: «Aggiorna database» e «Indirizzo del database» uscivano di 11 px dai pulsanti | due pulsanti `Expanded` con parole che non si spezzano | stanno su una riga solo se c'è posto per la parola più lunga di ognuno, altrimenti una sotto l'altra (`profile_section.dart`) | `«Il mio percorso» stretto con i caratteri grandi` (non rossa: non riprodotta a riposo) |
| Studio → Sessioni, righe delle sessioni con durate lunghe («1 h 25 min» + cestino) e menu «Tipo del file e altro» degli allegati | `ListTile.trailing` e voci di menu senza limite (assertion «Trailing widget consumes the entire tile width», 19 px) | durata e cestino al massimo il 35% della larghezza con puntini, `Flexible` nelle voci (`sessions_tab.dart`, `attachments.dart`) | `sessioni di studio con i caratteri grandi` (non rossa: le righe lunghe non sono fra quelle costruite) |

Cambi per le prove (non per l'utente): `AppServices(focusTimer: …)` per dare al
Focus un orologio proprio.

**Problemi dell'impianto di prova** (non crash, corretti nell'impianto)
- canale `dev.fluttercommunity.plus/connectivity_status` (`listen`) senza plugin:
  con l'accesso finto alle nuvole partiva la sincronizzazione e
  `connectivity_plus` segnalava un `MissingPluginException` (ora finto);
- timer periodici di sincronizzazione (`CloudDriveService.startAutoSync`) e
  registrazione avviata all'ultimo passo che restavano vivi a fine prova (ora si
  fermano e si aspetta che l'avvio in corso finisca);
- il pulsante grande del registratore non ha testo né chiave: si trova dall'icona
  (`tapIcon`); le etichette cercate salgono fino a 30 livelli di antenati.

**Asserzioni di Flutter** (solo in debug, pila senza codice dell'app; contate a
parte dalla prova, vedi il filtro in `runMonkey`), oltre a quelle del quarto
giro: `InputDatePickerFormField` che riscrive il suo campo in
`didChangeDependencies` mentre il tema o i caratteri cambiano (selettore della
data a testo); barra di selezione del testo («Seleziona tutto», «Copia») con
`RenderFollowerLayer` e con `size == theater.size` in
`OverlayPortal.overlayChildLayoutBuilder`; albero semantico con un `!` nullo in
`_updateSemanticsNodeGeometry` e con `offset.isFinite` (lettore di schermo
acceso, solo dopo molte navigazioni); `SnackBar` mobile fuori schermo in una
finestra alta 320 px.

**Sospetti non spiegati**: dopo un ridimensionamento in mezzo ad altre azioni,
con la finestra larga e i caratteri ×2, la prova ha segnalato (ogni 10-20 mila
azioni nelle sezioni File e Libri) «Trailing widget consumes the entire tile
width» e overflow di pagine schiacciate in 80-95 px. L'albero dei vincoli mostra
che la schermata è costruita con le misure nuove (colonna di navigazione larga
280 px) ma disposta con quelle della finestra di prima (375×812): la
disposizione non ha ancora il vincolo nuovo. Con un ridimensionamento isolato
(300 cambi di finestra, caratteri e tema consecutivi) non si riproduce mai, e
l'app non decide la disposizione dal vincolo ma da `MediaQuery`: è stato
classificato come fotogramma di flutter_test (`staleWindowConstraints`) e
contato a parte («errori noti di Flutter»). Non confermato come errore
dell'app; se si ripresenta fuori dalla prova, il resoconto della prova ha già
l'albero dei vincoli.

**Spiegazione (25/10, sezioni persistenti)**: con le sezioni principali che
restano vive nascoste (`SectionStack`, vedi `personalizzazione.md`) il caso
si è ripresentato più spesso (Esami → Medie nascosta) e l'albero dei vincoli
l'ha chiarito: la shell era coperta da un'altra pagina (registrazione aperta)
quando la finestra è cambiata. L'`Overlay` non dispone le pagine coperte, che
restano con le misure di prima ma si ricostruiscono con il `MediaQuery` nuovo;
un pezzo che si ridispone da solo (elenco, scheda) usa allora i vincoli vecchi
con i widget nuovi. Sono solo asserzioni di debug in una pagina che non si
disegna: quando torna in cima si ridispone tutta con le misure giuste. La prova
ora riconosce anche questo caso (`staleWindowConstraints`: la pagina sopra
l'errore, figlia dell'`Overlay`, ha vincoli diversi dalla finestra) e lo conta
fra gli errori noti.

**Esito del giro finale** (dopo l'ultima correzione): per ogni scenario nuovo
sei semi da 5000 azioni (Studio otto), finestre da 320×568 a 1920×1080, caratteri
×1, ×1,3 e ×2, tema chiaro e scuro, semi dispari con il lettore di schermo
acceso, senza errori e senza overflow:

| Scenario | Semi × azioni | Azioni | Errori | Overflow |
| --- | --- | --- | --- | --- |
| `onboarding` | 6 × 5000 | 30.000 | 0 | 0 |
| `cambio_corso` | 6 × 5000 | 30.000 | 0 | 0 |
| `impostazioni` | 6 × 5000 | 30.000 | 0 | 0 |
| `collegamenti` | 6 × 5000 | 30.000 | 0 | 0 |
| `lettore` | 6 × 5000 | 30.000 | 0 | 0 |
| `registratore` | 6 × 5000 | 30.000 | 0 | 0 |
| `studio` | 8 × 5000 | 40.000 | 0 | 0 |
| `esami` | 6 × 5000 | 30.000 | 0 | 0 |
| `libri` | 6 × 5000 | 30.000 | 0 | 0 |

In tutto 280.000 azioni; nei giri di ricerca prima delle correzioni ne sono state
fatte circa altrettante. Le asserzioni di Flutter elencate sopra sono contate a
parte e non fermano la prova. Suite completa: 1634 superati, 4 saltati, 0 falliti.
