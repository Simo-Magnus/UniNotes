<p align="center"><img src="docs/icona.png" alt="Logo di UniNotes" width="128" height="128"></p>

# UniNotes

App gratuita per gli studenti universitari italiani: **registra le lezioni, trascrivile,
organizza appunti, libri ed esami** del tuo corso di laurea. Funziona su **Windows, macOS,
Android e iOS**. Tutto resta sul dispositivo; la rete serve solo per il database pubblico
dei corsi e per i collegamenti che attivi tu (OneDrive, Google Drive, Gemini, la tua AI). Nessun account,
nessun abbonamento, nessuna pubblicità: solo donazioni libere ([SOSTIENI.md](SOSTIENI.md)).

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/K3P8291ENG)

| Cartella / file | Contenuto |
|---|---|
| [`app/`](app) | App Flutter (Windows, macOS, Android, iOS) |
| [`database/`](database) | Database pubblico: atenei, corsi di studio, insegnamenti, libri, date d'esame ([formato](docs/database_format.md)) |
| [`tools/db_builder/`](tools/db_builder) | Script che costruiscono il database dalle fonti ufficiali |
| [`tools/transcription_test/`](tools/transcription_test) | Test reale della trascrizione con Whisper su audio italiano |
| [`.github/workflows/`](.github/workflows) | `app.yml` build e test · `transcription.yml` test trascrizione |
| [`INSTALLAZIONE.md`](INSTALLAZIONE.md) | **Dove scaricare e come installare** l'app su Android, Windows, macOS, iPhone/iPad |
| [`PRIVACY.md`](PRIVACY.md) | Informativa sulla privacy (aperta dall'app in *Impostazioni → Privacy e informazioni*) |
| [`TERMINI.md`](TERMINI.md) | Termini e condizioni d'uso (aperti dall'app nella stessa sezione) |
| [`docs/`](docs) | Formato del database, formato data pack, OneDrive, Google Drive, specifica Design 3 |

**Scarica l'app**: <https://simo-magnus.github.io/UniNotes/> (riconosce il dispositivo) oppure
[Ultima build](https://github.com/Simo-Magnus/UniNotes/releases/tag/ultima-build) (Windows, macOS, Android, iOS) –
istruzioni per ogni piattaforma in [INSTALLAZIONE.md](INSTALLAZIONE.md). Su Windows c'è
l'installatore `UniNotes_setup.exe` (senza amministratore, disinstallazione da «App
installate»), su macOS `UniNotes.dmg` (si trascina UniNotes in Applicazioni); gli zip
restano come alternativa. Per togliere l'app con tutti i suoi dati, anche nel cloud e
nel calendario: prima *Impostazioni → Privacy e informazioni → Elimina tutti i dati*, poi
si disinstalla con il sistema (vedi [INSTALLAZIONE.md](INSTALLAZIONE.md)).

## Cosa fa l'app

- **Primo avvio**: contrasto e grandezza del testo → tipo di università (statale, non statale,
  a ordinamento speciale, telematica) o ricerca per nome/sigla/città → regione (non per le
  telematiche) → ateneo → tipo di laurea (triennale, professionalizzante, magistrale, magistrale
  a ciclo unico, altro) → corso → anno → *Scarica il piano di studi* (solo al tocco: scarica i
  dati del solo ateneo scelto e importa il piano) → l'AI con cui studi (diventa l'AI di
  riferimento) → avvisi (spiegati prima del permesso del sistema) → calendario del telefono
  (Android e iOS; su Windows il calendario Outlook si collega dalle Impostazioni, su macOS
  le prove si aggiungono con un file .ics) → gruppi da nascondere (OFA, inglese e lingua
  straniera, corsi facoltativi). Ogni passo ha al massimo due pulsanti. L'anno accademico in
  corso (dal 1° settembre) è il tuo anno; puoi aprire anche gli anni precedenti (*Segna come
  completato*: solo i voti; se mancano voti l'anno risulta *completato parzialmente*) e quelli
  successivi (voti facoltativi).
- **Home**: il corso di laurea con accanto l'anno di corso (toccandolo si sceglie l'anno
  mostrato in tutte le sezioni), «Inizia» (quanto hai studiato oggi rispetto all'obiettivo,
  Sessione Studio con cronometro o timer, Registra lezione), prossime prove con lo stato (da
  prenotare, prenotato), studio della settimana, ultime registrazioni con le trascrizioni
  fatte, moduli e argomenti di una suddivisione alla volta (semestre, annuale…: si apre
  su quella dell'ultimo argomento cambiato negli ultimi 30 giorni, se ancora in corso,
  altrimenti sul semestre in corso). Si tocca una card per aprirne la sezione; si tocca
  il riquadro di oggi per cambiare l'obiettivo giornaliero.
- **Impostazioni**: il mio percorso con *Cambia corso*, *Aggiorna database* e *Indirizzo
  del database* (senza connessione l'app la chiede, con *Riprova*), calendario, esclusioni, Focus e Non disturbare, aspetto, suoni, notifiche,
  *Esporta/importa dati* (.json), privacy e informazioni con le licenze open source.
- **Registra**: registrazione delle lezioni anche di più ore (schermo spento su Android, in
  background su iOS), testo istantaneo con **Parakeet** (incluso su Windows e Mac) o con
  il riconoscimento vocale del telefono, trascrizione con **Whisper** (locale) o
  **Gemini**, riassunti, appunti.
- **Studio**: moduli e argomenti per materia, cronometro, sessioni e statistiche.
- **Libri**: i libri del piano didattico arrivano dal database; accanto al titolo il
  cerchio con la spunta verde (*salva*: il libro diventa *Salvato*) o con la X (*rimuovi*);
  dal menu di ogni insegnamento *Elimina libri non salvati* toglie quelli senza spunta
  (vanno in *Libri rimossi*, ripristinabili; nessun file eliminato); puoi aggiungere libri
  extra a ogni insegnamento. Lettore interno.
- **Esami**: un esame per insegnamento con CFU e date d'appello se pubblicate, prove in
  itinere, voti, medie ponderate e base di laurea. Lo stato si cambia toccando l'icona
  della prova (da prenotare → prenotato → sostenuto → superato o non superato); il
  dettaglio si modifica toccando le singole voci. Dati mancanti: *Segnala* (apre una
  segnalazione precompilata su GitHub).
- **File**: lettore universale con **Ctrl+F** per PDF, Word, PowerPoint, Excel (anche i
  vecchi .doc/.ppt/.xls), OpenDocument, RTF, Markdown, testo e codice, EPUB/MOBI, immagini,
  audio/video con trascrizione, Xournal++, Excalidraw, mappe mentali, Evernote, archivi ZIP…
- **Collegamenti**: Whisper (tabella dei modelli con peso, RAM, hardware e download diretto),
  Gemini (con il tuo account, anche con l'abbonamento Google AI Pro per studenti), la tua
  **AI di riferimento** (ChatGPT, Claude, Copilot, Perplexity, NotebookLM, Gemini) con
  prompt pronti e file da allegare, **OneDrive** e **Google Drive** in sincronizzazione
  bidirezionale con la cartella che scegli.

## Il database

Costruito automaticamente da fonti pubbliche e ufficiali:

1. **Atenei** – le 4 pagine del MUR (61 statali, 21 non statali, 9 a ordinamento speciale,
   11 telematiche; un ateneo con sedi in più regioni compare in ognuna).
2. **Corsi di studio** – l'offerta formativa pubblicata su Universitaly (MUR/Cineca): tutti
   i ~5.900 corsi dell'a.a. 2026/27.
3. **Insegnamenti per anno, CFU, semestre, docenti, modalità d'esame e libri** – dal
   *Course Catalogue* Cineca degli atenei che lo usano (~50).
4. **Date degli appelli e delle prove parziali** – dalla bacheca appelli pubblica *Esse3*
   (~70 atenei).

Ciò che manca è segnato *da aggiungere*. Il database si rigenera ogni anno (luglio,
settembre, gennaio); l'app propone l'aggiornamento quando cambia la versione del database.
L'app include solo l'elenco degli atenei e dei corsi (circa 1 MB): i dati di un ateneo
(insegnamenti, libri, date, moduli) li scarica da internet solo per l'ateneo scelto e li
tiene sul dispositivo, anche offline.
Dettagli: [docs/database_format.md](docs/database_format.md).

## Sviluppo

```bash
cd app
flutter pub get
flutter analyze
flutter test                 # ~580 test
flutter run -d windows       # oppure macos, un telefono Android/iOS collegato
```

Installatore Windows (serve [Inno Setup](https://jrsoftware.org/isinfo.php), gratuito; in CI
lo fa il job `windows`): dopo `flutter build windows --release`, dalla cartella `app`
`iscc /DAppVersion=2026.9.0 windows\installer\uninotes.iss` → `build\installer\UniNotes_setup.exe`.

```bash
# database (serve internet libero: GitHub Actions o il proprio PC)
pip install -r tools/db_builder/requirements.txt
python tools/db_builder/fetch_mur.py && python tools/db_builder/parse_mur.py
python tools/db_builder/fetch_universitaly.py
python tools/db_builder/fetch_atenei.py --solo unito,unipd   # oppure tutti
python tools/db_builder/build_db.py && python tools/db_builder/sync_assets.py
```

## Licenza

[PolyForm Noncommercial 1.0.0](LICENSE): chiunque può scaricare, usare, copiare,
modificare e ridistribuire gratuitamente l'app, anche in versioni proprie, a
condizione di citare l'autore originale (Simo-Magnus) e la fonte
(<https://github.com/Simo-Magnus/UniNotes>), mantenendo le righe «Required Notice»
del file LICENSE. UniNotes non può essere venduto né usato a scopo commerciale, in
nessuna forma. I dati del database provengono da fonti
pubbliche, indicate per ogni elemento.

### Componenti di terze parti

La licenza PolyForm vale solo per il codice di UniNotes: i componenti di terzi
restano con le loro licenze, elencate nell'app (Impostazioni → Privacy e
informazioni → «Licenze»). In particolare le build per **Windows e macOS**
includono, per il testo istantaneo:

- **NVIDIA Parakeet TDT 0.6B v3** di NVIDIA
  (<https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>), con licenza
  [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).
  **Modificato**: il file incluso è la conversione in ONNX quantizzata int8 fatta
  da [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
  ([csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8](https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8)),
  non i pesi originali. Il testo della licenza (`LICENSE.txt`) e l'avviso con
  attribuzione e modifiche (`NOTICE.txt`) sono accanto ai file del modello
  (`data/parakeet/` su Windows, `UniNotes.app/Contents/Resources/parakeet/` su
  Mac) e in [`app/assets/licenses/`](app/assets/licenses). UniNotes non è
  affiliata a NVIDIA né approvata da NVIDIA; il modello è fornito «così com'è»,
  senza garanzie, e la PolyForm non ne limita l'uso: chi lo riceve può usarlo
  secondo la CC BY 4.0;
- **sherpa-onnx** (Apache-2.0), **ONNX Runtime** (MIT) e **Silero VAD** (MIT);
- **whisper.cpp** (MIT) e il modello **Whisper small** di OpenAI (MIT), nella
  conversione ggml quantizzata q5_1 di whisper.cpp (`ggml-small-q5_1.bin`, dal
  repository [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp)),
  che ritrascrive nella lingua della lezione le frasi che Parakeet scrive in
  un'altra lingua (`data/whisper/` su Windows, `UniNotes.app/Contents/Resources/whisper/`
  su Mac, con `LICENSE.txt`).

Su Android e iOS sono inclusi whisper.cpp (MIT) e il modello Whisper base di
OpenAI (MIT).

Usando l'app accetti i [Termini e condizioni d'uso](TERMINI.md); come vengono trattati i
dati è spiegato nell'[Informativa sulla privacy](PRIVACY.md).
