# Registratore delle lezioni

Il registratore (sezione **Registra**) funziona come l'app Memo Vocali di
iOS, con la trascrizione dal vivo come la registrazione audio nell'app Note.
Tutto avviene sul dispositivo: l'audio e il testo non lasciano il telefono o
il PC finché non scegli di sincronizzarli o di mandarli a Gemini.

Nella pagina **Registra** gli insegnamenti sono divisi come in Studio: **1°
semestre**, **2° semestre**, **Annuale** e **OFA** (con l'anno davanti se
il percorso ne mostra più d'uno), ognuno solo con il suo nome
(`groupStudyCourses` in `app/lib/features/study/course_groups.dart`).

Codice: `app/lib/features/notes/` (`lecture_recorder.dart`,
`recorder_screen.dart`, `recording_player_screen.dart`,
`recently_deleted_screen.dart`, `transcript_search_screen.dart`,
`recycle_bin.dart`, `course_notes_screen.dart`, `lesson_transcripts.dart`,
`spell_check.dart`) e `app/lib/features/notes/recorder/` (WAV, trascrizione
dal vivo con `live_transcriber.dart`, modifica del testo con
`live_transcript_editor.dart`, proposta di una trascrizione più accurata con
`better_transcription.dart`, salvataggio, riquadro sopra le schermate,
controlli in background). Riconoscimento vocale del sistema (oggi non usato
per il testo istantaneo, vedi sotto): `system_speech.dart`,
`app/android/.../LiveSpeech.kt`, `app/ios/Runner/LiveSpeech.swift` (uguale in
`app/macos/Runner/`), `app/windows/runner/live_speech.cpp`. Controllo
ortografico: `app/windows/runner/spell_check.cpp`, `UniNotesSpellCheck` in
`app/macos/Runner/MainFlutterWindow.swift`. Conversioni
audio: `app/lib/core/services/audio_codec.dart` e, su Windows,
`app/windows/runner/audio_transcoder.cpp`. Test:
`app/test/recorder_logic_test.dart`, `app/test/recorder_speech_test.dart`,
`app/test/recording_overlay_test.dart`, `app/test/live_transcript_edit_test.dart`,
`app/test/better_transcription_test.dart`, `app/test/spell_check_test.dart` e
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
  parla e diventa definitivo a ogni frase. Lo fa **sempre Whisper con il
  modello integrato**, sul dispositivo e senza internet, con un paio di
  secondi di ritardo, qualunque altra cosa sia collegata (riconoscimento
  vocale di Windows, modelli Whisper scaricati). Vedi [Trascrizione dal
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

## Trascrizione dal vivo

Il testo istantaneo lo fa **sempre Whisper con il modello integrato**
(`ggml-base-q5_1.bin`, vedi sotto), a finestre di 2 s: offline, uguale su
ogni sistema, con un paio di secondi di ritardo. Lingua: quella
dell'insegnamento se nota (es. inglese per gli insegnamenti in inglese),
altrimenti l'italiano. Whisper legge l'audio dal WAV di lavoro e non apre il
microfono: la registrazione non viene mai interrotta né bloccata da un suo
errore.

Prima, dove c'era, si usava il riconoscimento vocale in streaming del
sistema (Windows con «Riconoscimento vocale online», Android 13+, iOS e
macOS). Su Windows, con «Riconoscimento vocale online» attivo, il testo
istantaneo non arrivava: dal 21/10/2026 il registratore non lo usa più su
nessun sistema (`LectureRecorder` non passa più il riconoscitore a
`LiveTranscriber`), così il comportamento è lo stesso ovunque e non dipende
da impostazioni del sistema né da servizi in rete. Il codice del
riconoscitore (`system_speech.dart` e i file nativi `LiveSpeech`) resta,
spento, con i suoi test.

### Che cosa succede con ogni combinazione

| Situazione | Testo istantaneo durante la registrazione | Dopo «Salva» |
|---|---|---|
| Solo il modello integrato (nessun modello scaricato) | Whisper integrato | niente da proporre: la trascrizione è quella dal vivo; «Trascrivi con Whisper» resta disponibile |
| Modello integrato + un modello scaricato più accurato (small, medium, large, turbo…) | Whisper integrato (i modelli grandi sono troppo lenti per le finestre di 2 s) | riquadro «Trascrivere di nuovo con small?» con il tempo stimato, «Non ora» e «Trascrivi», casella «Fallo sempre in automatico» |
| Come sopra, con «Fallo sempre in automatico» già scelto | Whisper integrato | la trascrizione con il modello scaricato parte da sola, con l'avviso del tempo stimato |
| Modello scaricato meno accurato dell'integrato (tiny) | Whisper integrato | niente da proporre |
| «Riconoscimento vocale online» di Windows attivo | Whisper integrato (l'opzione di Windows non conta più) | come sopra, secondo i modelli scaricati |
| PC senza AVX2 (prima del 2013: whisper.cpp dell'app non gira) con un modello scaricato e `whisper-cli` | il modello scaricato a pezzi da ~10 s (testo con più ritardo) | niente da proporre se è già il modello migliore |
| Build senza il modello integrato | lo scarica da solo la prima volta (sul telefono solo con Wi‑Fi), con la barra nella card; l'audio di quei secondi si trascrive dopo il salvataggio | come sopra |
| Nessun modello utilizzabile | nessun testo, la card spiega come averlo; la registrazione va avanti | «Trascrivi con Whisper» o Gemini dalla pagina del corso |

I tempi dei segmenti sono quelli della registrazione. Alla fine («Salva») il
tratto ancora provvisorio e quelli saltati si completano in background
(«Completo la trascrizione», visibile nella card della registrazione).

### Dopo il salvataggio: una trascrizione più accurata

Se il modello che userebbe «Trascrivi con Whisper» (il predefinito o il più
accurato scaricato che il dispositivo regge, vedi [Quale modello Whisper si
usa](#quale-modello-whisper-si-usa)) è più accurato del modello integrato e
non è quello che ha fatto il testo dal vivo, dopo «Salva» (dal registratore,
dal riquadro sopra le schermate o dal menu dell'icona del PC) compare il
riquadro **«Trascrivere di nuovo con small?»** (`better_transcription.dart`):

- il testo spiega che il testo dal vivo è del modello integrato, veloce ma
  meno preciso, e dà il **tempo stimato** («circa 6 minuti», in background);
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
large 1,1; i quantizzati un po' meno), più lenta con meno core e 2,5 volte
sul telefono, più il caricamento del modello. Dopo la prima trascrizione con
un modello si usa la velocità **misurata su quel dispositivo** (media con le
precedenti, impostazione `whisper_speed_<modello>`), quindi la stima migliora
con l'uso.

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

Non serve più: il testo istantaneo è sempre di Whisper (vedi sopra) e la
card non chiede più di attivare l'opzione. Per la cronaca: la dettatura
libera di Windows (`SpeechRecognizer` senza grammatica) funziona solo con
Impostazioni → Privacy e sicurezza → Voce → «Riconoscimento vocale online»
attivo (`HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy`,
`HasAccepted` = 1), l'audio passa dai servizi Microsoft e il riconoscitore
apre il microfono per conto suo; con l'opzione attiva il testo istantaneo non
arrivava, e per questo si è passati a Whisper ovunque.

### Il modello integrato (offline)

Il testo istantaneo lo fa Whisper sul dispositivo con un **modello
integrato**: `ggml-base-q5_1.bin` (base multilingue quantizzato
q5_1, 57 MiB, `kBuiltInWhisperModel`), sempre con whisper.cpp dentro l'app
(`whisper_ggml`, anche su Windows: niente `whisper-cli` da scaricare). Lo
stesso modello è il ripiego sempre disponibile di «Trascrivi con Whisper»
(vedi [Quale modello Whisper si usa](#quale-modello-whisper-si-usa)).

Ogni build lo include:

- **Windows**: nell'installatore e nello zip (`app/windows/CMakeLists.txt`
  lo scarica una volta da Hugging Face durante la build, controlla lo SHA-1
  e lo copia in `data/whisper/` accanto a uninotes.exe). Funziona subito.
- **Android, iOS, macOS, Linux**: asset dell'app `assets/whisper/` (in
  `pubspec.yaml` con `platforms: [android, ios, macos, linux]`, così su
  Windows non è doppio). Il file non è nel repository (`.gitignore`): prima
  della build si scarica con `python tool/prepara_modello_whisper.py`
  (controlla lo SHA-1). Alla prima apertura l'app lo copia nella cartella
  dei modelli (`whisper/models/`, 4 s dopo l'avvio, in background; la copia
  si verifica con lo SHA-1 e si rinomina solo a fine scrittura).
- **Build senza il modello** (script non lanciato, build di Windows senza
  internet): alla prima registrazione che ne ha bisogno l'app lo scarica
  da sola, con la barra nella card; sul telefono solo con Wi‑Fi. L'audio
  registrato durante il download si trascrive dopo il salvataggio.

Verifica (19/10/2026, Windows): `whisper_ggml.dll` dell'app carica
`ggml-base-q5_1.bin` e trascrive un audio di prova in italiano («Buongiorno
a tutti. Oggi parliamo di integrali e calcoliamo l'integrale da 0 a 1 di x
al quadrato.») in 3,5 s compreso il caricamento, con il PC occupato da
altre build.

**Peso sugli store** (il modello si comprime pochissimo): +~55 MB su ogni
build. Google Play accetta AAB fino a 200 MB di download compresso
(UniNotes con media_kit, ffmpeg e pdfium resta sotto, ma va controllato
sull'AAB vero: se si supera, il modello va spostato in un *asset pack*
install-time di Play Asset Delivery, che richiede una modifica nativa);
App Store: sopra i 200 MB iOS chiede conferma per scaricare con i dati
mobili (non è un rifiuto); Microsoft Store e Mac App Store non hanno
problemi di dimensione.
- PC con CPU senza AVX2 (prima del 2013): whisper.cpp dell'app non si usa
  (`IsProcessorFeaturePresent`), resta il modello scaricato dall'utente con
  `whisper-cli`.

**Finestre corte** (`LiveWindowPlanner` in `recorder/live_transcript.dart`):
ogni ~2 s di audio nuovo si ritrascrive dal WAV di lavoro il tratto non
ancora definitivo (che si allunga da 2 a 6 s, con 0,3 s di sovrapposizione
col tratto prima). Il testo è **provvisorio** (più chiaro) e si aggiorna a
ogni passo; diventa **definitivo** quando la finestra finisce in una pausa
(ultimo mezzo secondo ~10 dB più basso del resto, `endsInPause`) o quando
arriva a 6 s: in quel caso l'ultima frase, forse tagliata a metà parola,
resta provvisoria e si ritrascrive nella finestra dopo. Le parole ripetute
nella sovrapposizione si tolgono unendo il testo (`TranscriptMerger`).

Il lavoro non blocca mai la registrazione: una finestra alla volta, in un
isolate separato, con il modello tenuto in memoria. Se Whisper è lento il
passo si allunga (fino a 5 s); se resta comunque indietro di oltre 18 s il
tratto vecchio si salta (il testo resta al passo col parlato) e si recupera
dopo il salvataggio (operazione «Completo la trascrizione», visibile nella
card della registrazione), insieme all'ultimo tratto ancora provvisorio. Le
finestre silenziose non vanno a Whisper e le frasi che Whisper inventa sul
silenzio («Sottotitoli creati dalla comunità Amara.org»…) si scartano.

Senza modello dal vivo (download non riuscito, telefono con i dati mobili)
si usa il modello scaricato dall'utente come prima: pezzi da ~10 s (9 s
nuovi + 1 s di sovrapposizione), ognuno definitivo appena trascritto
(`LiveWindowPlanner.slow`).

**Scelta del modello e latenza** (misurata su un portatile Intel Core
Ultra 5 226V, 8 core, senza altri lavori in corso, con un audio di prova in
italiano di 58 s sintetizzato con la voce Elsa di Windows, simulando la
registrazione in tempo reale con il `LiveWindowPlanner` dell'app e
`whisper_ggml.dll`, 4 thread):

| Modello | Whisper per finestra (mediana) | Testo provvisorio: ritardo medio / peggiore (90°) | Qualità in italiano |
|---|---|---|---|
| tiny q5_1 (31 MiB) | 0,38 s | 1,4 s / 2,5 s | troppi errori («avariabili», «legga una full», frasi inventate) |
| **base q5_1 (57 MiB)** | **0,77 s** | **1,8 s / 2,9 s** | buona («possiamo separare le variabili e integrare entrambi i membri») |
| small q5_1 (181 MiB) | solo l'encoder 2,5–6 s | oltre 5 s | — |

«Peggiore» è il ritardo della prima parola di ogni tratto nuovo (passo di
2 s più il tempo di Whisper); il testo definitivo arriva in mediana 1,8 s
dopo la fine della frase; il modello si carica in 0,9 s. Base è il modello
più leggero con un italiano leggibile e sta sotto i 3 s. Con il PC già
occupato al 100% (in una prima misura UniNotes trascriveva in parallelo
un'altra registrazione con il vecchio ripiego, `whisper-cli` e
large-v3-turbo) base impiegava 0,9–2,3 s per finestra e il ritardo medio
saliva a 1,9–3,5 s: il passo che si allunga da solo tiene comunque il testo
al passo con il parlato.

Peso: il modello aggiunge ~52 MiB a UniNotes_setup.exe (LZMA2 lo comprime
poco: 59,7 MB → 54,8 MB) e ~54 MiB a UniNotes-windows.zip (56,7 MB).

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
   large-v3-turbo, … small, base, modello integrato, tiny) e RAM necessaria
   al massimo il 60% di quella del PC/Mac o il 40% di quella del telefono
   (`deviceCanRun`); se nessuno regge, il più accurato comunque;
4. senza modelli scaricati, o se il programma whisper.cpp manca (Windows
   senza `whisper-cli`), il **modello integrato**, che gira sempre con
   whisper.cpp dentro l'app.

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

## Accessibilità

Pulsanti grandi (64–96 px nel registratore, 48 px nel riquadro), etichette
per i lettori di schermo su tutti i comandi (anche il riquadro, letto come
«Registrazione in corso: corso, tempo»), pallino che non pulsa con
«Riduci animazioni».
