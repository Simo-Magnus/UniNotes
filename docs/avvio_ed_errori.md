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
