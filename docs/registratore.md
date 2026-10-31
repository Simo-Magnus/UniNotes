# Registratore delle lezioni

Il registratore (sezione **Registra**) funziona come l'app Memo Vocali di
iOS, con la trascrizione dal vivo come la registrazione audio nell'app Note.
Tutto avviene sul dispositivo: l'audio e il testo non lasciano il telefono o
il PC finché non scegli di sincronizzarli o di mandarli a Gemini.

Nella pagina **Registra** gli insegnamenti sono divisi come in Studio: **1°
semestre**, **2° semestre**, **Annuale** e **OFA** (con l'anno davanti se
il percorso ne mostra più d'uno), ognuno solo con il suo nome
(`groupStudyCourses` in `app/lib/features/study/course_groups.dart`).
Sotto l'insegnamento c'è **Lingua della lezione: Italiano | Inglese**
(vedi «Lingua delle lezioni» più sotto): si cambia prima di registrare e
durante la registrazione si vede ma resta fissa.

Codice: `app/lib/features/notes/` (`lecture_recorder.dart`,
`recorder_screen.dart`, `recording_player_screen.dart`,
`recently_deleted_screen.dart`, `transcript_search_screen.dart`,
`recycle_bin.dart`, `course_notes_screen.dart`, `lesson_transcripts.dart`,
`spell_check.dart`) e `app/lib/features/notes/recorder/` (WAV, trascrizione
dal vivo con `live_transcriber.dart`, modifica del testo con
`live_transcript_editor.dart`, proposta di una trascrizione più accurata con
`better_transcription.dart`, salvataggio, riquadro sopra le schermate,
controlli in background, `vad_segmenter.dart` e `second_pass.dart`, vocabolario
del corso `course_vocabulary.dart`, lingua delle lezioni
`lecture_language.dart` e `speech_language.dart`). Parakeet: `app/lib/core/services/parakeet_service.dart`,
`parakeet_engine.dart`, `whisper_prompt.dart` e `app/lib/features/links/parakeet_model.dart`
(test `parakeet_live_test.dart`, `parakeet_service_test.dart`,
`second_pass_test.dart`, `whisper_prompt_test.dart` e, con il modello vero,
`parakeet_real_test.dart`). Riconoscimento vocale del sistema (testo
istantaneo sul telefono, vedi sotto): `system_speech.dart`,
`app/android/.../LiveSpeech.kt`, `app/ios/Runner/LiveSpeech.swift` (uguale in
`app/macos/Runner/`), `app/windows/runner/live_speech.cpp`. Controllo
ortografico: `app/windows/runner/spell_check.cpp`, `UniNotesSpellCheck` in
`app/macos/Runner/MainFlutterWindow.swift`. Conversioni
audio: `app/lib/core/services/audio_codec.dart` e, su Windows,
`app/windows/runner/audio_transcoder.cpp`. Test:
`app/test/recorder_logic_test.dart`, `app/test/recorder_speech_test.dart`,
`app/test/recording_overlay_test.dart`, `app/test/live_transcript_edit_test.dart`,
`app/test/better_transcription_test.dart`, `app/test/spell_check_test.dart`,
`app/test/recorder_language_test.dart` (lingua, Mac con macOS 26, maiuscole) e
`app/test/share_files_test.dart`; formule a voce
`app/lib/features/notes/spoken_math.dart` (`app/test/spoken_math_test.dart`);
scelta e consiglio dei modelli Whisper `app/lib/features/links/whisper_device.dart`
e `app/lib/core/services/whisper_service.dart` (`app/test/whisper_choice_test.dart`).

## Mentre registri

- **Tempo** e **forma d'onda** in tempo reale (livello calcolato dall'audio,
  10 valori al secondo).
- **Pausa / Riprendi**: il pulsante grande.
- **Segna**: segnalibro al tempo attuale; dall'avviso «Aggiungi nota» si
  scrive una nota facoltativa (l'avviso funziona anche se nel frattempo si è
  usciti dal registratore). I segnalibri compaiono sotto i pulsanti (tocco →
  nota o rimozione).
- **Trascrizione**: la card mostra il parlato trascritto **istantaneamente**,
  come Memo Vocali: il testo provvisorio (più chiaro) si aggiorna mentre si
  parla e diventa definitivo a ogni frase. Su **PC e Mac** lo fa
  **Parakeet** (NVIDIA, offline, frasi guidate dalle pause); sul
  **telefono** il **riconoscitore del sistema** (Google/Apple sul
  dispositivo) con Whisper integrato come ripiego e, dove il telefono
  regge, la seconda passata con small. Vedi [Trascrizione dal
  vivo](#trascrizione-dal-vivo). La registrazione funziona sempre, anche
  senza testo.
- **Modifica del testo**: come nel Blocco note, vedi [Modificare il testo
  mentre si registra](#modificare-il-testo-mentre-si-registra).
- **Elimina** (sotto i pulsanti, in rosso): ferma la registrazione e la
  sposta, con la trascrizione fin lì, in **«Eliminati di recente»**, dove si
  recupera per 30 giorni. Prima chiede «Eliminare la registrazione?» con
  Annulla, Elimina e la casella «Non chiedere più» (la stessa conferma del
  cestino della pagina del corso, impostazione `dont_ask_delete_recording`,
  si ripristina da Impostazioni → «Ripristina le domande»).
- **Salva**: ferma, salva e porta alla **pagina del corso**, alla card
  «Registrazioni delle lezioni» (la registrazione nuova è evidenziata), non
  al lettore. Se è stato scaricato un modello Whisper più accurato compare
  la proposta di trascrivere di nuovo (vedi [Dopo il salvataggio: una
  trascrizione più accurata](#dopo-il-salvataggio-una-trascrizione-più-accurata)).

### Uscire durante la registrazione

Non c'è più la domanda «salvare o no» quando si esce. Uscendo dal
registratore (indietro, cambio sezione, Home) la registrazione continua e
compare **subito** (già mentre la pagina si chiude, anche con il gesto
Indietro) un **riquadro sopra tutte le schermate** dell'app: pallino rosso
che pulsa, nome del corso, tempo, livello del microfono, **Pausa/Riprendi**,
**Salva** e **X**. Il riquadro:

- **segue il dito alla stessa velocità**: usa i movimenti grezzi del
  puntatore, senza soglia iniziale né animazioni, e si ridisegna solo la sua
  posizione; resta dentro lo schermo, nelle aree sicure e sopra la barra in
  basso;
- si **allarga o stringe** con la maniglia a destra (area di tocco di
  24 px), fino alla larghezza minima in cui i tre pulsanti restano visibili
  (il testo si accorcia, l'indicatore del microfono sparisce). Il gesto è
  diretto: la larghezza segue lo spostamento totale del dito dall'inizio
  (la maniglia resta sotto il dito, niente accumulo di piccoli passi), si
  ridisegna solo il riquadro (`ValueNotifier` della larghezza e
  `RepaintBoundary`, nessun `setState` sopra l'app); un **gesto veloce**
  (oltre 900 px/s) lo porta subito alla larghezza minima o massima con
  un'animazione di 160 ms, il **doppio tocco** sulla maniglia passa
  dall'una all'altra; con «Riduci animazioni» il cambio è immediato. Vale
  anche per il riquadro della sessione Focus (stesso gruppo);
- ha un **fondo scuro quasi opaco** (chiaro nel tema chiaro), leggibile
  anche sopra altri testi;
- un tocco riporta al registratore.

Solo la **X** chiede «Salvare la registrazione?» con due pulsanti, Elimina
(con una seconda conferma, in rosso) e Salva; toccando fuori dal dialogo la
registrazione continua. La conferma «Eliminare la registrazione?» (anche
dal cestino della pagina del corso e del lettore) ha Annulla, Elimina e la
casella **«Non chiedere più»**: spuntata, le eliminazioni successive vanno
subito in «Eliminati di recente» (sempre recuperabili per 30 giorni). La
scelta è l'impostazione `dont_ask_delete_recording` e si annulla da
Impostazioni → «Ripristina le domande» (cancella tutte le chiavi
`dont_ask_`). Dopo «Salva» dal riquadro, l'avviso «Apri» porta
alla pagina del corso.

Perché prima su Android il riquadro compariva solo al primo tocco: la pagina
del registratore si chiudeva a metà di un fotogramma e l'avviso «schermata
chiusa» arrivava quando un rebuild non chiede un fotogramma nuovo. Ora il
riquadro si ricostruisce a fotogramma finito chiedendone subito un altro
(`LectureRecorder.screenVisible`, `RecordingOverlayHost._changed`).

Il riquadro è lo stesso della sessione Focus (`widgets/floating_pill.dart`,
vedi [focus.md](focus.md)): con una registrazione e una sessione Focus in
corso i due riquadri stanno uno sotto l'altro e si trascinano insieme. Inizio
e fine della registrazione hanno un segnale breve e una vibrazione
(Impostazioni → Suoni e vibrazioni): quello di fine parte dopo lo stop e non
finisce nell'audio; quello d'inizio dura 0,16 s e parte mentre si apre il
microfono, quindi al massimo se ne sente un accenno nei primi istanti.

- **Android**: «Indietro» dalla Home con una registrazione in corso manda
  l'app in background senza fermarla.
- **PC (Windows, macOS)**: chiudendo la finestra l'app si riduce nell'area
  di notifica e continua a registrare, con una notifica che lo dice. Dal
  menu dell'icona: Apri, Pausa/Riprendi, Salva la registrazione, Esci. «Esci»
  con una registrazione in corso chiede Salva / Elimina / Annulla; se è il
  sistema a chiudere l'app (spegnimento) la registrazione si salva.

### Con l'app in background (telefono)

- **Android**: la notifica del servizio in primo piano mostra corso e tempo
  (aggiornato ogni secondo) con i pulsanti **Pausa/Riprendi** e **Salva**;
  il tocco apre il registratore. I pulsanti funzionano anche ad app in
  background: il servizio (isolate separato di `flutter_foreground_task`)
  passa il comando all'app.
- **Android, widget «Registra lezione»**: un tocco avvia la registrazione
  (stesso percorso del pulsante «Registra») e riporta alla schermata Home;
  poi il widget mostra il tempo con Pausa/Riprendi, Salva ed Elimina (con
  il secondo tocco di conferma, poi in «Eliminati di recente»). Lo stato è
  quello della notifica. Vedi [widget.md](widget.md#registra-lezione-avvio-con-un-tocco).
- **iOS**: la registrazione continua in background (`UIBackgroundModes`
  `audio` nell'Info.plist); durante una telefonata va in pausa. La **Live
  Activity** (schermata di blocco e Dynamic Island, con cronometro e, da
  iOS 17, i pulsanti Pausa/Riprendi e Salva) richiede un'estensione da
  aggiungere in Xcode: vedi [widget.md](widget.md#live-activity-della-registrazione-ios).

## Nessun audio perso

L'audio arriva dal microfono come PCM 16 bit, 16 kHz mono
(`AudioRecorder.startStream` del pacchetto `record`, flusso PCM supportato su
Android, iOS, macOS e Windows) e viene scritto man mano in un **WAV di
lavoro** nella cartella di supporto dell'app (`registrazioni_in_corso/`),
con accanto un file `.json` (corso, dove salvarla, segnalibri, testo
trascritto). L'intestazione del WAV si aggiorna a ogni pausa, a ogni stop e
ogni 5 secondi di audio, e si ricostruisce dalla lunghezza del file.

Se l'app si chiude di colpo (crash, batteria, sistema), al riavvio compare
«Registrazione da recuperare» con corso, ora d'inizio e durata: **Salva**
ripara il WAV e lo salva come le altre registrazioni, **Elimina** (con
conferma) lo sposta in «Eliminati di recente»; toccando fuori dal dialogo lo
si lascia dov'è e si decide più tardi.

Casi difficili (controllati il 22/10/2026, test in
`test/recorder_crash_test.dart`):

- **microfono occupato o negato** all'avvio: messaggio chiaro, nessun file di
  lavoro; un doppio tocco su «Registra» avvia una sola registrazione;
- **il sistema chiude il microfono** durante la registrazione (altra app,
  dispositivo scollegato) o **non riparte dopo una pausa** (telefonata su
  iOS): la registrazione va in pausa con il motivo sotto il tempo e si salva
  con «Salva» (l'audio fin lì resta);
- **disco pieno**: pausa con il motivo; fermare e salvare funzionano lo
  stesso (i dati in memoria vanno nel salvataggio);
- **oltre 4 GB** (il limite del formato WAV, ~37 ore a 16 kHz mono)
  l'intestazione resta al massimo invece di ricominciare da zero (prima un
  recupero avrebbe tagliato il file) e la registrazione si ferma lì;
- doppio «Salva» (schermata, riquadro, notifica): una sola registrazione;
- i dati di lavoro (`.json`), quelli accanto all'audio e `info.json` del
  cestino si scrivono in `<file>.part` e poi si rinominano sopra il file, uno
  alla volta (`lib/features/notes/safe_files.dart`); se l'app si chiude
  proprio lì il recupero usa la copia `.part`;
- l'audio salvato si segna subito nei dati di lavoro: un errore dopo
  (trascrizione, dati) non produce un doppione al riavvio, e i segnalibri
  non scritti si rifanno da quelli della sessione;
- un `.m4a` molto più piccolo del previsto (codificatore fermato a metà) non
  fa cancellare il WAV: si tiene il WAV;
- «Elimina» con il cestino irraggiungibile lascia l'audio nel WAV di
  lavoro; lo spostamento nel cestino rimette a posto i file già spostati se
  uno non si sposta (copia in `.part` fra unità diverse, mai un file a metà).

## Trascrizione dal vivo

Chi fa il testo istantaneo dipende dal sistema. La scelta è in **un punto
solo**, `liveEngineOrder` in `app/lib/features/notes/recorder/live_transcriber.dart`
(ogni motore che non può partire passa al successivo), fissata da un test
(`app/test/parakeet_live_test.dart`, «scelta del motore per piattaforma», e
`app/test/recorder_logic_test.dart`, «motore dal vivo per piattaforma»):

| Sistema | 1° motore | Ripiego | In più |
|---|---|---|---|
| **macOS 26 o successivo** | **riconoscitore nuovo di Apple** (SpeechAnalyzer + SpeechTranscriber, sul Mac, nella lingua della lezione) | **Parakeet** se il modello della lingua non è ancora sul Mac (si scarica in background per la volta dopo), la lingua manca, il permesso è negato, non risponde all'avvio entro 45 s o si ferma a metà (Parakeet continua da lì); poi Whisper (small q5_1 incluso nell'app o un modello scaricato) | — |
| **Windows, Linux, macOS fino al 15** | **Parakeet** (NVIDIA Parakeet TDT 0.6B v3 con sherpa-onnx) | Whisper a pezzi da ~10 s: **small q5_1 incluso nell'app** (dal 24/10/2026) o un modello scaricato più adatto; senza nessuno dei due nessun testo | frasi fuori lingua ritrascritte con Whisper small incluso (vedi «Lingua della trascrizione» e «Whisper small incluso su PC e Mac») |
| **Android, iOS** | **riconoscitore del sistema** (Google/Apple, sul dispositivo dove c'è) | Whisper base q5_1 integrato, se il riconoscitore manca, non ha la lingua, si ferma o non risponde all'avvio entro 45 s | seconda passata con small q5_1 solo con Whisper base, dove il telefono regge |

Un riconoscitore che non risponde all'avvio (iOS 26 che scarica il modello
della lingua senza rete, dettatura di Windows che non finisce di
prepararsi) non lascia più il testo dal vivo «in avvio» per tutta la
lezione: dopo 45 s (`SystemSpeech.kStartTimeout`) la sessione si chiude,
gli eventi che arrivassero dopo si scartano e si passa al motore
successivo, che riparte dall'inizio del WAV di lavoro (test in
`app/test/crash_r2_nativo_test.dart`).

Lingua: sempre fissata, **italiano** o **inglese**, quella scelta
nell'onboarding o in Registra (vedi «Lingua delle lezioni» sotto), mai il
rilevamento automatico né altre lingue. Nessun motore apre il
microfono per conto suo: ricevono l'audio della registrazione (o lo leggono
dal WAV di lavoro), e un loro errore non ferma mai la registrazione.

### Parole stabili confermate subito (22/10/2026)

Prima il testo diventava modificabile solo a fine frase: con Parakeet alla
pausa (o dopo 18 s di parlato continuo), con il riconoscitore del sistema
quando lui chiudeva la frase, con Whisper a fine finestra (fino a 6 s). Si
vedeva un lungo blocco grigio che poi veniva «incollato» tutto insieme.

Ora vale la **conferma per accordo** (LocalAgreement-2, come
whisper_streaming di Macháček, Dabre e Bojar, 2023;
`app/lib/features/notes/recorder/live_agreement.dart`, logica pura): a ogni
nuova decodifica del tratto in corso (Parakeet ogni ~0,75 s, il
riconoscitore del sistema a ogni testo provvisorio, Whisper ogni ~2 s) le
parole iniziali **uguali nelle ultime due decodifiche** diventano subito
confermate ed entrano nella trascrizione come il resto: si modificano, si
salvano, hanno i loro tempi. In grigio resta solo la coda ancora incerta.
Con Parakeet una parola detta è modificabile **~1–2 s dopo** (due
decodifiche a 0,75 s l'una dall'altra, più ~0,2–0,3 s di calcolo).

Misura (22/10/2026, Parakeet vero dell'app installata, 17 frasi di FLEURS
dev in italiano, 255 s, a pezzi da 100 ms): **311 parole su 366** confermate
per accordo prima della fine della frase, **1,15 s di mediana** dalla fine
della parola (90%: 2,0 s), più il calcolo di un'ipotesi (0,24 s di mediana,
90%: 0,49 s); prima, con il testo modificabile solo a fine frase, 3,5 s di
mediana e 7,8 s al 90%.

- **Fine frase**: il testo definitivo del motore (Parakeet con tutto
  l'audio della frase, il risultato del riconoscitore del sistema, la
  finestra definitiva di Whisper) sostituisce le parole confermate:
  punteggiatura, maiuscole e parole corrette, diviso in frasi con i loro
  tempi. La prima frase tiene la sua chiave (inizio in ms), così nel campo
  di modifica cambia al suo posto.
- **Frasi corrette a mano**: non si toccano mai. Le parole nuove vanno in
  una frase nuova dopo; a fine frase le parole del testo definitivo che
  corrispondono a quelle già corrette si scartano (niente doppioni).
- **Correzioni del riconoscitore** (Android e iOS a volte riscrivono parole
  già dette): una parola confermata cambia solo se la stessa correzione
  arriva in due testi provvisori di fila e la frase non è stata corretta a
  mano; il resto si sistema a fine frase. Se il riconoscitore riparte da
  capo (il testo nuovo non contiene più le parole confermate, es. iOS dopo
  una pausa) la frase si chiude com'è e ne inizia una nuova.
- **Frasi lunghissime senza pause**: le parole si confermano man mano; dopo
  un punto si apre un segmento nuovo, così non resta un unico blocco.
- **Whisper con la finestra piena**: l'ultima frase resta provvisoria e le
  sue parole già confermate passano alla finestra dopo (si allineano, non
  si ripetono). Il modello Whisper pesante (ripiego su PC, pezzi da 9 s
  definitivi subito) non ridecodifica: lì il testo arriva a pezzi come
  prima.
- **Fine registrazione a metà frase**: il tratto si ritrascrive dopo il
  salvataggio («Completo la trascrizione») e il risultato sostituisce le
  parole confermate. Se il PC resta indietro e un tratto si salta, le parole
  confermate restano e il recupero parte da dopo di loro.
- **Seconda passata** (telefono, solo con Whisper base): lavora solo sulle
  frasi chiuse, prima della frase in corso; **formule** e controllo
  ortografico come prima.
- Il file della sessione si salva al massimo ogni ~3 s mentre le parole si
  confermano (subito a fine frase).
- Nel campo di modifica le parole confermate si aggiungono in fondo alla
  frase in corso: se il cursore era lì resta dov'è.

Test: `app/test/live_agreement_test.dart` (ipotesi che cambiano,
correzioni, frasi corrette a mano, ripartenze, frasi lunghissime, finestra
piena di Whisper, Parakeet finto con la fine frase, la fine della
registrazione e le frasi in un'altra lingua), `app/test/recorder_speech_test.dart`
(riconoscitore del sistema che riscrive le parole).

### Maiuscole a inizio pezzo (24/10/2026)

Il riconoscitore del telefono restituisce ogni pezzo con la maiuscola anche quando continua la frase di
prima («oggi parliamo Di integrali»), e lo stesso fanno il riconoscitore di Apple sul Mac, Parakeet
quando il VAD taglia a una pausa a metà frase e Whisper all'inizio di ogni finestra o blocco. Se il
testo precedente non finisce con `.`, `!`, `?` o `…` l'iniziale torna minuscola. Restano maiuscoli i
nomi propri noti (parole del vocabolario dell'insegnamento che non sono la prima del loro nome, per
esempio «Lagrange» in «Teorema di Lagrange», e parole già viste con la maiuscola a metà frase nella
stessa lezione), le sigle e le parole con maiuscole interne («PDF», «UniNotes») e «I» nelle lezioni in
inglese. Le frasi già corrette a mano non si toccano.

Dove si applica (`TranscriptMerger` in `live_transcript.dart`):

| Testo | Come |
|---|---|
| pezzi uniti (`merger.add`: finestre di Whisper, frasi definitive senza parole confermate, tratti recuperati, frasi ritrascritte con Whisper) | in `add`, come prima |
| parole confermate per accordo e testo definitivo di fine frase (riconoscitore del sistema e di Apple, Parakeet, Whisper) | `merger.recase` sulle ultime frasi a ogni cambiamento (`LiveTranscriber._segmentsChanged`) |
| seconda passata con small (telefono) | `recase` dal blocco sostituito in poi |
| trascrizione salvata e «Completo la trascrizione» | sono le frasi qui sopra (`live.segments`) |
| «Trascrivi con…» / «Trascrivi di nuovo con…» dopo il salvataggio, anche quella «più accurata» proposta da `better_transcription.dart` (Whisper e Parakeet) | `TranscriptMerger.recaseTexts` sui segmenti prima di scriverli (`notes_actions.dart`), con il vocabolario dell'insegnamento come nomi propri |

Test: `test/live_transcript_case_test.dart` (unione dei pezzi), `test/recorder_language_test.dart`
(riconoscitore del sistema con parole confermate e testo definitivo, Parakeet con una pausa a metà
frase, trascrizione dopo il salvataggio).

### Lingua delle lezioni (24/10/2026)

La lingua della trascrizione la sceglie lo studente, **italiano** o
**inglese** (`recorder/lecture_language.dart`):

- **onboarding**, dopo l'AI di riferimento: «In che lingua sono le tue
  lezioni?» («Scegli la lingua della maggior parte delle lezioni che
  registrerai…»), due opzioni, **Italiano** e **Inglese**; un tocco salva
  (`lecture_language`) e va avanti. Chi ha fatto l'onboarding prima ha
  l'italiano, o l'inglese per gli insegnamenti seguiti in inglese;
- **Registra**, sotto l'insegnamento: «Lingua della lezione: Italiano |
  Inglese», prima di registrare; la scelta resta per quell'insegnamento
  (`lecture_language_course_<id>`). Ordine: scelta per l'insegnamento →
  insegnamento seguito in inglese (`Course.examLanguage`) → lingua
  dell'onboarding → italiano (`pickLectureLanguage`);
- la lingua si salva con la registrazione (`lingua` nel `.json` accanto,
  `RecordingMeta.language`) e la usano «Completo la trascrizione», la
  trascrizione più accurata proposta dopo il salvataggio e «Trascrivi
  con…» (che la mostra già scelta e permette di cambiarla).

Nelle Impostazioni non c'è un posto per la lingua (non c'era nemmeno
prima): si cambia dove serve, in Registra.

### Lingua della trascrizione (22/10/2026, aggiornato il 24/10)

La lingua è sempre quella della lezione (sopra). Mai il rilevamento
automatico (`lectureLanguage`, `speech_language.dart`). Il risultato deve
contenere solo parole di quella lingua, salvo nomi propri e termini
tecnico-scientifici.

- **Whisper** (whisper-cli e whisper.cpp nell'app, dal vivo, seconda
  passata e file): `-l it`/`-l en` (`WhisperOptions.cliArgs`,
  `language` del plugin): il modello scrive nella lingua fissata.
- **Riconoscitore del sistema** (telefono) e **di Apple** (Mac con macOS
  26): `it-IT` o `en-US` (`speechLocaleFor`), modelli di una sola lingua.
- **Parakeet** (NVIDIA Parakeet TDT 0.6B v3) riconosce da solo la lingua
  fra 25 lingue europee e sherpa-onnx **non permette di fissarla** (le
  opzioni di lingua esistono solo per Whisper, SenseVoice e Canary); gli
  hotwords non cambiano il testo (provato il 21/10, vedi «Parakeet su PC e
  Mac»). Ogni frase di Parakeet (dal vivo, testo provvisorio compreso, e
  «Trascrivi con Parakeet») passa da `outsideLecture(frase, lecture:)`: se
  **la frase intera** è in un'altra lingua (dal 24/10 anche l'**inglese in
  una lezione in italiano** e l'**italiano in una lezione in inglese**,
  oltre a spagnolo, portoghese, francese, tedesco, olandese, rumeno,
  polacco e alfabeti diversi) o, in italiano, è solo un intercalare inglese
  del rumore («Thank you», «Yeah»…), non entra nella trascrizione: quel
  tratto si **ritrascrive con Whisper fissato sulla lingua della lezione**
  (dal vivo e in «Trascrivi con Parakeet»), con **Whisper small q5_1
  incluso nell'app** (dal 24/10/2026, vedi «Whisper small incluso su PC e
  Mac») o con un modello scaricato più adatto (`WhisperService.liveEngine`).
  Solo in una build senza il modello incluso e senza modelli scaricati si
  toglie, e la card «Trascrizione» lo dice. Le frasi corte o incerte
  restano.

**Come decide** `outsideLecture`: conta le parole funzionali tipiche di ogni
lingua (articoli, preposizioni, pronomi, ausiliari: «the», «and», «you»,
«il», «che», «sono», «que», «não»…), le lettere che l'italiano e
l'inglese non usano («ñ», «ã», «í»…) e le finali che l'italiano non ha
(«-ção», «-dade», «-ción», «-ung»…). Le parole uguali in italiano e in
inglese («a», «in», «so», «me», «all'») non contano. La frase è fuori
lingua se l'altra lingua ha almeno due indizi e più di 1,5 volte (+1)
quelli della lingua della lezione. Si guarda la frase intera e non la
singola parola apposta: i termini tecnici inglesi sono parole piene
(«dataset», «training set», «gradient descent», «customer journey»),
quasi mai parole funzionali, e restano; i nomi italiani in una lezione in
inglese («Leonardo da Vinci», «University of Bologna») anche.

**Misure** (24/10/2026, Parakeet vero int8 di sherpa-onnx 1.13.8 su questo
PC, a frasi come il testo definitivo; script in `bench/bin/lang.dart`,
`whisper_lang.dart` e `detect_eval.dart` nella cartella di lavoro
dell'agente, non nel repository). Audio: 17 frasi vere in italiano di
FLEURS (230 s, voci diverse), 16 frasi di lezione in italiano con termini
tecnici inglesi (voce Elsa di Windows) e 16 frasi di lezione in inglese con
nomi italiani (voci Zira e Hazel), ognuna pulita e con un «microfono
lontano» simulato (riverbero, guadagno basso e rumore di fondo):
«lontano» = riverbero 0,5 s e 10 dB di rapporto segnale/rumore, «molto
lontano» = 0,7 s e 6 dB, «in fondo all'aula» = 0,9 s e 3 dB.

| Audio | WER di Parakeet (FLEURS · Elsa · Zira · Hazel) | Frasi tolte da `outsideLecture` |
|---|---|---|
| pulito | 4,7% · 5,8% · 2,7% · 2,7% | 0 su 74 |
| lontano | 13,4% · 18,8% · 3,8% · 5,4% | 0 su 77 |
| molto lontano | 42,4% · 35,1% · 5,9% · 17,3% | 2 su 80 (tutte e due davvero in inglese) |
| in fondo all'aula | 80,4% · 59,6% · 20,0% · 42,7% | 10 su 82 (9 frasi inglesi e 1 portoghese uscite da audio italiano) |

- Parakeet sbaglia lingua **solo quando l'audio è cattivo**: con l'audio
  pulito o lontano nessuna frase in un'altra lingua (le frasi inglesi
  restano inglesi, quelle italiane con i termini tecnici restano
  italiane: nessuna frase giusta tolta); in fondo all'aula interi tratti
  di audio italiano diventano frasi inglesi inventate («And I'll show you
  that for any day, but I'm not.», «So I didn't get something about
  it.») o portoghesi. L'audio inglese non è mai uscito in italiano.
- Le frasi miste (qualche parola straniera in una frase italiana,
  «Il m'entend finale ha deviato la victoria di un punto») restano: a quel
  livello di rumore le parole sono sbagliate comunque e una parola
  straniera non si distingue da un termine tecnico. Un controllo parola
  per parola con i dizionari toglierebbe anche i termini tecnici.
- **Whisper fissato sulla lingua** (medium q5_0 scaricato dall'utente,
  `-l it`, 4 thread, con altri test in corso sul PC) sulle stesse frasi di
  FLEURS: 11,8% lontano (Parakeet 13,4%), **31,7%** molto lontano
  (Parakeet 42,4%) e **38,0%** in fondo all'aula (Parakeet 80,4%), sempre
  in italiano; ma lavora 1,9–2,6 s per
  secondo di audio, contro 0,09 di Parakeet: **come motore principale non
  sta al passo** su un PC normale (con large-v3-turbo è peggio ancora). Per
  questo resta il ripiego delle sole frasi fuori lingua.
- **«Ancora»** (metà frase precedente nella lingua giusta messa davanti a
  ogni frase, perché il decodificatore di Parakeet tende a continuare nella
  lingua in cui sta scrivendo): provata e **scartata**: non toglie le frasi
  in un'altra lingua (con l'audio cattivo anche l'ancora è cattiva), il WER
  cambia di poco in meglio o in peggio (es. FLEURS lontano 13,4% → 11,0%,
  Zira pulito 2,7% → 10,3%, parole tagliate al confine) e il calcolo
  cresce del 20–65%.

Fatto il 24/10/2026, su decisione dell'utente: le build desktop includono
**Whisper small q5_1** (181 MiB; il base q5_1, 57 MiB, incluso fino al
21/10, è molto meno preciso), così le frasi fuori lingua si ritrascrivono
sempre, anche senza un modello scaricato (vedi «Whisper small incluso su
PC e Mac»). Resta solo da valutare, con l'approvazione dell'utente, NVIDIA
Canary-1B v2 (stessa famiglia di Parakeet, 25 lingue, la lingua si indica;
circa 1 miliardo di parametri, più lento), se ne esiste una versione per
sherpa-onnx, che per i modelli Canary permette di fissare la lingua.

### Perché sul telefono era peggiorata (21/10/2026)

Fino alla build f029f732 (19/10) sul telefono il testo dal vivo veniva dal
riconoscitore del sistema (`SystemSpeech`, Google/Apple sul dispositivo) e,
prima ancora (a51efa8d), dal modello scaricato dall'utente a pezzi da
~10 s. Con bea7d53f (21/10) `LectureRecorder` non creava più
`SystemSpeech()` per nessun sistema (la modifica serviva a Windows, dove con
«Riconoscimento vocale online» il testo non arrivava): sul telefono il
testo dal vivo è passato a Whisper base q5_1 con finestre da 2 s senza
contesto, molto meno preciso, e il testo salvato era quello. Audio,
whisper_ggml (2.7.1) e impostazioni del microfono non erano cambiati. Ora
`LectureRecorder` passa di nuovo `SystemSpeech()` su Android e iOS (solo
lì), con lo stesso codice nativo di allora (`LiveSpeech.kt`, `LiveSpeech.swift`:
riavvio del riconoscitore dopo le pause, Android 13+ con l'audio da una
pipe, `it-IT`, riconoscimento sul dispositivo dove c'è, permessi invariati);
la card torna a spiegare perché il riconoscitore non trascrive (lingua,
permesso) mentre lavora Whisper. Su PC il riconoscitore del sistema resta
spento; sul Mac si usa da macOS 26, solo quello nuovo (vedi «Mac con
macOS 26»).

### Che cosa succede con ogni combinazione

| Situazione | Testo istantaneo durante la registrazione | Dopo «Salva» |
|---|---|---|
| PC/Mac (Parakeet incluso nell'app) | Parakeet, subito | niente da proporre, salvo un modello Whisper scaricato più accurato (large): riquadro «Trascrivere di nuovo con …?» |
| PC/Mac, build senza il modello incluso (fatta a mano): prima registrazione | barra «Scarico Parakeet…» con «Annulla»; la registrazione va, l'audio si tiene | «Completo la trascrizione» aspetta la fine del download e trascrive tutto con Parakeet |
| PC/Mac senza modello incluso, download annullato o non riuscito | Whisper small incluso (o il modello scaricato) a pezzi, altrimenti nessun testo (la card spiega come averlo) | «Trascrivi con…» Parakeet (riprende il download dalla card) o Whisper |
| PC/Mac con meno di 4 GB di RAM | Whisper small incluso (o il modello scaricato) a pezzi, altrimenti nessun testo; la card dice perché | «Trascrivi con…» Whisper small incluso, un modello scaricato o Gemini |
| PC/Mac, Parakeet si ferma a metà (errore) | si continua con Whisper (small incluso o scaricato) dal punto in cui il testo era definitivo, altrimenti «Trascrizione dal vivo interrotta» | i tratti mancanti si recuperano |
| PC/Mac, frase di Parakeet in un'altra lingua | il tratto si ritrascrive con Whisper small incluso (o un modello scaricato più adatto) nella lingua della lezione | lo stesso in «Trascrivi con Parakeet» |
| Mac con macOS 26 e il modello della lingua di Apple | riconoscitore di Apple, sul Mac; se si ferma, Parakeet da lì | riquadro se c'è un modello scaricato più accurato di small |
| Mac con macOS 26, modello della lingua non ancora scaricato | Parakeet (la card lo dice; il modello di Apple si scarica in background per la volta dopo) | come PC/Mac |
| Telefono con il riconoscitore del sistema | riconoscitore del sistema (niente seconda passata) | riquadro se c'è un modello scaricato più accurato di small |
| Telefono senza riconoscitore (Android < 13, lingua mancante) o che si ferma | Whisper integrato (+ small dove regge) | riquadro se c'è un modello scaricato più accurato |
| Nessun motore | nessun testo, la registrazione va avanti | «Trascrivi con…» o Gemini dalla pagina del corso |

I tempi dei segmenti sono quelli della registrazione. Alla fine («Salva») il
tratto ancora provvisorio e quelli saltati si completano in background
(«Completo la trascrizione», visibile nella card della registrazione).

### Mac con macOS 26: il riconoscitore di Apple (24/10/2026)

Da macOS 26 il testo dal vivo sul Mac lo fa il **riconoscitore nuovo di
Apple** (SpeechAnalyzer con SpeechTranscriber, lo stesso di Note e Memo
Vocali), sul Mac e nella lingua della lezione: un modello per una sola
lingua, quindi niente parole di altre lingue (il problema di Parakeet,
vedi sotto). Parakeet resta il ripiego. Codice: `liveEngineOrder(appleSpeech:)`
e `LiveTranscriber._beginSystem` (`live_transcriber.dart`),
`macAppleSpeech`/`macOSMajor` (`system_speech.dart`, dalla versione di
`Platform.operatingSystemVersion`), `AnalyzerSpeechEngine` in
`macos/Runner/LiveSpeech.swift` (lo stesso file di iOS).

1. `support` con `prepare: true`: il Mac risponde anche lo stato del
   modello della lingua (`analyzer`: `installed`, `downloading`,
   `unsupported`). Se non è ancora sul Mac parte il download in background
   (`AssetInventory`, una volta sola) e **questa** registrazione la fa
   Parakeet, subito: la card lo dice («Il riconoscitore di Apple sta
   scaricando la lingua della lezione…»). Dalla registrazione dopo
   trascrive Apple.
2. `start` con `analyzerOnly: true`: solo SpeechAnalyzer, mai
   SFSpeechRecognizer (che sul Mac vuole la Dettatura attiva e può usare la
   rete) e nessun download durante l'avvio. Se non parte risponde
   `analyzer` e si passa a Parakeet; se non risponde entro 45 s
   (`SystemSpeech.kStartTimeout`) anche, e il tratto iniziale si trascrive
   con Parakeet dopo il salvataggio.
3. Se Apple si ferma a metà lezione (errore definitivo) il testo fin lì
   resta e **Parakeet continua da quel punto** (`_beginParakeet(fromNow:
   true)`: niente ritrascrizione dell'inizio); se Parakeet non può girare,
   il modello Whisper scaricato.
4. Permesso: la prima volta macOS chiede quello del riconoscimento vocale
   (`NSSpeechRecognitionUsageDescription`, già nell'Info.plist); negato =
   Parakeet, e la card dice dove riabilitarlo.

Etichetta della card: «dal vivo · Apple, sul Mac». macOS fino al 15 e
Windows: come prima (Parakeet, poi Whisper). Test:
`test/recorder_language_test.dart` («Mac con macOS 26»).

### Parakeet su PC e Mac

**Modello**: NVIDIA Parakeet TDT 0.6B v3 (600 M parametri, 25 lingue
europee compreso l'italiano, punteggiatura e maiuscole; licenza
CC BY 4.0, vedi sotto), nella versione ONNX int8 di sherpa-onnx (pacchetto
`sherpa_onnx` 1.13.8, Apache-2.0, ONNX Runtime incluso: ~22 MB di DLL su
Windows). Codice: `core/services/parakeet_service.dart` (download, motore
condiviso), `core/services/parakeet_engine.dart` (isolate con sherpa-onnx),
`features/notes/recorder/vad_segmenter.dart` (logica pura, testata con VAD e
decodificatore finti), `features/links/parakeet_model.dart` (file, pesi,
impronte).

**Consegna: incluso nell'app desktop.** I quattro file (`encoder.int8.onnx`
652 MB, `decoder.int8.onnx`, `joiner.int8.onnx`, `tokens.txt`: 670 MB,
639 MiB; gli stessi dell'archivio `.tar.bz2` ufficiale delle release di
sherpa-onnx, presi uno per uno da Hugging Face,
`csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8`) sono **dentro
l'installazione**, e l'app li legge da lì senza copiarli
(`ParakeetService.bundledModelDir`): alla prima registrazione Parakeet parte
subito, senza download né barra.

| Build | Dove sta il modello | Come ci arriva |
|---|---|---|
| Windows (UniNotes_setup.exe, zip, MSIX) | `data\parakeet\` accanto a `uninotes.exe` | `app/windows/CMakeLists.txt` lo scarica durante `flutter build windows` nella cache `app/build/parakeet/` (SHA-256 di ogni file; un `<file>.sha256` accanto evita di rileggerlo a ogni build) e lo installa con Silero VAD e le licenze; installatore, zip e MSIX impacchettano la cartella Release (`crea_msix.ps1` controlla che ci sia) |
| macOS (UniNotes.app, .dmg, .zip) | `UniNotes.app/Contents/Resources/parakeet/` | il workflow, dopo `flutter build macos` e prima della firma: `python3 tool/prepara_modello_parakeet.py --installa …/Contents/Resources/parakeet` |
| Linux | `data/parakeet/` accanto all'eseguibile | nessuna build Linux nel repository: l'app lo cerca lì; altrimenti lo scarica |

La cache `app/build/parakeet/` non è nel repository (`build/` è in
`.gitignore`); nel workflow la conserva `actions/cache` (chiave
`parakeet-tdt-0.6b-v3-int8-acfc2b44`, ~670 MB per sistema), così Hugging Face
si contatta solo la prima volta. `-DUNINOTES_PARAKEET=OFF` (CMake) fa una
build senza modello.

**Ripiego**: se i file inclusi mancano o hanno la dimensione sbagliata
(build fatte a mano senza modello, download non riuscito durante la build)
l'app li scarica come prima, alla prima registrazione o con «Scarica» nella
card Collegamenti → Whisper: avanzamento, ripresa (`.part` e `Range`),
spazio libero controllato prima di iniziare (con 200 MB di margine),
SHA-256 verificato a fine file, annullabile, un solo download alla volta,
in `<supporto dell'app>/parakeet/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/`.
La card dice «Parakeet incluso nell'app» (senza «Scarica» né «Elimina») o
«Parakeet scaricato» / «Non ancora scaricato».
Il **Silero VAD** (`silero_vad.onnx`, 643 KB, MIT) è accanto al modello
incluso e, per il ripiego, è anche un asset delle build desktop
(`assets/vad/`, `platforms: [windows, macos, linux]`). Su Windows
`onnxruntime.dll` dell'app si carica per primo: Windows 11 ne ha uno suo in
System32 (versione 1.17, troppo vecchia) che altrimenti farebbe chiudere
l'app. Il VAD di sherpa-onnx riceve l'audio a pezzi di 0,1 s: con blocchi
da 30 s (trascrizione di un file) non chiudeva le frasi alle pause e perdeva
l'inizio.

**Pesi** (21/10/2026, colonna con Whisper small aggiornata il 24/10; i
modelli quantizzati si comprimono poco: small q5_1, 190 MB, diventa 184 MB
con Deflate e 180 MB con LZMA al massimo, misurato):

| Pacchetto | Senza Parakeet | Con Parakeet | Con Parakeet e Whisper small q5_1 (dal 24/10) |
|---|---|---|---|
| cartella Release di Windows | ~153 MB | 825 MB (misurato) | 996 MB (misurato il 24/10) |
| UniNotes-windows.zip (Deflate) | ~90 MB | **564 MB** (misurato) | **~750 MB** |
| UniNotes_setup.exe (LZMA2 max, solido) | ~60 MB | **~500 MB** (stima: l'encoder con LZMA2 al massimo passa da 652 a 428 MB) | **~680 MB** |
| UniNotes.msix (Deflate) | ~90 MB | **~570 MB** (stima) | **~755 MB** |
| UniNotes.dmg / UniNotes-macos.zip | ~100 MB | **~580 MB** (stima: l'encoder con Deflate 465 MB) | **~765 MB** |
| spazio occupato dopo l'installazione | | ~0,85 GB (Windows), ~0,8 GB (Mac) | ~1,05 GB (Windows), ~1 GB (Mac) |

Tutti sotto il limite di 2 GB per file delle release di GitHub (e degli
artefatti); Microsoft Store e notarizzazione Apple accettano queste
dimensioni. Tempi del workflow: la prima volta ~1 minuto per scaricare il
modello, poi il ripristino della cache (~20–40 s); l'installatore Inno Setup
impiega qualche minuto in più per comprimere (LZMA2 con 4 thread,
`LZMANumBlockThreads=4`); macOS: la firma e la notarizzazione caricano
~0,6 GB in più.

**Licenza del modello incluso (CC BY 4.0)** e dove è rispettata:

| Obbligo | Dove |
|---|---|
| Attribuzione all'autore (NVIDIA) e nome dell'opera («NVIDIA Parakeet TDT 0.6B v3») | `NOTICE.txt` accanto al modello; pagina Licenze dell'app (`assets/licenses/parakeet_NOTICE.txt`); introduzione della pagina Licenze (`kLicensesIntro`); card Collegamenti → Whisper (`kParakeetAttribution`); README («Componenti di terze parti»); TERMINI.md / sito (termini) |
| Link all'opera (huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | stessi posti; pulsante «Pagina ufficiale del modello» nella card |
| Link o testo della licenza | testo completo `LICENSE.txt` (legalcode CC BY 4.0) accanto al modello e nella pagina Licenze (`assets/licenses/CC-BY-4.0.txt`); link nella card («Licenza CC BY 4.0»), README, termini |
| Indicazione delle modifiche | «modificato: convertito in ONNX e quantizzato int8 da k2-fsa/sherpa-onnx» in NOTICE, pagina Licenze, card, README, termini |
| Nessuna approvazione implicita | «UniNotes non è affiliata a NVIDIA né approvata da NVIDIA» negli stessi posti |
| Nessuna restrizione aggiuntiva | NOTICE e README: la licenza PolyForm di UniNotes vale solo per il codice dell'app, il modello resta CC BY 4.0; nessuna misura tecnica sui file (sono file normali nella cartella dell'app) |
| Esclusione di garanzia | NOTICE (sezione 5 della licenza), termini, pagina Licenze |

Le altre licenze dei componenti redistribuiti sono nella stessa cartella e
nella pagina Licenze: Silero VAD (MIT, `silero_vad_LICENSE.txt`), ONNX
Runtime (MIT, `onnxruntime_LICENSE.txt`), sherpa-onnx (Apache-2.0,
`sherpa-onnx_LICENSE.txt` su Windows; nella pagina Licenze arriva dal
pacchetto `sherpa_onnx`).

**Dal vivo con il VAD** (`VadLiveSegmenter`): l'audio della registrazione
(mono 16 kHz) va man mano all'isolate di Parakeet, sempre una richiesta alla
volta con tutto l'audio arrivato nel frattempo (`PcmBacklog`). Il VAD
(Silero: pausa di 0,5 s per chiudere una frase, parlato minimo 0,25 s,
taglio forzato oltre 18 s di parlato continuo; dal vivo, dal 30/10/2026,
il tratto si chiude prima, dopo ~12 s, nel punto più silenzioso: vedi
sotto) decide dove sono le frasi:
mentre si parla, ogni ~0,75 s di audio nuovo si decodifica la frase in
corso (un'ipotesi: le parole uguali in due ipotesi di fila si confermano
subito, vedi sopra); alla pausa la frase si decodifica una volta con tutto
il suo audio (più 0,3 s prima, per non tagliare la prima parola, e 0,25 s
di silenzio digitale prima e dopo) e diventa
definitiva, divisa in frasi alla punteggiatura con i tempi dei token. I
silenzi non producono testo e non costano calcolo. Due thread di ONNX
Runtime, in un isolate a parte: non rubano tempo alla registrazione. Se il
PC resta indietro di oltre 30 s si tiene l'audio più recente e il tratto
saltato si recupera dopo il salvataggio. Le correzioni dell'utente, le
formule e il salvataggio dei segmenti funzionano come prima.

**Vocabolario del corso (hotwords)**: sherpa-onnx accetta gli hotwords per
i transducer NeMo solo con `modified_beam_search` e un `bpe.vocab`, che per
questo modello non è pubblicato. Provato il 21/10/2026 con un `bpe.vocab`
ricavato da `tokens.txt` e parole delle frasi di prova («Stanley»,
«Paesi», «Massiccio del Vinson», punteggio fino a 4): il testo non cambia
(solo una maiuscola), mentre la decodifica è un po' più lenta. Quindi
Parakeet usa `greedy_search`, senza vocabolario; il vocabolario del corso
resta per Whisper.

**Misure** (21/10/2026, questo PC: portatile Intel Core Ultra 5 226V,
8 core, 16 GB, con altre build in corso; script in Dart con sherpa-onnx
1.13.8 e la prova `app/test/parakeet_real_test.dart` con l'isolate vero
dell'app):

- frasi vere in italiano (17 frasi di FLEURS dev, 230 s, voci diverse):
  **WER 4,7%** contando anche i numeri scritti in cifre o in lettere
  («due»/«2»); 230 s trascritti in 10,5 s con 2 thread (**fattore 0,046**,
  ~22 volte più veloce del tempo reale);
- dal vivo (le stesse frasi in un file da 255 s con 1,5 s di silenzio fra
  una e l'altra, a pezzi da 100 ms come la registrazione): decodifica di
  una frase confermata (5–14 s di audio) **0,28 s di mediana**, massimo
  0,6–0,9 s; testo provvisorio in 0,19 s di mediana; testo definitivo
  **0,8 s dopo la fine della frase** (di cui 0,5 s sono la pausa che il VAD
  aspetta); lavoro totale, provvisori compresi, 0,18–0,23 s per secondo di
  audio. 4 thread non vanno più veloce (0,26 per secondo), 1 thread
  0,23;
- memoria: 0,97 GB dopo il caricamento (~2 s); decodificare 4 minuti in un
  colpo solo arriva a 3,2 GB e peggiora il testo, per questo anche la
  trascrizione dopo il salvataggio va a frasi con il VAD (blocchi da 30 s);
- voce sintetica di Windows (Elsa): Parakeet la riconosce male (parole
  storpiate, a tratti in spagnolo), al contrario delle voci vere: per le
  prove servono registrazioni vere, non la sintesi vocale.

### Parakeet dal vivo: doppioni, inizi persi, parlato veloce (30/10/2026)

**Problema** (registrazioni vere del 30/10/2026, video riprodotti davanti al
microfono del PC, parlato medio-veloce): frasi doppie e sovrapposte nel
testo salvato («Parlarne.» / «Parlarne. mercoledì Ed è bravissimo…» /
«è davvero che mercoledì…» con tempi che si accavallano), parole perse dopo
l'inizio e dopo le pause, un tratto di 13,6 s con 5 parole, ripetizioni
(«stando stando stando stando stando»), tratti di 20–22 s.

**Cause** (trovate rigiocando l'audio vero a pezzi da 0,1 s, in tempo
reale, nel percorso intero dell'app: `VadLiveSegmenter` nell'isolate di
Parakeet, `LiveTranscriber`, `LiveAgreement`):

1. **Ipotesi vuote.** Su questo audio Parakeet restituisce spesso un testo
   vuoto per un'ipotesi a metà del parlato (anche 2–3 di fila), poi di nuovo
   il testo. Il testo vuoto valeva come «fine della frase»: la conferma per
   accordo si chiudeva, le parole già confermate restavano, e il testo
   definitivo del tratto, che arrivava dopo per tutto l'audio, si
   aggiungeva accanto: **doppioni e frasi sovrapposte**.
2. **«Ripartito da capo».** Un'ipotesi molto diversa dalle parole confermate
   chiudeva la frase (pensato per il riconoscitore del sistema e Whisper, che
   ripartono davvero). Parakeet invece ridecodifica sempre dallo stesso
   inizio e su audio difficile l'ipotesi cambia quasi tutta («Fizo! Por
   que?» → «Fisso! Perché?»): stesso effetto, doppioni.
3. **Prime parole perse.** Parakeet perde spesso le parole all'inizio di un
   tratto, o lo restituisce vuoto, se l'audio inizia subito con voce o
   rumore: decodificando gli stessi tratti del VAD con varianti, 0,25 s di
   **silenzio digitale prima e dopo** portano l'errore sul file di
   Psicologia (riferimento: la trascrizione di large-v3-turbo) dal 27,2% al
   21,2% (0,5 s: 22,0%; 1 s: 21,2%; più audio vero prima: 23,5%); su un
   tratto mancavano «Voglio fare un fondo, per uno studio di product design»,
   4 s.
4. **Parlato continuo.** Senza pause il tratto arrivava a 18–22 s: ogni
   ipotesi ridecodifica tutto (fino a 2–3 s di calcolo per ipotesi con il PC
   carico, il testo dal vivo restava indietro di 2–3 s) e il taglio forzato
   del VAD cadeva a metà frase («seminando piano piano | per un
   progetto…»: il pezzo dopo usciva in inglese inventato).

**Cosa cambia**:

- `VadLiveSegmenter`: un'ipotesi vuota lascia il testo provvisorio com'era;
  Parakeet riceve ogni tratto e ogni ipotesi con 0,25 s di zeri prima e dopo
  (`silencePad`, i tempi dei pezzi restano quelli della registrazione); se
  il testo definitivo è vuoto, ha meno della metà delle parole dell'ultima
  ipotesi o inizia ~0,8 s dopo la prima parola delle ipotesi, un secondo
  tentativo con 1 s di zeri (`retryPad`) e si tiene il testo con più
  parole; dal vivo, dopo 12 s di parlato senza pause (`softMax`) il tratto
  si chiude nel punto più silenzioso fra 5 e 12 s (finestra di 0,16 s con
  meno energia) e il VAD riparte da lì (gli si ridà l'audio dopo il
  taglio), così il suo taglio forzato a 18 s non arriva più; le parole
  ripetute a ciclo (una parola 4 volte o più, un gruppo di 2–6 parole 3
  volte o più) restano una volta (`collapseRepeats`; «piano piano» e «bene,
  bene, bene» restano). La trascrizione di un file dopo il salvataggio usa
  silenzio e secondo tentativo, non il taglio a 12 s.
- `LiveTranscriber`: un'ipotesi vuota mentre si parla non chiude più la
  frase; con Parakeet `LiveAgreement.hypothesis(restart: false)`.
- `LiveAgreement`: nessuna frase finisce dopo l'inizio della seguente
  (`_clampEnds`: si accorcia la fine, l'inizio resta la chiave della frase),
  anche quando restano le parole confermate di un tratto senza testo
  definitivo (vuoto o in un'altra lingua).

**Misure** (Intel Core Ultra 5 226V, 2 thread, con un altro lavoro sul PC;
tre registrazioni del 30/10, 118 s, 148 s e 93 s; percorso intero in tempo
reale con l'isolate dell'app; «doppioni» = frasi vicine con lo stesso
testo, contate a mano):

| | prima | dopo |
|---|---|---|
| frasi sovrapposte nei tempi (le tre registrazioni) | 1 + 0 + 2 | **0** |
| frasi doppie | 1 + 1 + 2 | **0** |
| tratti oltre 18,5 s | 0 + 1 + 0 | **0** |
| tratti lunghi quasi vuoti (> 8 s, < 1 parola/s) | 1 + 1 + 1 | 1 + 0 + 0 (musica: «Provavelmente.») |
| Psicologia: parole sbagliate rispetto a large-v3-turbo | 17,5% | **15,1%** |
| ritardo del testo dal vivo (audio per passo, 95° percentile, Psicologia) | 2,2 s | 1,3 s |
| audio decodificato per minuto di registrazione (senza attese, stessi file) | 8,0–12 min | 7,4–9,4 min |

Il testo salvato con l'app il 30/10 (Deontologia) aveva 2 frasi
sovrapposte, 1 doppione, una ripetizione «stando ×5» e un tratto di 22 s.
Restano gli errori del modello su questo audio (parole storpiate, frasi
inventate in inglese sulla musica, tolte dal filtro della lingua): con
l'audio di un video davanti al microfono Parakeet sbaglia ~15% delle parole
anche così.

Gli strumenti delle misure (rigioco dell'audio vero nel percorso dal vivo,
rigioco dei passi registrati senza modello, varianti di decodifica) stanno
fuori dalla repo; i test (`parakeet_live_test.dart`,
`live_agreement_test.dart`) controllano ipotesi vuote, silenzio digitale,
secondo tentativo, taglio nel punto più silenzioso, ripetizioni e assenza
di sovrapposizioni con VAD e decodificatore finti.

### Whisper small incluso su PC e Mac (24/10/2026)

Decisione dell'utente del 24/10/2026: le app desktop includono il modello
Whisper **small multilingue q5_1** (`ggml-small-q5_1.bin`, 190 085 487 byte,
181 MiB; `kDesktopWhisperModel` in `features/links/whisper_models.dart`),
così le frasi che Parakeet scrive in un'altra lingua si ritrascrivono
**sempre** con Whisper fissato sulla lingua della lezione, senza scaricare
niente (prima, senza un modello Whisper scaricato, si toglievano).

| Build | Dove sta | Come ci arriva |
|---|---|---|
| Windows (UniNotes_setup.exe, zip, MSIX) | `data\whisper\` accanto a `uninotes.exe`, con `LICENSE.txt` | `app/windows/CMakeLists.txt` lo scarica durante `flutter build windows` nella cache `app/build/whisper/` (SHA-256 controllato, `<file>.sha256` accanto) e lo installa; `-DUNINOTES_WHISPER=OFF` per una build senza; `crea_msix.ps1` controlla che ci sia |
| macOS (UniNotes.app, .dmg, .zip) | `UniNotes.app/Contents/Resources/whisper/` | il workflow, dopo `flutter build macos` e prima della firma: `python3 tool/prepara_modello_whisper_desktop.py --installa …/Contents/Resources/whisper` |
| Linux | `data/whisper/` accanto all'eseguibile | nessuna build Linux nel repository: l'app lo cerca lì |
| Android, iOS | — | nessun cambiamento (lì c'è base q5_1 integrato e, dove il telefono regge, small q5_1 scaricato per la seconda passata) |

**File e impronte**: il file ufficiale del repository di whisper.cpp su
Hugging Face (`ggerganov/whisper.cpp`, ramo main); SHA-256
`ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb`
(impronta LFS pubblicata da Hugging Face, `X-Linked-ETag` e API
`paths-info`) e SHA-1 `6fe57ddcfdd1c6b07cdcc73aaf620810ce5fc771` (tabella del
README del repository), tutte e due controllate sul file scaricato il
24/10/2026 da `tool/prepara_modello_whisper_desktop.py`. Nella CI la cache
`app/build/whisper` ha la chiave `whisper-small-q5_1-ae85e4a9` (Windows,
Store e macOS); il file non è mai nel repository. Un `ggml-base-q5_1.bin`
rimasto in `data\whisper\` da una build o un'installazione di prima del
21/10 si toglie (CMake, `[InstallDelete]` dell'installatore e
`crea_msix.ps1`): niente doppioni.

**Nell'app** (`WhisperService.includedModelFile`): il file si legge da lì
senza copiarlo, se ha la dimensione giusta (lo SHA-256 si controlla durante
la build) e se si può usare (whisper.cpp dentro l'app, `whisper_ggml`, che
su Windows vuole una CPU con AVX2, oppure `whisper-cli` se scaricato). Lo
usano:

- **testo dal vivo**: `liveEngine` lo sceglie fra i modelli per il vivo
  (`_livePreference`: large-v3-turbo q5_0, small, **small q5_1**, medium
  q5_0…, quindi un modello scaricato più adatto viene prima) per
  ritrascrivere le frasi di Parakeet in un'altra lingua e come ripiego
  quando Parakeet non può girare (meno di 4 GB di RAM, errore), a pezzi da
  ~10 s;
- **«Trascrivi con Parakeet»** dopo il salvataggio: i tratti fuori lingua
  vanno a lui (`rescue`);
- **«Trascrivi con…»**: compare fra i motori («small-q5_1») e si può scegliere
  come modello predefinito. Con «Automatico» però resta **Parakeet**: in
  `kWhisperAccuracy` small q5_1 viene dopo Parakeet, che sull'audio pulito
  è più preciso (WER 4,7% misurato su FLEURS contro ~10–15% di small) e
  circa tre volte più veloce (0,06 contro ~0,2 s per secondo di audio).
  Whisper è meglio solo con l'audio cattivo (le misure con medium sopra),
  e lì lavora già sulle frasi che Parakeet sbaglia di lingua. Small q5_1
  diventa il motore di «Trascrivi con…» solo dove Parakeet non può girare.

**Collegamenti → Whisper**: riga «Whisper small-q5_1 incluso nell'app
(181 MiB): ritrascrive nella lingua della lezione le frasi che Parakeet
scrive in un'altra lingua.»; nella tabella dei modelli small-q5_1 ha
l'etichetta «incluso nell'app» e nessun «Scarica» né «Elimina» (come
Parakeet incluso). Una copia scaricata prima si può ancora eliminare («resta
quella inclusa nell'app»).

**Licenza**: MIT per i pesi e il codice di Whisper (OpenAI) e per la
conversione in ggml (whisper.cpp, autori di ggml). Testi in
`app/assets/licenses/whisper_LICENSE.txt`, mostrati nella pagina Licenze
dell'app (voce «Whisper small q5_1 (OpenAI, whisper.cpp)») e copiati come
`LICENSE.txt` accanto al modello; introduzione della pagina Licenze,
PRIVACY.md §6.2, TERMINI.md e README aggiornati.

Test: `app/test/whisper_included_test.dart` (scelta del modello incluso,
nessun doppione con una copia scaricata, Parakeet ancora predefinito,
ripiego senza Parakeet, telefono invariato; frase fuori lingua
ritrascritta dal vivo e in «Trascrivi con Parakeet» con motori finti).

### Dopo il salvataggio su PC e Mac

Parakeet è fra i motori di «Trascrivi con…» / «Trascrivi di nuovo con…»
(etichetta «Parakeet», sottotitolo «NVIDIA, veloce, 639 MiB»), insieme ai
modelli Whisper scaricati; i modelli Whisper scaricabili restano. Con
«Automatico» si usa il più accurato che il dispositivo regge
(`kWhisperAccuracy`: large-v3 … large-v1, medium, **Parakeet**, small,
base; Parakeet sotto medium dal 29/10/2026, vedi «Trascrizione a pezzi
brevi»): senza modelli Whisper scaricati (o con solo small, base, tiny) è
Parakeet. Un'ora di lezione in ~4 minuti (stima 0,06 s per secondo). La
trascrizione si salva come «trascritta con Parakeet».

### Telefono: Whisper migliorato e seconda passata

Il modello integrato del telefono (`ggml-base-q5_1.bin`, solo negli asset
Android e iOS) ora usa sempre:

- **Silero VAD di whisper.cpp** (`assets/vad/ggml-silero-v5.1.2.bin`,
  885 KB, SHA-256 controllato alla copia): i silenzi della finestra non
  vanno al modello, niente frasi inventate;
- **`suppressNonSpeechTokens`**: niente «[Musica]», «[BLANK_AUDIO]»;
- **vocabolario del corso** come `initialPrompt` (`buildWhisperPrompt` in
  `core/services/whisper_prompt.dart`): «Lezione di <insegnamento>:
  <modulo in corso>, <suoi argomenti>, <altri moduli>, <altri argomenti>.»,
  al massimo ~200 token (whisper.cpp ne usa 224), tagliando dalla fine a
  voci intere; si leggono solo i moduli e gli argomenti dello studente.
  Solo vocabolario e mai l'ultima frase confermata: le finestre da 2 s si
  sovrappongono e con la frase precedente nel prompt Whisper tende a
  ripeterla (per questo resta `noContext: true`); le righe che ripetono il
  prompt si scartano (`isPromptEcho`).

Le stesse opzioni valgono per «Trascrivi con Whisper» dopo il salvataggio
(whisper_ggml) e, su PC e Mac, per i modelli Whisper scaricati con
`whisper-cli` (`--prompt`, `--suppress-nst`, `--vad --vad-model`).

**Seconda passata con small** (`second_pass.dart`): con small q5_1
(181 MiB, nella tabella dei modelli; si scarica da solo con il Wi‑Fi la
prima volta che serve, se la seconda passata è accesa e il telefono è
adatto), mentre si registra i tratti già confermati del testo istantaneo
**di Whisper base** si ritrascrivono in blocchi da ~30 s, in background (2
thread, small non resta in memoria fra un blocco e l'altro perché
whisper.cpp tiene un modello solo, quello del testo istantaneo) e
sostituiscono il testo, salvo le frasi corrette a mano. Condizioni:

- solo quando il testo dal vivo è di **Whisper base** (riconoscitore del
  sistema assente, senza la lingua o fermo): **mai sul testo del
  riconoscitore del sistema** (dal 24/10/2026, vedi sotto);
- telefono con almeno 6 GB di RAM e 6 core e almeno 700 MB liberi;
- **prova al primo uso**: il primo blocco misura la velocità
  (impostazione `whisper_second_pass_rtf`); oltre 0,5 s di lavoro per
  secondo di audio la seconda passata resta spenta su quel telefono;
- si **ferma da sola** se resta indietro di oltre 90 s, se due blocchi di
  fila sono molto più lenti della prova (il telefono si scalda e rallenta)
  o con la batteria sotto il 20% senza caricabatterie (riprende con il
  caricabatterie). La card «Trascrizione» **non lo scrive più** (prima:
  «Seconda passata con small sospesa: …»): il testo istantaneo resta e
  migliora dopo il salvataggio con «Trascrivi di nuovo con…»;
- interruttore «Seconda passata con small mentre registri» in Collegamenti
  → Whisper (impostazione `whisper_second_pass`, accesa di predefinito dove
  il telefono regge).

**Perché non sul testo del riconoscitore del sistema** (decisione del
24/10/2026):

- *precisione*: Whisper small multilingue sbaglia in italiano circa una
  parola su dieci anche su audio pulito (WER ~10–15% su FLEURS secondo
  l'articolo di Whisper, la stessa stima della tabella dei modelli in
  `whisper_models.dart`; il q5_1 qualcosa in più); il riconoscitore di Google sul dispositivo (Android 13+) e quello
  di Apple (SFSpeechRecognizer sul dispositivo, SpeechAnalyzer da iOS 26)
  sono modelli fatti per la dettatura in una sola lingua, con
  punteggiatura, e quando il 21/10 il testo dal vivo del telefono è
  passato per errore a Whisper è peggiorato in modo evidente (vedi
  «Perché sul telefono era peggiorata»). Small non è quindi un
  miglioramento sicuro: può cambiare frasi giuste in sbagliate, e sul
  rumore Whisper inventa frasi intere;
- *batteria e calore*: small q5_1 sul telefono lavora 0,3–0,5 s per
  secondo di audio su 2 core grandi, cioè 20–30 minuti di calcolo pieno
  per ogni ora di lezione, sopra al riconoscitore che già gira; in due ore
  di lezione è la voce di consumo più grande dell'app e fa scaldare il
  telefono (che poi rallenta anche la registrazione);
- *testo che cambia sotto gli occhi*: le frasi già lette (e a volte in
  corso di correzione) venivano sostituite a blocchi da 30 s.

Con Whisper base invece small è un miglioramento netto (base sbaglia in
italiano circa il doppio: WER ~20–30% contro ~10–15%), quindi lì resta. Per un
testo migliore di quello del riconoscitore, dopo il salvataggio si propone
solo un modello **più accurato di small** (medium o large, se scaricato:
`kSystemSpeechRank` in `better_transcription.dart`).

### Dopo il salvataggio: una trascrizione più accurata

Se il modello che userebbe «Trascrivi con…» (il predefinito o il più
accurato scaricato che il dispositivo regge, vedi [Quale modello Whisper si
usa](#quale-modello-whisper-si-usa)) è più accurato del motore che ha fatto
il testo dal vivo (Parakeet su PC e Mac, il modello integrato sul
telefono), dopo «Salva» (dal registratore, dal riquadro sopra le schermate
o dal menu dell'icona del PC) compare il riquadro **«Trascrivere di nuovo
con small?»** (`better_transcription.dart`):

- il testo spiega chi ha fatto il testo dal vivo («di Parakeet», «del
  modello integrato»), veloce ma meno preciso, e dà il **tempo stimato**
  («circa 6 minuti», in background);
- due pulsanti: **Non ora** e **Trascrivi**; toccando fuori è come «Non ora»
  (la trascrizione si può sempre fare dopo con «Trascrivi di nuovo con…»);
- la casella **«Fallo sempre in automatico»**: spuntata, con «Trascrivi», le
  volte successive la trascrizione parte da sola con un avviso. È
  l'impostazione `dont_ask_better_transcription` e si annulla da
  Impostazioni → «Ripristina le domande».

La trascrizione con il modello scaricato aspetta che finisca «Completo la
trascrizione» (così non scrivono in due la stessa trascrizione); quella dal
vivo va in «Eliminati di recente».

**Stima del tempo**: secondi di lavoro per secondo di audio su un PC con 8
core (tiny 0,03, base 0,06, small 0,2, medium 0,55, large-v3-turbo 0,45,
large 1,1, Parakeet 0,06; i quantizzati un po' meno), più lenta con meno
core e 2,5 volte sul telefono, più il caricamento del modello. Dopo la
prima trascrizione con un modello si usa la velocità **misurata su quel
dispositivo** (media con le precedenti, impostazione
`whisper_speed_<modello>`), quindi la stima migliora con l'uso.

### Trascrizione a pezzi brevi (29/10/2026)

**Problema** (lezione vera registrata da lontano su PC, 29/10/2026): il
testo dal vivo di Parakeet era quasi tutto in inglese inventato dal brusio
(«Okay.», «Mm-hmm.», «No, I know.»: 57 frasi, metà passava il filtro della
lingua) e large-v3-turbo sul file intero si fermava su una frase ripetuta
per minuti («Non è un'imposte.» ×60).

**Cosa cambia**:

- «Trascrivi con Whisper» (whisper-cli e whisper.cpp nell'app, telefono
  compreso) non trascrive più il file intero o pezzi da 10 minuti ma **pezzi
  di al massimo 25 s tagliati alle pause** (`whisper_chunks.dart`: livello
  ogni 30 ms, pausa = almeno 360 ms sotto il livello medio del file meno
  12 dB), ognuno **da solo** (`-mc 0` / `no_context`): un errore resta nel
  suo pezzo. I pezzi di solo silenzio o fondo non vanno a Whisper. Un pezzo
  che esce **a ciclo** (la stessa frase 3 volte in più o la stessa sequenza
  di 4 parole 3 volte, `looksLooped`) si ritrascrive in due metà; se resta a
  ciclo si tiene una copia sola (`withoutLoops`). Le frasi intere del
  silenzio («Grazie.», «Grazie a tutti.») si tolgono (`withoutFillers`).
  `whisper-cli` trascrive 20 pezzi per processo (`-f`/`-of` per pezzo, il
  modello si carica una volta). Solo i WAV si dividono (le registrazioni
  dell'app e l'audio convertito); `.flac`, `.mp3`, `.ogg` letti direttamente
  da whisper-cli restano interi.
- Nelle lezioni in italiano una **frase breve** (fino a 6 parole) di
  Parakeet senza parole italiane e con almeno una parola inglese è fuori
  lingua (`outsideLecture`, con le parole di `_englishShort` e i versi
  «Oh.», «Mm-hmm.», «Sorry.» fra gli intercalari): nella lezione vera le
  frasi tolte passano da 27 a 47 su 57, nelle 33 frasi di prova se ne tolgono
  solo 1–2 (tutte inventate dal rumore; con molto rumore 13, tutte inglesi).
- `kWhisperAccuracy`: Parakeet sotto medium (prima era sopra).

**Misure** (Intel Core Ultra 5 226V, 8 core, solo CPU; le 33 frasi di prova
in fila con 2 s di pausa, 393 s; degrado simulato come il 24/10:
riverbero e rumore; percentuale di parole sbagliate):

| Motore | pulito | lontano | molto lontano | lontano + rumore |
|---|---|---|---|---|
| Parakeet dal vivo (com'era) | 6,6% | 13,2% | 31,4% | 69,5% |
| Whisper small q5_1 (incluso), frase per frase | 12,4% | 23,4% | 38,0% | 53,9% |
| Whisper medium q5_0, frase per frase | 5,4% | 16,4% | 21,7% | 37,5% |
| large-v3-turbo q5_0, frase per frase | 4,4% | 8,3% | 19,7% | 27,1% |
| **large-v3-turbo q5_0 a pezzi brevi** | – | **8,0%** | – | **24,4%** |
| turbo a pezzi con il codice dell'app (`transcribeInChunks`, tagli un po' diversi; con o senza i tempi delle frasi) | – | 9,8% | – | – |
| turbo a pezzi + VAD sui pezzi | – | 9,0% | – | 30,2% |
| turbo a pezzi + VAD + riduzione del rumore (ffmpeg `afftdn`, `dynaudnorm`) | – | – | – | 32,5% |

A pezzi brevi nessun pezzo è uscito a ciclo e turbo va a ~0,8 volte la
durata dell'audio (un'ora in ~50 minuti, solo CPU). Il VAD sui pezzi e la
riduzione del rumore peggiorano: non si usano. Sulla lezione vera il testo
a pezzi non ha più cicli ma resta poco leggibile: l'audio era troppo
lontano dal docente per qualunque modello. Con un microfono vicino (o il
telefono sulla cattedra) l'errore scende verso quello della colonna
«pulito». 99,9% di parole giuste non è raggiungibile con modelli aperti in
italiano (i migliori ~2,5–5% con audio pulito).

Gli strumenti delle misure con i modelli veri stanno fuori dalla repo e si
usano a mano; i test della repo (`whisper_chunks_test.dart`,
`live_agreement_test.dart`) controllano pause, cicli, frasi del silenzio e
lingua senza modelli.

### Giunture dei pezzi e frasi lunghe (30/10/2026)

**Segnalazione**: con large-v3-turbo q5_0 appena scaricato la prima prova
era «come Parakeet»; nella seconda Whisper a volte univa quello che si dice
prima con quello che si dice dopo perdendo dei pezzi, e teneva ancora
blocchi di testo troppo lunghi.

**La prima prova**: nessun modello saltato. Il modello è finito di
scaricare alle 20:19:42; la registrazione di Deontologia (20:11–20:13) è di
prima e ha solo il testo dal vivo di Parakeet. In Fondamenti (salvata alle
20:22) il testo che si vede subito è quello dal vivo di Parakeet (in
«Eliminati di recente»: «trascrizione dal vivo con Parakeet»); Whisper l'ha
sostituito un minuto dopo, in background. Il codice della scelta
(`pickModel`, `availableModels`, `offerBetterTranscription`) legge i
modelli dal disco a ogni chiamata, senza scelte in memoria; l'impostazione
`whisper_model` era vuota (automatico).

**Cause trovate** (piano dei pezzi dell'app sui file veri, confronto con
whisper-cli sul file intero, con il contesto e beam 5):

- **Pausa lunga dentro il pezzo**: in Fondamenti 47,1–65,0 s c'erano 5 s di
  silenzio (49,3–54,2 s, video in pausa) e Whisper ha scritto un segmento
  solo di 18 s, «ma mi… / …delle dinamiche» diventato «ma ha delle
  dinamiche», con una frase persa. Il piano tagliava sempre all'ultima pausa
  entro 25 s, anche con una pausa lunga in mezzo.
- **Taglio a metà parola**: senza pause in 25 s il taglio cadeva a 25 s
  esatti, nel parlato (Psicologia generale, 38,95 s, −20 dB): «super
  pro|dotti» → «super progetti. prodotti».
- **Silenzio all'inizio**: i primi 9 s di Psicologia generale sono silenzio
  digitale; «Stay hungry, stay foolish.» è vero (la citazione all'inizio
  del video, sentita anche da Parakeet), ma il segmento partiva da 0 s.
- **Blocchi lunghi**: Whisper chiude un segmento solo con i suoi token di
  tempo: 14–18 s nell'app, fino a 27 s sul file intero. Nel lettore la frase
  in ascolto era un blocco di righe. I tempi dei pezzi riportati alla
  registrazione erano giusti; nessun codice unisce il testo di Whisper a
  quello dal vivo (dopo Whisper si rifanno solo le maiuscole).

**Cosa cambia** (`whisper_chunks.dart`):

- `planChunks`: una pausa di almeno 3 s (`kWhisperLongPause`) si taglia
  sempre ai due lati (0,3 s di margine) e diventa un pezzo a sé, che va a
  Whisper solo se il 10% più forte delle sue finestre sta entro 22 dB dal
  livello medio del file (una domanda dal fondo dell'aula sì, il fondo della
  stanza no); senza pause il taglio cade nel punto più basso (150 ms) fra 15
  e 25 s. Un pezzo sotto 1,5 s (whisper.cpp non trascrive meno di 1 s) si
  allunga con del silenzio.
- `splitSentences`: ogni segmento si divide alle fine delle frasi; una frase
  oltre 10 s alle virgole (in parti uguali), oltre 15 s anche fra le parole.
  I tempi vengono dai token (`-ojf` di whisper-cli, che non cambia il testo:
  controllato parola per parola); whisper.cpp nell'app non dà i token e i
  tempi si stimano dai caratteri.
- Provati e scartati: pezzi sovrapposti di 0,5 s con le parole doppie tolte
  alle giunture (i tempi dei token ai bordi sbagliano: parole perse a ogni
  giuntura, differenza dal riferimento 36,8% e 11,5% contro 25,4% e 10,2%
  con gli stessi tagli senza sovrapposizione); `-ml 1 -sow` (stesso testo,
  ma si perdono i segmenti di Whisper).

**Misure** (turbo q5_0, CPU, il codice dell'app con whisper-cli vero;
differenza in parole dal file intero, che non è la verità ma è più
accurato). Whisper non dà sempre lo stesso testo per lo stesso pezzo: nello
stesso processo il campionamento a temperatura più alta riparte dal punto
lasciato dal pezzo prima, e un rumore di ±1 sui campioni cambia l'uscita.
Differenze di 2–3 punti sono rumore:

| | Fondamenti (93 s) | Psicologia generale (149 s) | Deontologia (118 s) |
|---|---|---|---|
| pezzi di prima | 28,9% (28,1%, 28,1% con ±1) | 9,4% (9,7%, 9,2%) | 24,3% |
| pezzi nuovi | 24,6% (28,5%, 25,9%) | 10,2% (8,6%, 11,8%) | 25,4% |
| segmento più lungo, prima → dopo | 18 s (nell'app) → 9,1 s | 13 s → 8,1 s | 17 s → 8,8 s |

Sulle 33 frasi di prova (verità nota, frasi tolte del silenzio come
nell'app): «lontano» 9,7% → 7,8%, «lontano + rumore» 24,9% → 25,8% (stessi
pezzi salvo i 3 s di silenzio iniziale: rumore). Le giunture viste nei file
veri sono sparite («super prodotti», «ma mi… / …delle dinamiche», «Stay
hungry» a 9,4 s); le frasi perse dentro un pezzo restano possibili (in
Fondamenti «non lo doveva rilasciare» manca anche nel file intero con il
contesto). Costo: con le pause lunghe tagliate i pezzi sono un po' di più
(lezione vera del 29/10, 335 s: 15 → 19; i file del 30/10: +0–1) e ogni
pezzo costa come 30 s di audio, quindi ~10–25% di tempo in più.

### Modificare il testo mentre si registra

Il testo della card si modifica **come nel Blocco note o in Google Docs**: un
tocco (o un clic) in un punto qualsiasi del testo mette lì il cursore e si
scrive, cancella, seleziona (anche con la pressione lunga su una parola),
copia e incolla direttamente nel testo, mentre la registrazione e la
trascrizione continuano: le frasi nuove arrivano in fondo (il cursore resta
dov'è), quella provvisoria compare sotto, più chiara. Esc o un tocco fuori
tornano alla lettura. Le modifiche si salvano da sole a ogni tasto (nel file
della sessione dopo 2 s, nella trascrizione e nei dati della registrazione
al salvataggio).

Due modalità con passaggio immediato (`live_transcript_editor.dart`):
**lettura**, con le formule `$…$` disegnate, e **modifica**, con il testo
semplice (le formule in LaTeX). Il cursore va nel punto toccato anche con le
formule (la posizione nel testo disegnato si converte in quella del testo
LaTeX); senza formule le due modalità hanno lo stesso aspetto.

Le frasi tengono i loro tempi (testo sincronizzato nel lettore): una
modifica dentro una frase cambia solo quella; una modifica che ne tocca più
d'una (es. cancellare lo spazio fra due frasi, incollare sopra una selezione)
le unisce in una sola, dall'inizio della prima alla fine dell'ultima; una
frase svuotata si toglie (`TranscriptEditBuffer`,
`LiveTranscriber.replaceSegments`). Il testo originale resta in memoria per
unire bene le finestre successive di Whisper.

**Lezioni di ore** (24/10/2026, test in `app/test/crash_r3_memoria_test.dart`):
il testo è diviso in blocchi di 40 frasi (`kLiveReadingBlock`, ~4 minuti di
lezione), ognuno un paragrafo: a ogni parola nuova si ricostruisce e si
reimpagina solo l'ultimo blocco (prima un paragrafo unico con tutta la
lezione: con 2600 frasi, ~4 ore, 115 ms sul PC per ogni parola, più volte al
secondo; ora ~25 ms quasi costanti). Toccando il testo si modifica **il
blocco toccato**: nel campo ci sono le sue frasi, gli altri blocchi restano
in lettura sopra e sotto (prima tutto il testo era nel campo: ~140 ms per
tasto e per parola confermata dopo 4 ore; ora ~25 ms). Una selezione o una
cancellazione non attraversa due blocchi; nell'ultimo blocco le frasi nuove
entrano nel campo come prima. Con meno di 40 frasi non cambia niente.

### Controllo ortografico

Nel campo di modifica della trascrizione e nell'editor delle note (anche di
riassunti e trascrizioni) le parole errate hanno la classica **linea
ondulata rossa**, con il **correttore del sistema operativo**, come nel
Blocco note: nessun dizionario incluso nell'app (`spell_check.dart`).

| Sistema | Correttore | Suggerimenti |
|---|---|---|
| Windows | `ISpellChecker` di Windows (`spellcheck.h`, `windows/runner/spell_check.cpp`) | tasto destro sulla parola: suggerimenti in cima al menu, poi Taglia, Copia, Incolla |
| macOS | `NSSpellChecker` (`UniNotesSpellCheck` in `MainFlutterWindow.swift`) | tasto destro sulla parola |
| Android | correttore del sistema (della tastiera), con `DefaultSpellCheckService` di Flutter | tocco sulla parola sottolineata |
| iOS | `UITextChecker`, con `DefaultSpellCheckService` | tocco sulla parola sottolineata |
| Linux | nessuno | — |

Su PC e Mac si controllano **italiano e inglese insieme**: una parola è
errata solo se non è in nessuna delle due lingue installate, così le
citazioni in inglese di una lezione in italiano non si sottolineano; la
lingua dell'insegnamento viene prima e dà i suggerimenti. Sul telefono il
sistema controlla una lingua alla volta: quella dell'insegnamento. Se una
lingua non è installata nel sistema, per quella lingua non si sottolinea
nulla e Impostazioni → Aspetto lo dice con un avviso discreto («Per il
controllo ortografico in italiano installa la lingua italiana in Windows»).
Le formule (`$…$`, `\(…\)`…) e gli indirizzi web non si controllano.

Il testo si controlla una riga alla volta, con i risultati delle righe già
viste in memoria: a ogni tasto si ricontrolla solo la riga cambiata, anche in
una trascrizione di un'ora. Il campo di Flutter controlla il testo solo
quando cambia: per sottolineare subito il testo che c'è già, il controllo si
attiva un fotogramma dopo l'apertura del campo.

**Linea rossa anche in lettura.** Le parole errate si segnano con la stessa
linea ondulata rossa anche senza entrare nella modifica: nella card
«Trascrizione» mentre si registra (`EditableLiveTranscript`, modalità
lettura), nel lettore delle registrazioni (`recording_player_screen.dart`,
frasi della trascrizione e testo semplice) e nella lettura di trascrizioni,
riassunti e appunti (`MarkdownLiteView`, non nelle risposte dell'AI).
L'aspetto è identico a quello della modifica
(`TextField.materialMisspelledTextStyle`) e il passaggio alla modifica con il
cursore nel punto toccato non cambia (la linea divide il testo in tratti ma
non cambia né le posizioni dei caratteri né quello che leggono i lettori di
schermo). Il lavoro è in `spell_check.dart`:

- `ReadingSpellChecker` chiede gli errori allo stesso servizio
  (`spellCheckService(lingua)`) un testo alla volta (una frase della
  trascrizione, un blocco di Markdown), in modo asincrono, un testo dopo
  l'altro e dopo un breve ritardo (500 ms) dall'ultimo testo nuovo; il
  risultato resta in memoria per testo, quindi lo stesso testo non si richiede
  due volte e durante la registrazione (una frase nuova ogni ~2 s) si
  controllano solo le frasi nuove o cambiate. Finché il risultato non c'è il
  testo si vede com'è; dove il correttore non c'è (`spellCheckSupported`
  falso, Linux) o se il controllo fallisce, nessun errore e nessun avviso. Un
  controllo superato da uno più recente (restituisce `null`) si riprova una
  volta.
- `misspelledSpans(testo, errori, {style, start, end, offset})` trasforma
  testo + errori in `TextSpan` con le parole errate sottolineate; `start`/`end`
  e `offset` permettono di disegnare un tratto di un testo più grande (la
  parte di una frase prima o dopo una formula) con gli errori calcolati sul
  testo intero.
- Il testo provvisorio (ancora in corso) e le formule (`$…$`, parti math) non
  si controllano; nei Markdown anche il codice, e il controllo di un blocco
  vede una formula o il codice in linea come uno spazio (una parola in parte
  in grassetto resta una parola).

### Formule (LaTeX)

Il filtro **«Formule (LaTeX)»** nella card «Trascrizione» (la scelta resta
per le registrazioni successive, impostazione `live_formulas`) scrive come
formule quelle dette a voce, con un convertitore italiano parlato → LaTeX
(`spoken_math.dart`): «due terzi» → `$\frac{2}{3}$`, «integrale da 2 a pi
greco» → `$\int_{2}^{\pi}$`, «x al quadrato più y al quadrato uguale r al
quadrato» → `$x^{2} + y^{2} = r^{2}$`, «il limite per x che tende a zero di
seno di x fratto x» → `$\lim_{x \to 0} \frac{\sin x}{x}$`. Riconosce
numeri in lettere e cifre, frazioni («un mezzo», «pi greco mezzi», «x fratto
2», «b su c»), più/meno/per/diviso, uguale/diverso/minore/maggiore (o
uguale), potenze («al quadrato», «quadro», «alla terza», «elevato alla n»,
«alla meno uno»), pedici («x con zero»), radici (quadrata, cubica, ennesima),
valore assoluto, fattoriale, integrali («da … a …», «tra … e …», «in dx»),
somme e produttorie («per k che va da 1 a n», «da i uguale 1 a n»), limiti,
seno/coseno/tangente/logaritmo («in base»), esponenziale, «f di x», «f
primo», derivate («derivata di … rispetto a x»), lettere greche (anche
«maiuscola»), infinito, «e alla x» e parentesi («aperta parentesi … chiusa
parentesi»).

Un tratto diventa formula solo se ha almeno un segno o una struttura
matematica e almeno due parole: «tre», «alfa», «la somma di due numeri»,
«più o meno», «due secondi», date e orari restano testo; le parole a, e, i,
o (articoli e congiunzioni) non diventano variabili, tranne dove la frase lo
richiede (indici di somme e limiti). Le formule si vedono disegnate
(`widgets/math_text.dart`) nella card, nel lettore e negli appunti e si
salvano in LaTeX (`$…$`) nella trascrizione. Le frasi corrette a mano non si
convertono più. Senza l'opzione il testo resta com'è.

### Windows: «Riconoscimento vocale online»

Non serve: su PC il testo istantaneo è di Parakeet. Per la cronaca: la
dettatura libera di Windows (`SpeechRecognizer` senza grammatica) funziona
solo con Impostazioni → Privacy e sicurezza → Voce → «Riconoscimento vocale
online» attivo (`HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy`,
`HasAccepted` = 1), l'audio passa dai servizi Microsoft e il riconoscitore
apre il microfono per conto suo; con l'opzione attiva il testo istantaneo non
arrivava, e per questo su PC e Mac il riconoscitore del sistema non si usa.

### Il modello Whisper integrato (telefono)

Sul telefono il ripiego del testo istantaneo è Whisper con un **modello
integrato**: `ggml-base-q5_1.bin` (base multilingue quantizzato q5_1,
57 MiB, `kBuiltInWhisperModel`), con whisper.cpp dentro l'app
(`whisper_ggml`). Lo stesso modello è il ripiego sempre disponibile di
«Trascrivi con Whisper» sul telefono.

Come arriva: asset dell'app `assets/whisper/` (in `pubspec.yaml` con
`platforms: [android, ios]`, quindi **non entra nei pacchetti di Windows,
macOS e Linux**: con Flutter 3.47 gli asset si filtrano per piattaforma
con la chiave `platforms`). Il file non è nel repository (`.gitignore`):
prima delle build Android e iOS si scarica con `python
tool/prepara_modello_whisper.py` (controlla lo SHA-1; nella CI è un passo
del workflow, tolto da quello di macOS). Alla prima apertura l'app lo copia
nella cartella dei modelli (`whisper/models/`, 4 s dopo l'avvio, in
background; la copia si verifica con lo SHA-1 e si rinomina solo a fine
scrittura). In una build senza il modello si scarica da solo con il Wi‑Fi
alla prima registrazione che ne ha bisogno.

**Dal 21/10/2026 non c'è più su PC e Mac**: `app/windows/CMakeLists.txt` non
lo scarica più durante la build e l'installatore non lo mette in
`data/whisper/`; una copia rimasta nella cartella dei modelli di un Mac non
si usa (`WhisperService.builtInSupported` è vero solo sul telefono). Dal
24/10/2026 in `data/whisper/` c'è invece **small q5_1** (vedi «Whisper
small incluso su PC e Mac»); il vecchio base q5_1 si toglie.

**Finestre corte** (`LiveWindowPlanner` in `recorder/live_transcript.dart`):
ogni ~2 s di audio nuovo si ritrascrive dal WAV di lavoro il tratto non
ancora definitivo (che si allunga da 2 a 6 s, con 0,3 s di sovrapposizione
col tratto prima). Il testo è **provvisorio** (più chiaro) e si aggiorna a
ogni passo; diventa **definitivo** quando la finestra finisce in una pausa
(ultimo mezzo secondo ~10 dB più basso del resto, `endsInPause`) o quando
arriva a 6 s: in quel caso l'ultima frase, forse tagliata a metà parola,
resta provvisoria e si ritrascrive nella finestra dopo. Le parole ripetute
nella sovrapposizione si tolgono unendo il testo (`TranscriptMerger`). Con il
VAD di whisper.cpp i silenzi dentro la finestra non arrivano al modello.

Il lavoro non blocca mai la registrazione: una finestra alla volta, in un
isolate separato, con il modello tenuto in memoria. Se Whisper è lento il
passo si allunga (fino a 5 s); se resta comunque indietro di oltre 18 s il
tratto vecchio si salta (il testo resta al passo col parlato) e si recupera
dopo il salvataggio, insieme all'ultimo tratto ancora provvisorio. Le
finestre silenziose non vanno a Whisper e le frasi che Whisper inventa sul
silenzio («Sottotitoli creati dalla comunità Amara.org»…) si scartano.

Senza modello dal vivo (download non riuscito, telefono con i dati mobili;
su PC e Mac quando Parakeet non può girare) si usa il modello scaricato
dall'utente: pezzi da ~10 s (9 s nuovi + 1 s di sovrapposizione), ognuno
definitivo appena trascritto (`LiveWindowPlanner.slow`).

**Misure di allora** (19/10/2026, portatile Intel Core Ultra 5 226V, audio
di prova di 58 s sintetizzato con la voce Elsa di Windows, `whisper_ggml.dll`,
4 thread): tiny q5_1 0,38 s per finestra (troppi errori), **base q5_1
0,77 s** (testo provvisorio in media 1,8 s dopo, peggiore 2,9 s), small
q5_1 solo l'encoder 2,5–6 s (non sta al passo con finestre da 2 s, e sul
telefono è ~3 volte più lento di base: per questo small fa la seconda
passata a blocchi da 30 s e non il testo istantaneo).

## Salvataggio e formati

| | Formato |
|---|---|
| Registrazione salvata | `.m4a` AAC mono, ~48 kbit/s (~21 MB per ora). Su Windows si usa il formato del codificatore di sistema più vicino (stessi canali, frequenza uguale o subito superiore, bitrate più vicino a 48 kbit/s) |
| Se la compressione non riesce | resta il WAV (16 kHz mono, ~115 MB per ora): mai perdere la registrazione |
| Registrazioni precedenti | `.flac`, `.wav`, `.m4a`: restano leggibili e trascrivibili |
| Dati della registrazione | `Registrazioni/<nome>.json`: segnalibri, segmenti della trascrizione con inizio e fine, forma d'onda (un valore ogni 0,1 s), durata. Si rinomina, si sincronizza e va nel cestino con l'audio; non compare negli elenchi |
| Trascrizione | `Trascrizioni/<nome>.md` (Whisper, o il testo dal vivo): un paragrafo ogni ~2 minuti, **senza gli orari delle frasi**; l'intestazione dice chi l'ha fatta e con quale modello («trascritta con Whisper small»). I tempi dei segmenti sono solo nel `.json` (testo sincronizzato nel lettore) |
| Trascrizioni del vecchio formato (`[hh:mm:ss]` a ogni paragrafo) | aprendo la pagina del corso o la registrazione gli orari si tolgono dal file; se la registrazione non aveva ancora i tempi nel `.json`, prima vengono copiati lì. Anche esportazione PDF, lettura, modifica e i file mandati all'AI li tolgono. Le trascrizioni di Gemini non si toccano |
| Trascrizione di Gemini | `Trascrizioni/<nome> (Gemini).md`, accanto a quella di Whisper; si rinomina con la lezione |

Compressione (WAV → `.m4a`):

- **Android, iOS**: ffmpeg incluso nell'app (`ffmpeg_kit_flutter_new_min`,
  codificatore AAC di ffmpeg);
- **macOS**: `/usr/bin/afconvert` (Core Audio, di sistema), con ffmpeg
  dell'app come riserva;
- **Windows**: Media Foundation, con un piccolo metodo nativo nel runner
  (canale `io.github.simomagnus.universitynotes/audio`, metodo `toM4a`:
  `IMFSourceReader` → `IMFSinkWriter` MPEG-4 AAC).

Conversione in WAV 16 kHz mono per Whisper (`toWav`): le stesse vie. Su
Windows le registrazioni `.m4a` non richiedono più di scaricare ffmpeg: si
convertono con Media Foundation, e ffmpeg resta solo come riserva se la
conversione nativa non riesce.

## Nella pagina del corso

Card **«Registrazioni delle lezioni»** (la card «Trascrizioni» non c'è più):

- tocco sulla card → la registrazione (ascolto e trascrizione);
- tocco sul **nome** → rinomina (insieme a trascrizioni, riassunto e dati);
- **cestino** → «Eliminati di recente»; nel menu ⋮ restano solo «Salva una
  copia», «Condividi» e «Allega a modulo/argomento di Studio»;
- sulla stessa riga **«Trascrivi con Whisper»** e **«Trascrivi con
  Gemini»**: fatta la trascrizione la casella diventa **«Vedi
  trascrizione»** (una riga sola: prima c'era anche «con modello
  integrato»), azzurra per Whisper e viola per Gemini, e apre la
  registrazione con quella trascrizione («Trascrizione con Whisper · small»
  o «con Gemini»: il modello si legge lì). Sotto «Trascrivi con Whisper» c'è
  il modello che si userà (es. «small», «modello integrato»). Il testo dal
  vivo del vecchio riconoscimento del sistema non occupa la casella di
  Whisper: si legge nella registrazione e Whisper resta disponibile;
- **tenendo premuto** «Trascrivi con Whisper», o dal menu ⋮ («Trascrivi con
  un altro modello…», «Trascrivi di nuovo con…», anche nel menu del
  lettore) si sceglie il modello per quella sola trascrizione; rifacendola,
  quella di prima va in «Eliminati di recente»;
- se Whisper non riesce non compare una card d'errore: la card della
  registrazione dice «Impossibile trascrivere con Whisper: …» con cosa
  provare (scaricare un modello, un modello più piccolo, Gemini…);
- operazioni in corso (Whisper, Gemini, «Completo la trascrizione», taglio)
  con la barra di avanzamento nella card.

Sotto le registrazioni: **«Riassunti lezioni e Appunti»** (prima «Riassunti
delle lezioni»: si allegano riassunti e appunti, Markdown, PDF, Word…) e
**«Note»** (prima «Appunti personali»: le note scritte nell'app, «Nuovo» apre
l'editor «Nuova nota», con il controllo ortografico).

**Condividi su Windows**: il tasto apre la finestra «Condividi» di Windows
(share_plus con `DataTransferManager`). Non serve pubblicare l'app né un
pacchetto MSIX: la finestra funziona anche per l'app installata con
UniNotes_setup.exe, da Windows 10 1809. Prima non funzionava perché il
plugin risponde sempre «non disponibile», anche quando la finestra si apre:
l'app lo prendeva per un errore, copiava il file negli appunti e apriva
Esplora file, e la finestra «Condividi» (che si chiude appena perde il
focus) spariva subito. Ora su Windows (`widgets/share_files.dart`,
`systemShare`) la risposta vale come finestra aperta; l'app chiama
direttamente il canale nativo del plugin mandando sempre testo, titolo
(obbligatorio per Windows) e file, perché il plugin ricordava i campi della
condivisione precedente; i percorsi sono assoluti con «\». Su Windows prima
della 1809 i file vanno ancora negli appunti con la cartella aperta.

**Trascrivi con Gemini** (con l'account dello studente, senza chiave API:
la chiave API e Antigravity sono stati tolti dall'app e i valori salvati si
cancellano una volta all'avvio): si apre il riquadro con il prompt e il file da allegare (tasto **Condividi** e tasto della **cartella**:
sul PC apre la cartella con il file selezionato da copiare nella chat, sul
telefono copia il percorso) e «Apri Gemini». Non c'è più «Incolla risposta»:
copiata la trascrizione in Gemini, **tornando in UniNotes** con il riquadro
aperto il testo copiato (almeno 200 caratteri, diverso dal prompt) si salva
da solo come trascrizione di Gemini, con «Annulla» nell'avviso. Lo stesso per
«Riassumi con Gemini».

**Studia con la tua AI di riferimento**: le richieste pronte senza «Incolla
risposta»; le risposte incollate in passato restano elencate e ora si
possono **eliminare** (cestino) oltre che rinominare.

## Quale modello Whisper si usa

Con più modelli scaricati (Collegamenti → Whisper):

1. il modello scelto per quella trascrizione (pressione lunga o «Trascrivi
   di nuovo con…»);
2. altrimenti il **modello predefinito** scelto nel menu «Modello
   predefinito» di Collegamenti → Whisper;
3. se è «Automatico» (il valore iniziale; scaricare un modello non lo
   cambia più), il **più accurato fra quelli scaricati che il dispositivo
   regge**: ordine di accuratezza in italiano `kWhisperAccuracy` (large-v3,
   large-v3-turbo, … large-v1, medium, Parakeet, small, small q5_1, base,
   modello integrato, tiny) e RAM necessaria al massimo il 60% di quella del
   PC/Mac o il 40% di quella del telefono (`deviceCanRun`); se nessuno
   regge, il più accurato comunque;
4. senza modelli scaricati, o se il programma whisper.cpp manca (Windows
   senza `whisper-cli`): su PC e Mac **Parakeet** (incluso o scaricato) e,
   dove Parakeet non può girare, **Whisper small q5_1 incluso nell'app**
   (con whisper.cpp dentro l'app); sul telefono il **modello integrato**,
   che gira sempre con whisper.cpp dentro l'app.

Perché così: il predefinito lascia allo studente il controllo; l'automatico
evita che un modello scaricato per prova (o più vecchio) resti in uso
quando ne arriva uno migliore, ma senza scegliere un modello che sul
telefono finirebbe la memoria; l'integrato garantisce che «Trascrivi con
Whisper» funzioni sempre. Ogni trascrizione salva il modello usato davvero
(intestazione del `.md` e `trascrizione` nel `.json`, `WhisperResult`).

**Consiglio per il dispositivo**: Collegamenti → Whisper mostra «Consigliato
per questo dispositivo» accanto al modello da scaricare scelto in base a RAM
(`/proc/meminfo` su Android e Linux, `GlobalMemoryStatusEx` su Windows,
`sysctlbyname("hw.memsize")` su macOS e iOS, via FFI, senza pacchetti),
core (`Platform.numberOfProcessors`), piattaforma e spazio libero
(`recommendWhisperModel`): sul PC e sul Mac large-v3-turbo q5_0 con almeno
8 GB e 4 core, small con almeno 4 GB, altrimenti base; sul telefono small
con almeno 6 GB e 6 core, altrimenti base; se lo spazio non basta (con
500 MiB di margine) il modello più accurato che ci sta. Tiny non si
consiglia mai: il modello integrato è già migliore.

## Riascoltare una registrazione

Tocco su una registrazione nella pagina del corso:

- **forma d'onda che scorre** sotto la linea di lettura, trascinabile, fluida
  a ogni fotogramma: la posizione del lettore arriva a intervalli
  irregolari, fra una e l'altra si avanza con il tempo trascorso e la
  velocità (`PlaybackClock`); si ridisegnano solo la forma d'onda e i tempi,
  non la pagina;
- **indietro / avanti di 15 e 30 s**, **velocità** 0,5–2×, **Salta
  silenzi** (salta i tratti silenziosi di almeno 1,5 s);
- **testo sincronizzato**: il segmento in corso è evidenziato e resta in
  vista, un tocco su un segmento salta a quel punto (senza l'orario accanto
  a ogni frase); le formule `$…$` si vedono disegnate;
- **segnalibri**: tacche arancioni sulla forma d'onda e pulsanti (tocco → vai
  lì, pressione lunga → nota o rimozione); «Segna» ne aggiunge uno durante
  l'ascolto;
- **nome**: un tocco lo rinomina; **cestino** nella barra in alto;
- **riquadro della trascrizione**: chi l'ha fatta (colore di Whisper o di
  Gemini), scelta fra le due se ci sono entrambe, **cerca** (anche Ctrl+F),
  **copia il testo** e **«Apri in» l'AI di riferimento**;
- menu ⋮: **condividi** l'audio, il testo o entrambi, **Riassumi** (Gemini con il prompt e
  la trascrizione da allegare; il riassunto copiato si salva da solo),
  **Taglia**;
- **Taglia**: si sceglie un tratto **ascoltandolo** (▶ suona il tratto e si
  ferma alla fine; spostando un cursore si riascolta da lì; un tocco sulla
  forma d'onda suona da quel punto) e si tiene solo quello o lo si toglie;
  segnalibri, testo e forma d'onda si spostano di conseguenza. L'originale
  va in «Eliminati di recente».

Non ci sono più «Trascrivi di nuovo con qualità migliore» e «Apri nel
lettore».

La lente nella pagina **Registra** cerca nelle trascrizioni di tutte le
registrazioni; il risultato apre la registrazione con il testo già cercato.

## Eliminati di recente

Le registrazioni (con i loro dati) e gli appunti eliminati restano 30 giorni
in una cartella nascosta dentro la cartella degli appunti (`.eliminati/`,
come `.cestino-onedrive` e `.cestino-googledrive` per i file eliminati su un
altro dispositivo), poi si cancellano da soli. Dalla pagina **Registra →
Eliminati di recente** si ripristinano (con « (ripristinato)» se nel
frattempo è comparso un file con lo stesso nome; l'avviso ha **Annulla**,
che rimette l'elemento negli eliminati con la data di prima) o si
cancellano per sempre. **Svuota** è un pulsante grande sopra l'elemento
eliminato per ultimo, pieno come gli altri, con i colori di errore del tema
(fondo `errorContainer`, testo e icona `onErrorContainer`, bordo sottile
`error`): contrasto almeno 4,5:1 in tema chiaro e scuro (prima il testo
rosso sul fondo tonale non si leggeva). Le cartelle che iniziano con «.» non si sincronizzano: su OneDrive e
Google Drive il file eliminato va nel cestino del servizio, come prima.

## Windows: niente schermo nero riaprendo dalla barra delle applicazioni

Riducendo a icona la finestra, Windows porta l'area della finestra a 0x0 e
il runner la passava alla vista di Flutter: il motore si ridimensionava a
0x0 e al ripristino doveva rifare layout e disegno di tutta la pagina a
piena misura (vetro sfocato compreso) prima di mostrare qualcosa; nel
frattempo restava il fondo vuoto (nero). Ora (`windows/runner/win32_window.cpp`,
`WM_SIZE` con `SIZE_MINIMIZED`) la vista di Flutter tiene la sua misura e
l'ultimo frame: al ripristino si vede subito. Il runner manda lui a Flutter
lo stato «hidden» quando la finestra è ridotta a icona e «resumed» /
«inactive» al ripristino (`flutter_window.cpp`, canale `flutter/lifecycle`):
le Sessioni Focus continuano a sapere che l'app è in secondo piano. In più
un frame forzato a ogni ritorno in primo piano (`WM_ACTIVATEAPP`, oltre a
`WM_SIZE` e `WM_SHOWWINDOW`) e, lato Dart, `scheduleForcedFrame` in
`desktop_window.dart`; la sincronizzazione al ritorno parte dopo 5 s.

Prova (22/10/2026, app di prova con lo stesso runner e una pagina con 20
riquadri sfocati, build release, riduci/ripristina da script): prima, a ogni
ripristino Flutter riceveva una nuova misura e rifaceva la pagina (layout
~18 ms + disegno 22–46 ms, con la superficie ricreata); dopo, nessuna
nuova misura né ricostruzione, stati «hidden» → «resumed» corretti.

### Secondo giro (25–26/10/2026): il nero misurato e tolto

Il primo giro non bastava. Misurato sull'app vera (build release, PC con
Intel Core Ultra 5 226V e grafica integrata) con uno script che riduce e
ripristina la finestra in tutti i modi realistici (`ShowWindow`
`SW_MINIMIZE`/`SW_RESTORE`, `WM_SYSCOMMAND` `SC_MINIMIZE`/`SC_RESTORE`
come la barra delle applicazioni, `ShowWindowAsync` + `SetForegroundWindow`,
nascondi/mostra come l'area di notifica), con pause di 0, 1, 10 e 60 s, e
cattura l'area della finestra **dallo schermo** (BitBlt dal DC dello
schermo, che vede la composizione di DWM compresa la superficie DirectX di
Flutter) a raffica per 1,5 s dopo ogni ripristino. Conta come «nero» una
cattura con più del 10% dei pixel neri puri o del colore di fondo della
finestra (#02060F) che non lo erano prima della riduzione né nello sfondo
dietro la finestra.

Cause trovate:

- `window_manager` ferma `WM_SIZE` con `SIZE_MINIMIZED` (restituisce 0
  prima del runner): il codice del primo giro su quel messaggio (stato
  «hidden» per le Sessioni Focus, vista che tiene la misura) non girava
  mai. Ora il runner guarda i messaggi **prima** dei plugin.
- Ridotta a icona (o nascosta), Windows libera la superficie DirectX della
  vista di Flutter. Al ripristino il compositore mostra subito la finestra
  (animazione dalla barra) con la superficie vuota: si vede il fondo
  dipinto dal runner (#02060F, quasi nero) o il nero. Flutter presenta un
  frame 12–30 ms dopo il ripristino, ma spesso troppo presto (finestra non
  ancora visibile per il compositore: il frame va perso) e, con l'app
  ferma, il successivo arrivava solo con un movimento del mouse. Nella
  schermata iniziale (nulla che si muove) il nero restava anche **per
  secondi**; nella Home, dove qualcosa ridisegna, 20–65 ms.

Rimedi (`windows/runner/flutter_window.cpp`):

- **ultima immagine**: appena prima di ridurre a icona
  (`WM_WINDOWPOSCHANGING` verso la posizione delle finestre ridotte,
  -32000) o di nascondere la finestra (`WM_SHOWWINDOW`), il runner copia
  l'area client dalla superficie della finestra (BitBlt dal DC della
  finestra, 4–13 ms; `PrintWindow` con `PW_RENDERFULLCONTENT` dava la stessa
  immagine in 40–60 ms, troppo per una riduzione) e la dipinge nella
  superficie GDI della finestra, che Windows conserva; al ripristino
  `WM_ERASEBKGND` dipinge di nuovo quella invece del colore di fondo. Il
  compositore mostra così l'ultimo frame finché Flutter non ripresenta
  (stessa immagine, nessun salto). Se la copia risulta tutta nera (altra
  scheda video o presentazione) si scarta e resta il colore di fondo;
- **frame forzati** per circa un secondo dopo il ritorno (uno ogni 33 ms,
  `StartRedraws`): uno arriva di sicuro a finestra visibile, anche con
  l'app ferma; poi l'immagine si libera (non va ridipinta sotto la vista a
  un ridimensionamento);
- stato «hidden»/«inactive»/«resumed» di nuovo mandato a Flutter alla
  riduzione e al ripristino.

| Ripristini (build release) | Prima | Dopo |
|---|---|---|
| Home, tema scuro, pause 0/1 s (3 modi × 50) | nero in 86 su 150, fino a 65 ms (media ~22 ms), fino al 72% della finestra | nero in 0 su 150 (peggior cattura: 3% di pixel, bordi dell'animazione) |
| Home, tema chiaro, pause 0/1 s (3 modi × 50) | — | nero in 0 su 150 (peggiore 0,1%) |
| Nascondi/mostra (area di notifica), 20 | — | nero in 0 su 20 |
| Ridotta 10 s e 60 s (4 modi × 4) | — | nero in 0 su 16 |
| Schermata iniziale (app ferma), 4 + 4 + 8 ripristini | nero in tutti, ancora nero 5 s dopo il ripristino | — |

In tutto, dopo: 0 catture nere in 366 ripristini. Le catture da script non
passano dalla barra delle applicazioni vera: l'unica differenza è chi
chiede la riduzione, i messaggi alla finestra sono gli stessi.

## Windows: la X chiude subito (26/10/2026)

Prima la finestra restava sullo schermo per **8–11 secondi** dopo la X
(misure sotto). Causa: alla fine del ciclo dei messaggi il distruttore di
`FlutterWindow` era vuoto e il motore si chiudeva con la distruzione
implicita dei membri, cioè con `flutter_controller_` ancora impostato
mentre veniva distrutto: i messaggi che la chiusura della vista manda alla
finestra arrivavano ancora al motore a metà distruzione, e la chiusura
durava secondi (con il distruttore che chiama `OnDestroy`, che azzera il
puntatore prima, 15–40 ms: provato sulla stessa build cambiando solo
quello). La finestra si distruggeva solo dopo, e intanto la copia unica era
già libera: una nuova copia poteva partire con la vecchia ancora aperta.

Ora (`windows/runner/flutter_window.cpp`, `main.cpp`,
`lib/core/services/desktop_window.dart`):

- alla **X** (anche dall'anteprima della barra con la finestra ridotta) il
  runner **nasconde subito** la finestra, prima dei plugin e del motore, e
  la segna con la proprietà `UniNotes.Chiusura` (1 = X premuta);
- l'app decide: con una **registrazione in corso** resta nell'area di
  notifica (canale `io.github.simomagnus.universitynotes/finestra`,
  `nascosta`; prima, su Windows, la X passava dal motore a
  `onExitRequested`, che salvava e fermava la registrazione invece di
  lasciarla andare: ora risponde «cancel» e va nell'area di notifica); se
  l'icona dell'area di notifica non si può mostrare la finestra torna
  visibile. Altrimenti esce (`uscita`, proprietà = 2): salva la
  registrazione se c'è (solo da «Esci»), toglie l'icona, aspetta le
  scritture del database in corso (una transazione vuota dopo quelle
  avviate, al massimo 5 s) e chiude;
- senza risposta dall'app entro 10 s la finestra torna visibile (meglio di
  un processo invisibile);
- `~FlutterWindow` chiama `OnDestroy` (canali, poi motore con il puntatore
  già azzerato); finestra e motore si chiudono in un blocco prima di
  `CoUninitialize` e del rilascio della copia unica;
- una **seconda copia** avviata mentre la prima si chiude (proprietà 1 o 2,
  o finestra già distrutta con la copia unica ancora presa) non le passa il
  primo piano e non sparisce: aspetta che la prima finisca (al massimo
  15 s, controllando ogni 25 ms) e si apre al suo posto. Con la X appena
  premuta e l'app che resta nell'area di notifica, la proprietà sparisce e
  la seconda copia riporta in primo piano quella.

| Chiusura (build release, Home con dati, OneDrive non collegato) | Prima | Dopo |
|---|---|---|
| Finestra non più visibile dopo `WM_CLOSE` / `SC_CLOSE` (21 chiusure: appena aperta, dopo 20 s di uso, ridotta a icona) | 7,8–10,9 s (media ~8,4 s) | 1–6 ms (i 4–5 ms in più quando era visibile: copia dell'ultima immagine) |
| Processo finito | 8,0–10,9 s | 0,49–0,61 s |
| Riapertura subito dopo la chiusura | 21 su 21 | 21 su 21 |
| Riapertura mentre la prima si chiude (30 ms, 0,5 s, 2 s dopo la X) | la nuova partiva con la vecchia ancora aperta per secondi | 6 su 6, la nuova aspetta la fine della vecchia |

I ~300 ms fra la fine di `wWinMain` e la fine del processo sono lo
scaricamento delle librerie (motori di trascrizione, lettore): a finestra
già sparita e copia unica già libera.

### Strumenti per le misure

- Build di prova con i dati in una cartella a parte:
  `flutter build windows --release --dart-define=UNINOTES_CARTELLA_PROVA=<cartella>`
  (`lib/core/services/test_data_dir.dart`): dati, Documenti, temporanei e
  download dentro quella cartella, preferenze in memoria, niente
  portachiavi, toast pianificati e registro dell'utente. Nelle build
  normali la costante è vuota e non cambia nulla.
- Traccia dei tempi: con la variabile d'ambiente
  `UNINOTES_TRACCIA_FINESTRA=<file>` runner (`window_trace.h`) e app
  (`DesktopWindow.trace`) scrivono nello stesso file i messaggi della
  finestra, i frame presentati dopo un ripristino, i passi della chiusura.
- Script (ctypes, nessun pacchetto) che riduce/ripristina e chiude la
  finestra e cattura lo schermo: descritto sopra; i test statici del
  runner sono in `app/test/crash_r6_finestra_test.dart`.

## Accessibilità

Pulsanti grandi (64–96 px nel registratore, 48 px nel riquadro), etichette
per i lettori di schermo su tutti i comandi (anche il riquadro, letto come
«Registrazione in corso: corso, tempo»), pallino che non pulsa con
«Riduci animazioni».

## Nome predefinito delle registrazioni e orario con i due punti (24/10/2026)

- **Nome predefinito**: «2026-10-05 14:04» (data e ora d'inizio), **senza la
  parola «Lezione»** (prima «2026-10-05 14-04 Lezione»). Due registrazioni
  nello stesso minuto: «… (2)».
- **I due punti sul disco**: Windows (e OneDrive) non ammettono «:» nei nomi
  dei file. Il nome del file ha al suo posto «꞉» (U+A789, «modifier letter
  colon»), che sembra due punti ed è un carattere normale per Windows,
  OneDrive, Android, macOS e Linux: `Registrazioni/2026-10-05 14꞉04.m4a`,
  `Trascrizioni/2026-10-05 14꞉04.md`, `Riassunti/…`. Scelta fatta al posto di
  un titolo nei metadati: registrazione, trascrizione, riassunto, PDF e
  trascrizione di Gemini si ritrovano dal nome del file (non ci sono due
  nomi da tenere allineati fra cartelle, sincronizzazione e backup), e il
  nome resta leggibile anche fuori dall'app.
- **Quello che vede l'utente** è sempre «14:04»: `NotesStore.displayName`
  (e `NoteFile.title`) sostituisce «꞉» con «:». Vale per elenchi, titoli,
  titolo della trascrizione, lavori in background, «Eliminati di recente»,
  condivisione, allegati di Studio, ricerca (si trova scrivendo «14:04»),
  campo «Rinomina» (parte da «14:04»). Scrivendo «:» nel campo, il nome del
  file prende «꞉» (`NotesStore.fileStem`); le note personali ne guadagnano:
  «Analisi: limiti» non diventa più «Analisi_ limiti».
- **Registrazioni di prima** («2026-10-05 14-04 Lezione.m4a»): restano come
  sono sul disco (nessun file rinominato, i collegamenti con trascrizioni,
  riassunti e allegati non si toccano) e si **mostrano** anche loro con
  «14:04» («2026-10-05 14:04 Lezione»); la parola «Lezione» dei nomi vecchi
  si lascia. Aprendo «Rinomina» su una di queste senza cambiare niente, il
  file non viene toccato.
- Titoli degli allegati di Studio: i nuovi si salvano con «14:04»; quando si
  rinomina la lezione si aggiornano sia quelli vecchi (che finiscono con il
  nome del file) sia quelli nuovi.
- Da provare su dispositivo vero: salvare una registrazione su Android e su
  Windows e controllare che la cartella sincronizzata con OneDrive/Drive
  mostri il file con «꞉» e che la condivisione verso altre app lo accetti.
  Test: `notes_screens_test.dart` (gruppo «nome della lezione con l'orario»).

## Registra: niente card «Blocchi appunti OneNote» (24/10/2026)

La card in cima alla pagina Registra (visibile con l'account Microsoft
collegato) è stata tolta. Gli appunti OneNote si allegano come qualunque file
(sono accettati anche `.one` e `.onepkg`, il lettore interno li apre e da lì
«OneNote nell'app» porta ai blocchi dell'account): dalla pagina di un corso in
Registra → «Riassunti lezioni e Appunti» → **Allega** (e «Allega a
modulo/argomento di Studio» sul file), oppure in Studio → **Aggiungi file**
sul modulo o sull'argomento (dal dispositivo o dagli appunti del corso).
