# UniNotes

App gratuita per gli studenti universitari italiani: **registra le lezioni, trascrivile,
organizza appunti, libri ed esami** del tuo corso di laurea. Funziona su **Windows, macOS,
Android e iOS**. Tutto resta sul dispositivo; la rete serve solo per il database pubblico
dei corsi e per i collegamenti che attivi tu (OneDrive, Google Drive, Gemini, la tua AI). Nessun account,
nessun abbonamento, nessuna pubblicità: solo donazioni libere ([SOSTIENI.md](SOSTIENI.md)).

| Cartella / file | Contenuto |
|---|---|
| [`app/`](app) | App Flutter (Windows, macOS, Android, iOS) |
| [`database/`](database) | Database pubblico: atenei, corsi di studio, insegnamenti, libri, date d'esame ([formato](docs/database_format.md)) |
| [`tools/db_builder/`](tools/db_builder) | Script che costruiscono il database dalle fonti ufficiali |
| [`tools/transcription_test/`](tools/transcription_test) | Test reale della trascrizione (Whisper e Gemini) su audio italiano |
| [`.github/workflows/`](.github/workflows) | `app.yml` build e test · `transcription.yml` test trascrizione |
| [`INSTALLAZIONE.md`](INSTALLAZIONE.md) | **Dove scaricare e come installare** l'app su Android, Windows, macOS, iPhone/iPad |
| [`PRIVACY.md`](PRIVACY.md) | Informativa sulla privacy (aperta dall'app in *Impostazioni → Privacy e informazioni*) |
| [`TERMINI.md`](TERMINI.md) | Termini e condizioni d'uso (aperti dall'app nella stessa sezione) |
| [`docs/`](docs) | Formato del database, formato data pack, OneDrive, Google Drive, specifica Design 3 |

**Scarica l'app**: <https://simo-magnus.github.io/UniNotes/> (riconosce il dispositivo) oppure
[Ultima build](https://github.com/Simo-Magnus/UniNotes/releases/tag/ultima-build) (Windows, macOS, Android, iOS) –
istruzioni per ogni piattaforma in [INSTALLAZIONE.md](INSTALLAZIONE.md).

## Cosa fa l'app

- **Primo avvio**: contrasto e grandezza del testo → tipo di università (statale, non statale,
  a ordinamento speciale, telematica) o ricerca per nome/sigla/città → regione (non per le
  telematiche) → ateneo → tipo di laurea (triennale, professionalizzante, magistrale, magistrale
  a ciclo unico, altro) → corso → anno → download dei dati del solo ateneo scelto e import del
  piano → l'AI con cui studi (diventa l'AI di riferimento) → avvisi (spiegati prima del permesso
  del sistema) → calendario del telefono → gruppi da nascondere (OFA, inglese e lingua
  straniera, corsi facoltativi). Ogni passo ha al massimo due pulsanti. L'anno accademico in
  corso (dal 1° settembre) è il tuo anno; puoi aprire anche gli anni precedenti (*Segna come
  completato*: solo i voti; se mancano voti l'anno risulta *completato parzialmente*) e quelli
  successivi (voti facoltativi).
- **Home**: «Inizia» (Sessione Studio con cronometro o timer, Registra lezione, la tua AI di
  riferimento), prossime prove con lo stato (da prenotare, prenotato), obiettivo di oggi e
  studio della settimana, ultime registrazioni con le trascrizioni fatte, moduli e argomenti,
  libri (scaricati, da procurare, riprendi la lettura).
- **Impostazioni**: in alto *Cambia corso*; il mio percorso (*Aggiorna database* e *Indirizzo
  del database*), calendario, esclusioni, Focus e Non disturbare, aspetto, suoni, notifiche,
  *Esporta/importa dati* (.json), privacy e informazioni con le licenze open source.
- **Registra**: registrazione delle lezioni anche di più ore (schermo spento su Android, in
  background su iOS), trascrizione con **Whisper** (locale) o **Gemini**, riassunti, appunti.
- **Studio**: moduli e argomenti per materia, cronometro, sessioni e statistiche.
- **Libri**: i libri del piano didattico arrivano dal database; accanto al titolo il
  cerchio con la spunta (*tieni*) o con la X (*rimuovi*); puoi aggiungere libri extra a
  ogni insegnamento. Lettore interno.
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

Ciò che manca è segnato *da aggiungere*. Il workflow **Database** lo rigenera ogni anno
(luglio, settembre, gennaio) e apre una pull request; l'app propone l'aggiornamento quando
cambia la versione del database. L'app include solo l'elenco degli atenei e dei corsi
(circa 1 MB): i dati di un ateneo (insegnamenti, libri, date, moduli) li scarica da
internet solo per l'ateneo scelto e li tiene sul dispositivo, anche offline.
Dettagli: [docs/database_format.md](docs/database_format.md).

## Sviluppo

```bash
cd app
flutter pub get
flutter analyze
flutter test                 # ~300 test
flutter run -d windows       # oppure macos, un telefono Android/iOS collegato
```

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

Usando l'app accetti i [Termini e condizioni d'uso](TERMINI.md); come vengono trattati i
dati è spiegato nell'[Informativa sulla privacy](PRIVACY.md).
