# Lettore: file rovinati, enormi o illeggibili

Il lettore (`app/lib/features/reader/`) non deve mai chiudere l'app né restare
sulla rotella: un file che non si riesce a mostrare diventa una pagina con il
motivo, «Apri con…» e «Condividi».

## Limiti

| Cosa | Limite | Dove |
|---|---|---|
| File caricato in memoria per l'anteprima (non PDF, audio, video, immagini comuni) | 200 MB su telefono, 600 MB su computer | `readerMaxBytes`, `reader_loader.dart` |
| Analisi in un isolate (file oltre 384 KB) | 2 minuti, poi l'isolate si ferma | `readerParseTimeout`, `runIsolated` |
| Voce di un archivio decompressa (ZIP, RAR, CAB, anche con dimensione falsa nell'indice) | 512 MB | `Zip.maxEntryBytes`, `inflateRaw` |
| Immagine decodificata | 4096 px di lato (2048 nel testo dei documenti) | `limitedImage`, `views/image_view.dart` |
| TIFF/TGA/ICO convertiti | 80 Mpixel in ingresso, 4096 px in uscita | `_toPng` |
| Pagina DjVu disegnata | 64 Mpixel; IW44 50 Mpixel; forme JB2 16384 px | `djvu/` |
| Livelli di una scaletta / mappa mentale | 64 | `kOutlineMaxDepth` |
| Annidamento HTML (EPUB, Evernote, pagine) | 300 livelli | `HtmlBlocks` |
| Testo di un elemento della vista | 6000 caratteri per pezzo, celle 2000, 1000 colonne | `DocumentView` |

## Messaggi

- permesso negato, file in uso, file sparito: `fileErrorMessage`;
- file troppo grande o troppo lento da leggere: si propone un'altra app;
- file danneggiato: `unreadableMessage` (in italiano, con il dettaglio del
  parser solo quando è utile, mai `RangeError` o simili).

## Fuzz

- `app/test/reader_fuzz_test.dart`: ogni parser con file vuoti, troncati, byte
  casuali, interi enormi, voci ZIP rovinate, XML/JSON/RTF annidati, righe
  enormi; ogni caso in un isolate con un tempo massimo.
- `app/test/reader_view_fuzz_test.dart`: i documenti ottenuti si mostrano,
  si cercano, si sfogliano e si ingrandiscono senza errori di impaginazione.
- Giri più lunghi: `READER_FUZZ_ROUNDS=20`, `READER_FUZZ_SEED=3`,
  `READER_FUZZ_ONLY=.djvu,.docx`, `READER_FUZZ_KEEP=<cartella>` (salva i casi).
- I casi trovati sono in `app/test/reader_crash_test.dart`.
