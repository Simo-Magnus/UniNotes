# UniNotes (app Flutter)

App Android + Windows del progetto. Documentazione generale nel [README principale](../README.md),
formato dei dati in [docs/datapack_format.md](../docs/datapack_format.md).

Struttura: `lib/core` (database SQLite, servizi, tema, navigazione), `lib/models`,
`lib/repositories`, `lib/features/<sezione>`, `lib/widgets`, `lib/utils`;
seed dei dati pubblici in `assets/data/seed_datapack.json`.

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

## Lettore universale e sezione File

`lib/features/reader/` apre nell'app qualsiasi file di appunti: `openInReader(context, path)`
(o il widget `ReaderScreen`). La sezione **File** mostra le cartelle dell'app (Appunti, Libri,
Materiali, Allegati) con i conteggi, i file recenti, la ricerca per nome in tutte le cartelle
e, su desktop, il trascinamento di un file nella finestra (non c'è più «Apri un file…»: la
sezione mostra i file dell'app). Libri, materiali,
allegati di Studio si aprono qui (le registrazioni hanno il loro lettore, con forma d'onda, segnalibri e
testo sincronizzato: vedi [docs/registratore.md](../docs/registratore.md)); **Apri con…** resta nel menu.

La tabella dei formati è `reader_formats.dart` (`kReaderFormats`, una riga per estensione con
famiglia e vista): è anche l'elenco di controllo verificato da `test/reader_formats_test.dart`.

| Famiglia | Estensioni | Vista |
|---|---|---|
| PDF | .pdf | pdfrx: ricerca nel testo, indice del PDF, riapre all'ultima pagina |
| Documenti | .docx .docm .dotx .dotm .odt .ott .rtf | documento (titoli → indice, elenchi, tabelle, immagini; pagine dai salti pagina di Word) |
| | .doc .dot (Word 97–2003) | solo testo, dal contenitore OLE2 (FIB → CLX) |
| | .pages | PDF/immagine d'anteprima incorporati, altrimenti "Apri con…" |
| | .ps .eps (PostScript) | testo delle stringhe passate a show/ashow/widthshow/xshow/… (una sezione per showpage); EPS: anteprima TIFF (intestazione DOS) o EPSI; i disegni richiedono un interprete |
| Presentazioni | .pptx .pptm .ppsx .ppsm .potx .odp .otp | una sezione per diapositiva, note del relatore |
| | .ppt .pps .pot (97–2003) | solo testo (TextCharsAtom/TextBytesAtom) |
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
`com.apple.security.files.user-selected.read-only` per i file scelti (serve anche
`com.apple.security.network.client` solo per flussi in rete); su Linux serve `libmpv`
(`sudo apt install libmpv-dev`). Nei test (`FLUTTER_TEST`) il lettore non si inizializza.
