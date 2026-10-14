# Registratore delle lezioni

Il registratore (sezione **Registra**) funziona come l'app Memo Vocali di
iOS, con la trascrizione dal vivo come la registrazione audio nell'app Note.
Tutto avviene sul dispositivo: l'audio e il testo non lasciano il telefono o
il PC finché non scegli di sincronizzarli o di mandarli a Gemini.

Codice: `app/lib/features/notes/` (`lecture_recorder.dart`,
`recorder_screen.dart`, `recording_player_screen.dart`,
`recently_deleted_screen.dart`, `transcript_search_screen.dart`,
`recycle_bin.dart`, `course_notes_screen.dart`, `lesson_transcripts.dart`)
e `app/lib/features/notes/recorder/` (WAV, trascrizione dal vivo con
`system_speech.dart` e `live_transcriber.dart`, salvataggio, riquadro sopra
le schermate, controlli in background). Riconoscimento vocale del sistema:
`app/android/.../LiveSpeech.kt`, `app/ios/Runner/LiveSpeech.swift` (uguale in
`app/macos/Runner/`), `app/windows/runner/live_speech.cpp`. Conversioni
audio: `app/lib/core/services/audio_codec.dart` e, su Windows,
`app/windows/runner/audio_transcoder.cpp`. Test:
`app/test/recorder_logic_test.dart`, `app/test/recorder_speech_test.dart` e
`app/test/recording_overlay_test.dart`.

## Mentre registri

- **Tempo** e **forma d'onda** in tempo reale (livello calcolato dall'audio,
  10 valori al secondo).
- **Pausa / Riprendi**: il pulsante grande.
- **Segna**: segnalibro al tempo attuale; dall'avviso «Aggiungi nota» si
  scrive una nota facoltativa (l'avviso funziona anche se nel frattempo si è
  usciti dal registratore). I segnalibri compaiono sotto i pulsanti (tocco →
  nota o rimozione).
- **Trascrizione**: la card mostra il parlato trascritto **istantaneamente**,
  come Memo Vocali o la digitazione vocale di Google Docs: il testo
  provvisorio (più chiaro) si aggiorna mentre si parla e diventa definitivo
  a ogni frase. Vedi [Trascrizione dal vivo](#trascrizione-dal-vivo). Se il
  sistema non offre il riconoscimento e Whisper non è installato la
  registrazione funziona lo stesso e la card spiega perché e come attivarlo.
- **Salva**: ferma, salva e porta alla **pagina del corso**, alla card
  «Registrazioni delle lezioni» (la registrazione nuova è evidenziata), non
  al lettore.

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
- si **allarga o stringe** con la maniglia a destra, fino alla larghezza
  minima in cui i tre pulsanti restano visibili (il testo si accorcia,
  l'indicatore del microfono sparisce);
- ha un **fondo scuro quasi opaco** (chiaro nel tema chiaro), leggibile
  anche sopra altri testi;
- un tocco riporta al registratore.

Solo la **X** chiede «Salvare la registrazione?» con due pulsanti, Elimina
(con una seconda conferma, in rosso) e Salva; toccando fuori dal dialogo la
registrazione continua. Dopo «Salva» dal riquadro, l'avviso «Apri» porta
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

Come Memo Vocali e la digitazione vocale di Google Docs, il testo compare
mentre si parla grazie al **riconoscimento vocale in streaming del sistema**
(Whisper a pezzi da 10 s non può dare il testo istantaneo: resta come
ripiego). Lingua: quella dell'insegnamento se nota (es. inglese per gli
insegnamenti in inglese), altrimenti l'italiano. Il riconoscitore riceve
**l'audio della registrazione** e non apre il microfono per conto suo
(tranne su Windows, dove il microfono è condiviso): la registrazione non
viene mai interrotta né bloccata da un suo errore.

| Sistema | Motore | Note |
|---|---|---|
| iOS / macOS 26+ | `SpeechAnalyzer` + `SpeechTranscriber` | sul dispositivo, il sistema scarica il modello della lingua la prima volta |
| iOS / macOS precedenti | `SFSpeechRecognizer` con `SFSpeechAudioBufferRecognitionRequest` | sul dispositivo quando la lingua lo permette (`supportsOnDeviceRecognition`), altrimenti in rete; una richiesta si chiude in una pausa dopo ~30 s (al massimo 55 s, limite di un minuto del servizio in rete) e se ne apre subito un'altra |
| Android 13+ | `SpeechRecognizer` con risultati parziali, `createOnDeviceSpeechRecognizer` dove c'è | l'audio arriva da una pipe (`EXTRA_AUDIO_SOURCE`, PCM 16 bit mono 16 kHz) con sessione segmentata; se il riconoscitore sul dispositivo non ha la lingua si passa a quello normale |
| Android 12 e precedenti | — | non si può passare l'audio al riconoscitore: aprirebbe il microfono in concorrenza con la registrazione (su molti telefoni la zittirebbe). Si usa Whisper |
| Windows 10/11 | `Windows.Media.SpeechRecognition`, dettatura continua | ascolta il microfono predefinito in modalità condivisa; serve «Riconoscimento vocale online» (Impostazioni → Privacy e sicurezza → Voce) e la lingua installata, altrimenti Whisper |
| Linux | — | Whisper |

Permessi: iOS e macOS chiedono il permesso del riconoscimento vocale la prima
volta (`NSSpeechRecognitionUsageDescription` nell'Info.plist, oltre a
`NSMicrophoneUsageDescription`); su Android basta il microfono. Il testo
provvisorio e quello definitivo arrivano sul canale
`io.github.simomagnus.universitynotes/speech` (`partial`, `result`); un
errore definitivo (`error` con `fatal`) fa passare a Whisper dal punto in
cui si è, senza perdere il testo già riconosciuto. I tempi dei segmenti sono
quelli della registrazione (inizio ~1 s prima del primo testo provvisorio,
fine all'arrivo del testo definitivo). Alla fine («Salva») si attende al
massimo 2 s l'ultimo testo, poi quello ancora provvisorio diventa definitivo.

**Ripiego con Whisper** (dove il sistema non offre nulla): ogni ~9 secondi di
audio nuovo il registratore legge dal WAV di lavoro l'ultimo pezzo (circa
10 s, con 1 s di sovrapposizione col precedente) e lo passa al motore
Whisper già usato dall'app:

- telefono (e Mac senza `whisper-cli`): `whisper_ggml` in un isolate
  separato, modello tenuto in memoria fra un pezzo e l'altro, pochi thread;
- PC e Mac con Homebrew: `whisper-cli` come processo separato.

Il lavoro non blocca mai la registrazione: un pezzo alla volta, e se Whisper
resta indietro i pezzi in attesa più vecchi si saltano (il testo resta al
passo col parlato) e si recuperano dopo il salvataggio (operazione
«Completo la trascrizione», visibile nella card della registrazione). I
pezzi silenziosi non vanno a Whisper e le frasi che Whisper inventa sul
silenzio («Sottotitoli creati dalla comunità Amara.org»…) si scartano. Il
testo dei pezzi si unisce senza ripetere le parole della sovrapposizione.

Modello usato dal vivo, fra quelli scaricati: telefono `small`, poi `base`,
`large-v3-turbo-q5_0`…; PC `large-v3-turbo-q5_0`, poi `small`,
`medium-q5_0`…

## Salvataggio e formati

| | Formato |
|---|---|
| Registrazione salvata | `.m4a` AAC mono, ~48 kbit/s (~21 MB per ora). Su Windows si usa il formato del codificatore di sistema più vicino (stessi canali, frequenza uguale o subito superiore, bitrate più vicino a 48 kbit/s) |
| Se la compressione non riesce | resta il WAV (16 kHz mono, ~115 MB per ora): mai perdere la registrazione |
| Registrazioni precedenti | `.flac`, `.wav`, `.m4a`: restano leggibili e trascrivibili |
| Dati della registrazione | `Registrazioni/<nome>.json`: segnalibri, segmenti della trascrizione con inizio e fine, forma d'onda (un valore ogni 0,1 s), durata. Si rinomina, si sincronizza e va nel cestino con l'audio; non compare negli elenchi |
| Trascrizione | `Trascrizioni/<nome>.md` (Whisper, o il testo dal vivo), lo stesso formato di sempre (un paragrafo ogni ~2 minuti con `[hh:mm:ss]`; l'intestazione dice chi l'ha fatta). I tempi precisi dei segmenti sono nel `.json`; per le trascrizioni senza `.json` il lettore usa i tempi dei paragrafi |
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
  trascrizione»**, azzurra per Whisper e viola per Gemini, e apre la
  registrazione con quella trascrizione («Trascrizione con Whisper» o «con
  Gemini»). Il testo dal vivo del sistema non occupa la casella di Whisper:
  si legge nella registrazione e Whisper resta disponibile;
- se Whisper non riesce non compare una card d'errore: la card della
  registrazione dice «Impossibile trascrivere con Whisper: …» con cosa
  provare (scaricare un modello, un modello più piccolo, Gemini…);
- operazioni in corso (Whisper, Gemini, «Completo la trascrizione», taglio)
  con la barra di avanzamento nella card.

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
  vista, un tocco su un segmento salta a quel punto;
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
eliminato per ultimo. Le cartelle che iniziano con «.» non si sincronizzano: su OneDrive e
Google Drive il file eliminato va nel cestino del servizio, come prima.

## Accessibilità

Pulsanti grandi (64–96 px nel registratore, 48 px nel riquadro), etichette
per i lettori di schermo su tutti i comandi (anche il riquadro, letto come
«Registrazione in corso: corso, tempo»), pallino che non pulsa con
«Riduci animazioni».
