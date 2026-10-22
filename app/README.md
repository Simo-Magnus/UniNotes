# UniNotes (app Flutter)

App per Windows, macOS, Android e iOS. Documentazione generale nel [README principale](../README.md),
formato dei dati in [docs/datapack_format.md](../docs/datapack_format.md).

Struttura: `lib/core` (database SQLite, servizi, tema, navigazione), `lib/models`,
`lib/repositories`, `lib/features/<sezione>`, `lib/widgets`, `lib/utils`;
negli asset (`assets/database/`) solo l'elenco degli atenei e dei corsi: i dati dell'ateneo scelto
si scaricano (`lib/core/catalog/catalog_service.dart`, cartella `database_cache/`).

## Cartelle di UniNotes

L'app crea solo queste cartelle (nessuna cartella nuova per le funzioni del 2026-10-14):

| Cartella | Dove | Contenuto |
|---|---|---|
| `Appunti` (telefono) o `Documenti\UniNotes\Corsi` (PC, cartella scelta in Collegamenti) | `NotesStore.root` | una cartella per insegnamento con `Registrazioni/` (audio e `.json` con segnalibri, testo dal vivo con i tempi, forma d'onda), `Trascrizioni/` (`<lezione>.md` di Whisper o del riconoscimento dal vivo, `<lezione> (Gemini).md` di Gemini), `Riassunti/`, `Appunti/` (appunti personali), `AI/` (risposte della tua AI); `.eliminati/` nascosta per «Eliminati di recente» |
| `Libri`, `Materiali` | `BookLibrary` | libri e materiali copiati nell'app |
| `Allegati` | `BookLibrary` (`attachmentsLibrary`) | file allegati a moduli e argomenti di Studio, in un'unica cartella |
| `calendario` (supporto dell'app) | `CalendarExport` | file `.ics`, solo su macOS |

Scelte: le trascrizioni istantanee e quelle di Gemini stanno in `Trascrizioni/` accanto a quelle
di Whisper (si distinguono dal nome e dall'intestazione), quindi niente cartella «Gemini»; il
tipo di un allegato (teoria, esercizi, ripasso) è un dato del database e un file può averne più
d'uno, quindi niente sottocartelle per tipo; le Sessioni Studio (cronometro e timer) sono righe
del database (`study_sessions`), senza file. La Home legge le cartelle esistenti senza crearne.

## Avvisi con «Annulla»

Le azioni reversibili mostrano in basso un avviso con **Annulla**
(`showUndoSnackBar` / `showUndoSnackBarOn` in `lib/widgets/undo_snack_bar.dart`): il
pulsante rimette subito le cose com'erano e lo conferma; l'avviso si chiude da solo dopo 6
secondi. Quello che non si può recuperare (togliere un file dal disco) si fa solo alla chiusura
dell'avviso senza «Annulla» (`onCommit`), così l'annullamento è completo. Dove si usa:

- Libri: libro rimosso, ripristinato o salvato (spunta verde); «Elimina libri non salvati»;
  libro eliminato (la copia nell'app si cancella alla chiusura dell'avviso); copia tolta
  dall'app (idem).
- File e lettore: voce tolta dai recenti, «Cancella elenco»; segnalibro aggiunto o eliminato.
- Registrazioni: registrazione eliminata (in corso, dal riquadro o da Registra) e file spostati
  in «Eliminati di recente»; ripristino da «Eliminati di recente»; segnalibri del lettore delle
  registrazioni (aggiunto/tolto); testo salvato da Gemini (torna il file di prima).
- Studio: sessione eliminata (torna con lo stesso id); allegato rimosso (la copia si cancella
  alla chiusura dell'avviso).
- Esami e insegnamenti: prova eliminata (torna con lo stesso id e l'insegnamento a scelta nel
  piano); «Segna tutti come sostenuti» degli anni precedenti; insegnamento tolto dagli elenchi
  (archiviato); nome dell'insegnamento cambiato.
- Impostazioni: «Ripristina le domande» (tornano le scelte «Non chiedere più»).

Senza «Annulla» (si conferma prima, perché non si torna indietro in modo completo): eliminazione
di un insegnamento con tutti i dati, di un modulo, degli argomenti e di «Rimuovi tutti i moduli»
(gli allegati copiati si cancellano e le sessioni restano senza modulo/argomento), insegnamenti
nascosti o rimessi dalle esclusioni del piano (riscaricano il piano), eliminazione definitiva da
«Eliminati di recente».

## Lettore universale e sezione File

`lib/features/reader/` apre nell'app qualsiasi file di appunti: `openInReader(context, path)`
(o il widget `ReaderScreen`). La sezione **File** mostra le cartelle dell'app (Appunti, Libri,
Materiali, Allegati) con i conteggi, i file recenti, la ricerca per nome in tutte le cartelle
e, su desktop, il trascinamento di un file nella finestra (non c'è più «Apri un file…»: la
sezione mostra i file dell'app). Libri, materiali,
allegati di Studio si aprono qui (le registrazioni hanno il loro lettore, con forma d'onda, segnalibri e
testo sincronizzato: vedi [docs/registratore.md](../docs/registratore.md)); **Apri con…** resta nel menu.

**Recenti**: l'app ricorda gli ultimi 50 file aperti nel lettore e ne mostra 20 (circa due
settimane di studio: dispense, libri e registrazioni dei corsi del semestre, senza allungare
troppo la pagina sul telefono); «Mostra altri» apre il resto. Ogni voce si toglie con la X.

**Apri con…** (menu del lettore e avviso dei formati semplificati) mostra la scelta dell'app del
sistema anche quando per quel tipo di file c'è già un'app predefinita: Windows «Come vuoi aprire
questo file?» (`SHOpenWithDialog` con `OAIF_ALLOW_REGISTRATION | OAIF_EXEC`,
`windows/runner/open_with.cpp`; senza il canale `rundll32 shell32.dll,OpenAs_RunDLL`), macOS un
pannello sulla cartella Applicazioni e poi `NSWorkspace` (`UniNotesOpenWith` in
`MainFlutterWindow.swift`), Android `Intent.createChooser` con il FileProvider di open_filex
(`OpenWith.kt`), iOS il menu «Apri in…» (`UIDocumentInteractionController`, `UniNotesOpenWith` in
`AppDelegate.swift`), Linux `gio open` (l'app predefinita: non c'è una scelta comune ai desktop).
Canale `io.github.simomagnus.universitynotes/apri_con`, metodo `openWith {path}` → "ok",
"annullato", "nessuna_app" o "errore" (`ExternalLauncher.openWith`). «Apri con l'app
predefinita» (pagina dei file non mostrabili) e i collegamenti ai file restano l'app predefinita.

### Resa dei formati: completa, semplificata, non supportata

Ogni formato ha una resa (`ReaderFormat.fidelity`): **completa**, **semplificata** (campo
`limited`: cosa l'app non mostra) o **non supportata** (solo «Apri con…»). Anche un file di un
formato a resa completa può avere parti che l'app non disegna (`RDoc.limits`: grafici, SmartArt
senza disegno, formule, immagini EMF/WMF/SVM, oggetti incorporati). In questi casi, all'apertura,
la finestra «Anteprima semplificata» (`reader_fidelity.dart`) dice cosa manca e propone due
pulsanti: «Vedi anteprima semplificata» e «Apri con un'altra app» (scelta dell'app del sistema;
il lettore si chiude). Con «Non chiedere più» la scelta vale per l'estensione
(`dont_ask_reader_partial_<estensione>` = `external`, che poi apre subito con l'app predefinita,
o `preview`) e si annulla da Impostazioni → «Ripristina le domande». In «Formati supportati» le
estensioni semplificate hanno «(semplificato)».

| Resa | Formati |
|---|---|
| Completa | .pdf; .docx .docm .dotx .dotm .odt .ott .rtf; .pptx .pptm .ppsx .ppsm .potx .odp .otp (diapositive disegnate); .xlsx .xlsm .xltx .ods .ots .csv .tsv; testo, markup e codice; .ipynb; .epub .mobi .azw .azw3 .prc .fb2 .cbz .cbr .djvu .djv; immagini; audio e video; .xopp .xoj .excalidraw .inkml .isf .ink; .enex .mm .opml; .zip .rar. Chiede comunque se il singolo file ha grafici, SmartArt senza disegno, formule, immagini EMF/WMF/SVM o oggetti incorporati |
| Semplificata (chiede) | .doc .dot (solo testo); .ppt .pps .pot (testo e, in fondo, le immagini); .xls .xlt (solo valori); .ps .eps; .pages .key .numbers (anteprima salvata da Apple); .xps .oxps (solo testo); .kfx .kfx-zip .kpf (solo testo); .acsm (token per Adobe Digital Editions); .goodnotes .note .notability (PDF e immagini incorporati); .one (testo e immagini senza impaginazione); .onepkg (elenco delle sezioni); .canvas (schede in elenco) |
| Non supportata | ogni altra estensione: informazioni sul file, «Apri con l'app predefinita», «Condividi» |

Verifica su file veri (`test/fixtures/office/`, salvati da PowerPoint ed Excel: presentazione
semplice, tema «Facet» con forme dello schema e del layout, gruppo, rotazione e ritaglio, la
stessa presentazione in .odp e in .ppt, fogli .xlsx con e senza grafico, .xls, .ods; l'autore nei
metadati è sostituito con «UniNotes»): le diapositive disegnate dall'app sono state confrontate
con le immagini esportate da PowerPoint (stesse posizioni, colori, sfondi, elenchi, tabelle e
immagini; cambia solo il carattere, quello dell'app). Test in `test/reader_fidelity_test.dart`.

La tabella dei formati è `reader_formats.dart` (`kReaderFormats`, una riga per estensione con
famiglia e vista): è anche l'elenco di controllo verificato da `test/reader_formats_test.dart`.

| Famiglia | Estensioni | Vista |
|---|---|---|
| PDF | .pdf | pdfrx: ricerca nel testo, indice del PDF, riapre all'ultima pagina |
| Documenti | .docx .docm .dotx .dotm .odt .ott .rtf | documento (titoli → indice, elenchi, tabelle, immagini; pagine dai salti pagina di Word) |
| | .doc .dot (Word 97–2003) | solo testo, dal contenitore OLE2 (FIB → CLX) |
| | .pages | PDF/immagine d'anteprima incorporati, altrimenti "Apri con…" |
| | .ps .eps (PostScript) | testo delle stringhe passate a show/ashow/widthshow/xshow/… (una sezione per showpage); EPS: anteprima TIFF (intestazione DOS) o EPSI; i disegni richiedono un interprete |
| Presentazioni | .pptx .pptm .ppsx .ppsm .potx | diapositive disegnate come nell'originale (`parsers/pptx_slides.dart`, vista `views/slide_view.dart`): sfondo, forme e immagini dello schema e del layout, segnaposto con posizioni e stili ereditati, caselle di testo (dimensioni, colori del tema, allineamento, elenchi puntati e numerati, adattamento), immagini anche ritagliate, forme predefinite con le regolazioni e a mano libera, linee, gruppi, rotazioni, tabelle con lo stile, SmartArt dal disegno salvato, formule dall'immagine di ripiego; grafici, EMF/WMF e oggetti → riquadro con il nome e domanda all'apertura; testo cercabile, a tutto schermo con zoom; note del relatore sotto. Se una forma non ha posizione: testo in sequenza |
| | .odp .otp | pagine disegnate (`parsers/odp_slides.dart`): sfondo, forme dello schema, riquadri di testo, elenchi, immagini, forme di LibreOffice (preimpostate e tracciati semplici), linee, gruppi, rotazioni, tabelle; formule e grafici → domanda all'apertura |
| | .ppt .pps .pot (97–2003) | testo (TextCharsAtom/TextBytesAtom) e, in fondo, le immagini PNG/JPEG del flusso Pictures |
| | .key | anteprima incorporata |
| Fogli di calcolo | .xlsx .xlsm .xltx .ods .ots .csv .tsv | tabelle con schede dei fogli, date e numeri formattati |
| | .xls .xlt (BIFF8) | valori (SST, LABELSST, NUMBER, RK, formule calcolate) |
| | .numbers | anteprima incorporata |
| Testo e markup | .txt .md .markdown .html .htm .xhtml .xml .json .yaml .yml .toml .ini .tex .bib .rst .org .adoc .log .srt .vtt | testo; Markdown formattato; titoli di LaTeX/rst/Org/AsciiDoc nell'indice; sottotitoli con i tempi |
| | .md (Obsidian, Zettelkasten) | `[[nota]]` e `[[nota\|alias]]` aprono l'altra nota della cartella (o di una sottocartella del vault), `![[immagine.png]]` e `![](immagine)` incorporate, `#etichette` (toccandole si cercano), tabelle con `\|` |
| Codice | .py .java .c .cpp .h .hpp .cs .js .ts .tsx .jsx .dart .kt .swift .m .r .rmd .sql .sh .ps1 .bat .go .rs .rb .php .lua .scala .hs .jl .css .asm .vhd .v .f90 … | spaziatura fissa |
| | .ipynb | celle Markdown, codice e risultati (testo e immagini) |
| E-book | .epub | capitoli dallo spine, immagini, indice da nav/NCX; EPUB 3 a impaginazione fissa (una pagina per elemento, immagini SVG), MathML (testo alternativo), audio/video segnalati; DRM Adobe/LCP/Apple → spiegazione di quale app usare |
| | .mobi .azw .azw3 .prc | PalmDOC senza DRM (DRM → avviso) |
| | .kfx .kfx-zip .kpf | con DRM (`DRMION`) → spiegazione (app Kindle, la protezione non si toglie); senza DRM: testo dei frammenti in Amazon Ion binario (niente immagini, stili, indice) |
| | .acsm | token di Adobe: titolo, autore, editore, formato, scadenza e come scaricare il libro con Adobe Digital Editions ("Apri con…") |
| | .djvu .djv | decodificatore DjVu nell'app (`djvu/`, dalla specifica DjVu v3): ZP-Coder, BZZ, JB2 (con dizionari condivisi e raffinamento), IW44 progressivo, colori FGbz, sfondi e primi piani JPEG; documenti raggruppati con segnalibri NAVM; testo nascosto cercabile con le parole evidenziate sulla pagina; pagine disegnate una alla volta in un isolate, ridotte per le scansioni grandi; documenti indiretti → spiegazione; maschere MMR (Smmr) non supportate |
| | .fb2 .cbz .cbr .xps .oxps | FictionBook; fumetti come pagine (.cbr con `koni_rar`, anche RAR5); testo dei glifi XPS |
| Immagini | .png .jpg .jpeg .gif .webp .bmp .ico .svg .tif .tiff .tga .heic .heif | zoom e trascinamento; TIFF/TGA convertiti; HEIC con il decodificatore del sistema |
| Audio | .mp3 .m4a .aac .wav .flac .ogg .oga .opus .wma .aiff .amr | media_kit: riproduci/pausa, posizione, ±10/30 s, velocità 0,5–3×; trascrizione con lo stesso nome (.srt .vtt .md .txt, anche in `../Trascrizioni/`) cercabile, tempi toccabili |
| Video | .mp4 .m4v .mov .mkv .webm .avi .wmv .3gp .mpg .mpeg | come l'audio, con l'immagine |
| Appunti a mano | .xopp .xoj .excalidraw | pagine con tratti (pressione), forme, immagini; testi cercabili |
| | .inkml .isf .ink (Windows Ink) | InkML (tracce con differenze prime/seconde, pennelli); ISF (attributi di disegno, punti compressi "Gorilla" o con i codici di Huffman predefiniti, delta-delta); altre compressioni → messaggio e "Apri con…" |
| | .goodnotes .note .notability (Notability) | PDF e immagini incorporati |
| App di appunti | .enex | una sezione per nota (ENML, immagini, caselle) |
| | .mm .opml | scaletta pieghevole |
| | .canvas (Obsidian) | schede in ordine e collegamenti |
| | .one | testo e immagini estratti senza impaginazione (euristica documentata in `parsers/onenote.dart` sul formato MS-ONESTORE), con i pulsanti "OneNote" (Microsoft Graph) e "Apri con…" |
| | .onepkg | pacchetto CAB (non compresso o MSZIP): elenco delle sezioni, ognuna si apre |
| | Apple Notes | nessun formato di file: esporta in PDF o testo (indicato in "Formati supportati") |
| Archivi | .zip .rar | elenco; ogni voce si apre nel lettore (le note di uno ZIP, es. un'esportazione di Notion, si estraggono con tutto l'archivio: pagine annidate, immagini e tabelle CSV funzionano) |
| Altro | qualsiasi | informazioni sul file, "Apri con l'app predefinita", "Condividi" |

Un file senza estensione nota viene riconosciuto dai primi byte (PDF, ZIP, RAR, OLE2, DjVu,
OneNote, KFX, PostScript, immagini, audio, RTF, testo, ...). I PDF con DRM di Adobe (ADEPT) o
FileOpen mostrano una spiegazione: l'app non toglie mai le protezioni.

Pacchetti per i formati: `koni_rar` e `koni_archive_core` (MIT, lettore RAR puro Dart; il file
NOTICE del pacchetto riporta le attribuzioni BSD di libarchive e rardecode). Il decodificatore
DjVu è scritto nell'app dalla specifica pubblica (nessun codice di DjVuLibre); i file di prova in
`test/fixtures/djvu/` si rigenerano con `make_fixtures.sh` (strumenti DjVuLibre).

Funzioni del lettore, uguali per tutti i formati:

- **Ctrl+F / ⌘F** (o la lente nella barra): evidenzia tutti i risultati, "3 di 17",
  Invio/F3 successivo, Maiusc+Invio/Maiusc+F3 precedente, Esc chiude; senza maiuscole né
  accenti ("perche" trova "perché"); porta in vista il risultato (nel PDF va alla pagina).
- Zoom: Ctrl + / Ctrl − / Ctrl 0, pizzico sul telefono; testo a tutta larghezza.
- Indice (PDF, EPUB, titoli di Word/Markdown, diapositive, fogli) e **segnalibri** del file nel
  pannello laterale (Ctrl+D aggiunge); **Vai a** pagina/diapositiva/foglio (Ctrl+G).
- Riapre dall'ultima posizione: per i PDF di libri e materiali nel catalogo, per gli altri file
  nelle impostazioni (`reader:<hash di percorso e dimensione>`, vedi `reader_store.dart`).
- Selezione e copia del testo, "Copia tutto il testo", Condividi, Apri con…, schermo intero (F11).
- Tema chiaro/scuro dell'app; i documenti stanno su una superficie di lettura piena.

Impostazione nativa del lettore multimediale (`media_kit`, `media_kit_video`,
`media_kit_libs_video`): nulla su Windows, Android e iOS; su macOS la sandbox ha
`com.apple.security.files.user-selected.read-write` per i file scelti (serve anche
`com.apple.security.network.client` solo per flussi in rete); su Linux serve `libmpv`
(`sudo apt install libmpv-dev`). Nei test (`FLUTTER_TEST`) il lettore non si inizializza.
