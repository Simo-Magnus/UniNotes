/// Formati del lettore: UNA tabella con ogni estensione supportata, la
/// famiglia e la vista che la mostra. È anche l'elenco di controllo (vedi
/// README e i test): un'estensione non in tabella va in "Informazioni file"
/// con "Apri con…".
library;

import 'package:path/path.dart' as p;

enum ReaderFamily {
  pdf('PDF'),
  word('Documento'),
  presentation('Presentazione'),
  spreadsheet('Foglio di calcolo'),
  text('Testo'),
  code('Codice'),
  ebook('E-book'),
  image('Immagine'),
  audio('Audio'),
  video('Video'),
  handwriting('Appunti a mano'),
  notes('App di appunti'),
  archive('Archivio'),
  other('File');

  const ReaderFamily(this.label);
  final String label;
}

/// Vista che mostra il formato.
enum ReaderViewer {
  /// PDF con pdfrx (ricerca nel testo, indice, zoom).
  pdf,

  /// Pagine DjVu decodificate nell'app, una alla volta (testo nascosto
  /// cercabile, segnalibri, zoom).
  djvu,

  /// Documento di testo strutturato (paragrafi, titoli, tabelle, immagini).
  document,

  /// Immagine singola con zoom e trascinamento.
  image,

  /// Lettore audio/video (media_kit), con la trascrizione se c'è.
  media,

  /// Tratti e forme su pagine (Xournal++, Excalidraw).
  ink,

  /// Scaletta pieghevole (mappe mentali, OPML).
  outline,

  /// Contenuto di un archivio (ZIP, RAR, CAB).
  archive,

  /// Contenitore: PDF o immagini d'anteprima incorporati, se ci sono.
  container,

  /// Nessuna vista: informazioni sul file, "Apri con…", "Condividi".
  info,
}

class ReaderFormat {
  const ReaderFormat(
    this.extension,
    this.label,
    this.family,
    this.viewer, {
    this.note,
  });
  final String extension;
  final String label;
  final ReaderFamily family;
  final ReaderViewer viewer;

  /// Limiti noti (mostrati nelle informazioni del file).
  final String? note;

  bool get supported => viewer != ReaderViewer.info;
}

const _f = ReaderFamily.code;
const _d = ReaderViewer.document;

/// Tutti i formati riconosciuti.
const List<ReaderFormat> kReaderFormats = [
  // PDF
  ReaderFormat('.pdf', 'PDF', ReaderFamily.pdf, ReaderViewer.pdf),
  // Documenti di testo
  ReaderFormat('.docx', 'Word', ReaderFamily.word, _d),
  ReaderFormat('.docm', 'Word con macro', ReaderFamily.word, _d),
  ReaderFormat('.dotx', 'Modello Word', ReaderFamily.word, _d),
  ReaderFormat('.dotm', 'Modello Word con macro', ReaderFamily.word, _d),
  ReaderFormat(
    '.doc',
    'Word 97–2003',
    ReaderFamily.word,
    _d,
    note: 'Solo testo',
  ),
  ReaderFormat(
    '.dot',
    'Modello Word 97–2003',
    ReaderFamily.word,
    _d,
    note: 'Solo testo',
  ),
  ReaderFormat('.odt', 'Testo OpenDocument', ReaderFamily.word, _d),
  ReaderFormat('.ott', 'Modello OpenDocument', ReaderFamily.word, _d),
  ReaderFormat('.rtf', 'Rich Text', ReaderFamily.word, _d),
  ReaderFormat(
    '.ps',
    'PostScript',
    ReaderFamily.word,
    _d,
    note: 'Solo il testo (i disegni richiedono un interprete PostScript)',
  ),
  ReaderFormat(
    '.eps',
    'PostScript incapsulato',
    ReaderFamily.word,
    _d,
    note: 'Anteprima incorporata (TIFF o EPSI) e testo',
  ),
  ReaderFormat(
    '.pages',
    'Apple Pages',
    ReaderFamily.word,
    ReaderViewer.container,
    note: 'Anteprima incorporata',
  ),
  // Presentazioni
  ReaderFormat('.pptx', 'PowerPoint', ReaderFamily.presentation, _d),
  ReaderFormat('.pptm', 'PowerPoint con macro', ReaderFamily.presentation, _d),
  ReaderFormat(
    '.ppsx',
    'Presentazione PowerPoint',
    ReaderFamily.presentation,
    _d,
  ),
  ReaderFormat(
    '.ppsm',
    'Presentazione PowerPoint con macro',
    ReaderFamily.presentation,
    _d,
  ),
  ReaderFormat('.potx', 'Modello PowerPoint', ReaderFamily.presentation, _d),
  ReaderFormat(
    '.ppt',
    'PowerPoint 97–2003',
    ReaderFamily.presentation,
    _d,
    note: 'Solo testo',
  ),
  ReaderFormat(
    '.pps',
    'Presentazione PowerPoint 97–2003',
    ReaderFamily.presentation,
    _d,
    note: 'Solo testo',
  ),
  ReaderFormat(
    '.pot',
    'Modello PowerPoint 97–2003',
    ReaderFamily.presentation,
    _d,
    note: 'Solo testo',
  ),
  ReaderFormat(
    '.odp',
    'Presentazione OpenDocument',
    ReaderFamily.presentation,
    _d,
  ),
  ReaderFormat(
    '.otp',
    'Modello di presentazione OpenDocument',
    ReaderFamily.presentation,
    _d,
  ),
  ReaderFormat(
    '.key',
    'Apple Keynote',
    ReaderFamily.presentation,
    ReaderViewer.container,
    note: 'Anteprima incorporata',
  ),
  // Fogli di calcolo
  ReaderFormat('.xlsx', 'Excel', ReaderFamily.spreadsheet, _d),
  ReaderFormat('.xlsm', 'Excel con macro', ReaderFamily.spreadsheet, _d),
  ReaderFormat('.xltx', 'Modello Excel', ReaderFamily.spreadsheet, _d),
  ReaderFormat(
    '.xls',
    'Excel 97–2003',
    ReaderFamily.spreadsheet,
    _d,
    note: 'Solo valori',
  ),
  ReaderFormat(
    '.xlt',
    'Modello Excel 97–2003',
    ReaderFamily.spreadsheet,
    _d,
    note: 'Solo valori',
  ),
  ReaderFormat('.ods', 'Foglio OpenDocument', ReaderFamily.spreadsheet, _d),
  ReaderFormat(
    '.ots',
    'Modello di foglio OpenDocument',
    ReaderFamily.spreadsheet,
    _d,
  ),
  ReaderFormat('.csv', 'CSV', ReaderFamily.spreadsheet, _d),
  ReaderFormat(
    '.tsv',
    'Valori separati da tabulazioni',
    ReaderFamily.spreadsheet,
    _d,
  ),
  ReaderFormat(
    '.numbers',
    'Apple Numbers',
    ReaderFamily.spreadsheet,
    ReaderViewer.container,
    note: 'Anteprima incorporata',
  ),
  // Testo e markup
  ReaderFormat('.txt', 'Testo', ReaderFamily.text, _d),
  ReaderFormat('.text', 'Testo', ReaderFamily.text, _d),
  ReaderFormat('.md', 'Markdown', ReaderFamily.text, _d),
  ReaderFormat('.markdown', 'Markdown', ReaderFamily.text, _d),
  ReaderFormat('.html', 'Pagina web', ReaderFamily.text, _d),
  ReaderFormat('.htm', 'Pagina web', ReaderFamily.text, _d),
  ReaderFormat('.xhtml', 'Pagina XHTML', ReaderFamily.text, _d),
  ReaderFormat('.xml', 'XML', ReaderFamily.text, _d),
  ReaderFormat('.json', 'JSON', ReaderFamily.text, _d),
  ReaderFormat('.yaml', 'YAML', ReaderFamily.text, _d),
  ReaderFormat('.yml', 'YAML', ReaderFamily.text, _d),
  ReaderFormat('.toml', 'TOML', ReaderFamily.text, _d),
  ReaderFormat('.ini', 'Impostazioni INI', ReaderFamily.text, _d),
  ReaderFormat('.tex', 'LaTeX', ReaderFamily.text, _d),
  ReaderFormat('.bib', 'BibTeX', ReaderFamily.text, _d),
  ReaderFormat('.rst', 'reStructuredText', ReaderFamily.text, _d),
  ReaderFormat('.org', 'Org mode', ReaderFamily.text, _d),
  ReaderFormat('.adoc', 'AsciiDoc', ReaderFamily.text, _d),
  ReaderFormat('.asciidoc', 'AsciiDoc', ReaderFamily.text, _d),
  ReaderFormat('.log', 'Registro', ReaderFamily.text, _d),
  ReaderFormat('.srt', 'Sottotitoli SubRip', ReaderFamily.text, _d),
  ReaderFormat('.vtt', 'Sottotitoli WebVTT', ReaderFamily.text, _d),
  ReaderFormat('.ipynb', 'Notebook Jupyter', ReaderFamily.code, _d),
  // Codice sorgente
  ReaderFormat('.py', 'Python', _f, _d),
  ReaderFormat('.java', 'Java', _f, _d),
  ReaderFormat('.c', 'C', _f, _d),
  ReaderFormat('.cpp', 'C++', _f, _d),
  ReaderFormat('.cc', 'C++', _f, _d),
  ReaderFormat('.h', 'Intestazione C', _f, _d),
  ReaderFormat('.hpp', 'Intestazione C++', _f, _d),
  ReaderFormat('.cs', 'C#', _f, _d),
  ReaderFormat('.js', 'JavaScript', _f, _d),
  ReaderFormat('.mjs', 'JavaScript', _f, _d),
  ReaderFormat('.ts', 'TypeScript', _f, _d),
  ReaderFormat('.tsx', 'TypeScript JSX', _f, _d),
  ReaderFormat('.jsx', 'JavaScript JSX', _f, _d),
  ReaderFormat('.dart', 'Dart', _f, _d),
  ReaderFormat('.kt', 'Kotlin', _f, _d),
  ReaderFormat('.kts', 'Script Kotlin', _f, _d),
  ReaderFormat('.swift', 'Swift', _f, _d),
  ReaderFormat('.m', 'Objective-C / MATLAB', _f, _d),
  ReaderFormat('.r', 'R', _f, _d),
  ReaderFormat('.rmd', 'R Markdown', _f, _d),
  ReaderFormat('.sql', 'SQL', _f, _d),
  ReaderFormat('.sh', 'Script shell', _f, _d),
  ReaderFormat('.bash', 'Script Bash', _f, _d),
  ReaderFormat('.ps1', 'Script PowerShell', _f, _d),
  ReaderFormat('.bat', 'Script batch', _f, _d),
  ReaderFormat('.go', 'Go', _f, _d),
  ReaderFormat('.rs', 'Rust', _f, _d),
  ReaderFormat('.rb', 'Ruby', _f, _d),
  ReaderFormat('.php', 'PHP', _f, _d),
  ReaderFormat('.pl', 'Perl / Prolog', _f, _d),
  ReaderFormat('.lua', 'Lua', _f, _d),
  ReaderFormat('.scala', 'Scala', _f, _d),
  ReaderFormat('.hs', 'Haskell', _f, _d),
  ReaderFormat('.jl', 'Julia', _f, _d),
  ReaderFormat('.css', 'CSS', _f, _d),
  ReaderFormat('.scss', 'SCSS', _f, _d),
  ReaderFormat('.asm', 'Assembly', _f, _d),
  ReaderFormat('.s', 'Assembly', _f, _d),
  ReaderFormat('.vhd', 'VHDL', _f, _d),
  ReaderFormat('.v', 'Verilog', _f, _d),
  ReaderFormat('.f90', 'Fortran', _f, _d),
  ReaderFormat('.gradle', 'Gradle', _f, _d),
  // E-book
  ReaderFormat('.epub', 'EPUB', ReaderFamily.ebook, _d),
  ReaderFormat(
    '.mobi',
    'Mobipocket',
    ReaderFamily.ebook,
    _d,
    note: 'Senza DRM',
  ),
  ReaderFormat('.azw', 'Kindle', ReaderFamily.ebook, _d, note: 'Senza DRM'),
  ReaderFormat(
    '.azw3',
    'Kindle KF8',
    ReaderFamily.ebook,
    _d,
    note: 'Senza DRM',
  ),
  ReaderFormat('.prc', 'Mobipocket', ReaderFamily.ebook, _d, note: 'Senza DRM'),
  ReaderFormat('.fb2', 'FictionBook', ReaderFamily.ebook, _d),
  ReaderFormat('.cbz', 'Fumetto (immagini)', ReaderFamily.ebook, _d),
  ReaderFormat('.cbr', 'Fumetto RAR', ReaderFamily.ebook, _d),
  ReaderFormat('.xps', 'XPS', ReaderFamily.ebook, _d, note: 'Solo testo'),
  ReaderFormat('.oxps', 'OpenXPS', ReaderFamily.ebook, _d, note: 'Solo testo'),
  ReaderFormat(
    '.djvu',
    'DjVu',
    ReaderFamily.ebook,
    ReaderViewer.djvu,
    note: 'Documenti indiretti (pagine in file separati) non supportati',
  ),
  ReaderFormat(
    '.djv',
    'DjVu',
    ReaderFamily.ebook,
    ReaderViewer.djvu,
    note: 'Documenti indiretti (pagine in file separati) non supportati',
  ),
  ReaderFormat(
    '.kfx',
    'Kindle KFX',
    ReaderFamily.ebook,
    _d,
    note:
        'Con DRM: solo nell\'app Kindle. Senza DRM: solo il testo (niente '
        'immagini, stili e indice)',
  ),
  ReaderFormat(
    '.kfx-zip',
    'Kindle KFX (archivio)',
    ReaderFamily.ebook,
    _d,
    note: 'Con DRM: solo nell\'app Kindle. Senza DRM: solo il testo',
  ),
  ReaderFormat(
    '.kpf',
    'Kindle Create',
    ReaderFamily.ebook,
    _d,
    note: 'Solo il testo',
  ),
  ReaderFormat(
    '.acsm',
    'Token Adobe (ACSM)',
    ReaderFamily.ebook,
    _d,
    note: 'Non è il libro: si apre con Adobe Digital Editions',
  ),
  // Immagini
  ReaderFormat('.png', 'PNG', ReaderFamily.image, ReaderViewer.image),
  ReaderFormat('.jpg', 'JPEG', ReaderFamily.image, ReaderViewer.image),
  ReaderFormat('.jpeg', 'JPEG', ReaderFamily.image, ReaderViewer.image),
  ReaderFormat('.gif', 'GIF', ReaderFamily.image, ReaderViewer.image),
  ReaderFormat('.webp', 'WebP', ReaderFamily.image, ReaderViewer.image),
  ReaderFormat('.bmp', 'Bitmap', ReaderFamily.image, ReaderViewer.image),
  ReaderFormat('.ico', 'Icona', ReaderFamily.image, ReaderViewer.image),
  ReaderFormat(
    '.heic',
    'HEIC',
    ReaderFamily.image,
    ReaderViewer.image,
    note: 'Decodifica del sistema (iOS, macOS, Android 9+)',
  ),
  ReaderFormat(
    '.heif',
    'HEIF',
    ReaderFamily.image,
    ReaderViewer.image,
    note: 'Decodifica del sistema (iOS, macOS, Android 9+)',
  ),
  ReaderFormat('.svg', 'SVG', ReaderFamily.image, ReaderViewer.image),
  ReaderFormat('.tif', 'TIFF', ReaderFamily.image, ReaderViewer.image),
  ReaderFormat('.tiff', 'TIFF', ReaderFamily.image, ReaderViewer.image),
  ReaderFormat('.tga', 'TGA', ReaderFamily.image, ReaderViewer.image),
  // Audio (registrazioni delle lezioni)
  ReaderFormat('.mp3', 'MP3', ReaderFamily.audio, ReaderViewer.media),
  ReaderFormat('.m4a', 'AAC (M4A)', ReaderFamily.audio, ReaderViewer.media),
  ReaderFormat('.aac', 'AAC', ReaderFamily.audio, ReaderViewer.media),
  ReaderFormat('.wav', 'WAV', ReaderFamily.audio, ReaderViewer.media),
  ReaderFormat('.flac', 'FLAC', ReaderFamily.audio, ReaderViewer.media),
  ReaderFormat('.ogg', 'Ogg Vorbis', ReaderFamily.audio, ReaderViewer.media),
  ReaderFormat('.oga', 'Ogg', ReaderFamily.audio, ReaderViewer.media),
  ReaderFormat('.opus', 'Opus', ReaderFamily.audio, ReaderViewer.media),
  ReaderFormat(
    '.wma',
    'Windows Media Audio',
    ReaderFamily.audio,
    ReaderViewer.media,
  ),
  ReaderFormat('.aiff', 'AIFF', ReaderFamily.audio, ReaderViewer.media),
  ReaderFormat('.aif', 'AIFF', ReaderFamily.audio, ReaderViewer.media),
  ReaderFormat('.amr', 'AMR', ReaderFamily.audio, ReaderViewer.media),
  // Video
  ReaderFormat('.mp4', 'MP4', ReaderFamily.video, ReaderViewer.media),
  ReaderFormat('.m4v', 'MPEG-4', ReaderFamily.video, ReaderViewer.media),
  ReaderFormat('.mov', 'QuickTime', ReaderFamily.video, ReaderViewer.media),
  ReaderFormat('.mkv', 'Matroska', ReaderFamily.video, ReaderViewer.media),
  ReaderFormat('.webm', 'WebM', ReaderFamily.video, ReaderViewer.media),
  ReaderFormat('.avi', 'AVI', ReaderFamily.video, ReaderViewer.media),
  ReaderFormat(
    '.wmv',
    'Windows Media Video',
    ReaderFamily.video,
    ReaderViewer.media,
  ),
  ReaderFormat('.3gp', '3GP', ReaderFamily.video, ReaderViewer.media),
  ReaderFormat('.mpg', 'MPEG', ReaderFamily.video, ReaderViewer.media),
  ReaderFormat('.mpeg', 'MPEG', ReaderFamily.video, ReaderViewer.media),
  // Appunti a mano e app di appunti
  ReaderFormat(
    '.xopp',
    'Xournal++',
    ReaderFamily.handwriting,
    ReaderViewer.ink,
  ),
  ReaderFormat('.xoj', 'Xournal', ReaderFamily.handwriting, ReaderViewer.ink),
  ReaderFormat(
    '.excalidraw',
    'Excalidraw',
    ReaderFamily.handwriting,
    ReaderViewer.ink,
  ),
  ReaderFormat(
    '.goodnotes',
    'GoodNotes',
    ReaderFamily.handwriting,
    ReaderViewer.container,
    note: 'PDF e immagini incorporati',
  ),
  ReaderFormat(
    '.note',
    'Notability',
    ReaderFamily.handwriting,
    ReaderViewer.container,
    note: 'PDF e immagini incorporati',
  ),
  ReaderFormat(
    '.notability',
    'Notability',
    ReaderFamily.handwriting,
    ReaderViewer.container,
    note: 'PDF e immagini incorporati',
  ),
  ReaderFormat(
    '.inkml',
    'InkML (Windows Ink)',
    ReaderFamily.handwriting,
    ReaderViewer.ink,
  ),
  ReaderFormat(
    '.isf',
    'Ink Serialized Format',
    ReaderFamily.handwriting,
    ReaderViewer.ink,
    note: 'Tratti X/Y; compressioni personalizzate non supportate',
  ),
  ReaderFormat(
    '.ink',
    'Windows Ink',
    ReaderFamily.handwriting,
    ReaderViewer.ink,
    note: 'InkML o ISF',
  ),
  ReaderFormat(
    '.one',
    'OneNote',
    ReaderFamily.notes,
    _d,
    note:
        'Testo e immagini estratti (senza impaginazione); per le pagine '
        'complete usa OneNote',
  ),
  ReaderFormat(
    '.onepkg',
    'Pacchetto OneNote',
    ReaderFamily.notes,
    ReaderViewer.archive,
    note: 'Elenco delle sezioni (archivio CAB non compresso o MSZIP)',
  ),
  ReaderFormat('.enex', 'Esportazione Evernote', ReaderFamily.notes, _d),
  ReaderFormat(
    '.mm',
    'Mappa mentale FreeMind/Freeplane',
    ReaderFamily.notes,
    ReaderViewer.outline,
  ),
  ReaderFormat(
    '.opml',
    'Scaletta OPML',
    ReaderFamily.notes,
    ReaderViewer.outline,
  ),
  ReaderFormat('.canvas', 'Canvas di Obsidian', ReaderFamily.notes, _d),
  // Archivi
  ReaderFormat(
    '.zip',
    'Archivio ZIP',
    ReaderFamily.archive,
    ReaderViewer.archive,
  ),
  ReaderFormat(
    '.rar',
    'Archivio RAR',
    ReaderFamily.archive,
    ReaderViewer.archive,
    note: 'Senza password',
  ),
];

/// Applicazioni senza un formato di file proprio: come portarne le note nel
/// lettore (mostrate in "Formati supportati").
const kReaderHints = <(String, String)>[
  (
    'Apple Notes',
    'Non ha un formato di file: esporta in PDF o testo (Condividi → '
        'Esporta come PDF, oppure copia il testo in una nota) e aprilo qui.',
  ),
];

final Map<String, ReaderFormat> _byExt = {
  for (final f in kReaderFormats) f.extension: f,
};

/// Estensione in minuscolo, compresi i nomi doppi (".excalidraw.json").
String readerExtension(String path) {
  final name = p.basename(path).toLowerCase();
  if (name.endsWith('.excalidraw.json')) return '.excalidraw';
  if (name.endsWith('.excalidraw.png')) return '.png';
  return p.extension(name);
}

ReaderFormat? formatOfExtension(String ext) => _byExt[ext.toLowerCase()];

ReaderFormat unknownFormat(String ext) => ReaderFormat(
  ext,
  ext.isEmpty ? 'File' : 'File ${ext.substring(1).toUpperCase()}',
  ReaderFamily.other,
  ReaderViewer.info,
);

bool _at(List<int> b, int offset, List<int> sig) {
  if (b.length < offset + sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[offset + i] != sig[i]) return false;
  }
  return true;
}

bool _ascii(List<int> b, int offset, String s) => _at(b, offset, s.codeUnits);

/// Estensione dedotta dai primi byte del file (null se non riconosciuto).
String? sniffExtension(List<int> head) {
  if (_ascii(head, 0, '%PDF')) return '.pdf';
  if (_at(head, 0, [0x50, 0x4B, 0x03, 0x04])) return '.zip';
  if (_at(head, 0, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) {
    return '.doc';
  }
  if (_at(head, 0, [0x89, 0x50, 0x4E, 0x47])) return '.png';
  if (_at(head, 0, [0xFF, 0xD8, 0xFF])) return '.jpg';
  if (_ascii(head, 0, 'GIF8')) return '.gif';
  if (_ascii(head, 0, 'BM') &&
      head.length > 14 &&
      head[6] == 0 &&
      head[7] == 0) {
    return '.bmp';
  }
  if (_ascii(head, 0, 'RIFF') && _ascii(head, 8, 'WEBP')) return '.webp';
  if (_ascii(head, 0, 'RIFF') && _ascii(head, 8, 'WAVE')) return '.wav';
  if (_ascii(head, 0, 'RIFF') && _ascii(head, 8, 'AVI ')) return '.avi';
  if (_at(head, 0, [0x49, 0x49, 0x2A, 0x00]) ||
      _at(head, 0, [0x4D, 0x4D, 0x00, 0x2A])) {
    return '.tif';
  }
  if (_ascii(head, 0, 'ID3') ||
      _at(head, 0, [0xFF, 0xFB]) ||
      _at(head, 0, [0xFF, 0xF3])) {
    return '.mp3';
  }
  if (_ascii(head, 0, 'fLaC')) return '.flac';
  if (_ascii(head, 0, 'OggS')) return '.ogg';
  if (_ascii(head, 4, 'ftyp')) {
    final brand = head.length >= 12
        ? String.fromCharCodes(head.sublist(8, 12))
        : '';
    if (const {'heic', 'heix', 'mif1', 'msf1', 'hevc'}.contains(brand)) {
      return '.heic';
    }
    if (brand.startsWith('M4A')) return '.m4a';
    if (brand.startsWith('qt')) return '.mov';
    return '.mp4';
  }
  if (_at(head, 0, [0x1A, 0x45, 0xDF, 0xA3])) return '.mkv';
  if (_ascii(head, 0, 'AT&TFORM')) return '.djvu';
  if (_at(head, 0, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])) return '.rar';
  if (_at(head, 0, [0xE4, 0x52, 0x5C, 0x7B, 0x8C, 0xD8, 0xA7, 0x4D])) {
    return '.one';
  }
  // KFX: con DRM, o contenitore "CONT" seguito dalla versione (16 bit).
  if (_at(head, 0, [0xEA, 0x44, 0x52, 0x4D, 0x49, 0x4F, 0x4E, 0xEE]) ||
      (_ascii(head, 0, 'CONT') &&
          head.length > 6 &&
          head[4] < 16 &&
          head[5] == 0)) {
    return '.kfx';
  }
  if (_at(head, 0, [0xC5, 0xD0, 0xD3, 0xC6])) return '.eps';
  if (_ascii(head, 0, '%!PS')) {
    return _ascii(head, 0, '%!PS-Adobe-3.0 EPSF') ? '.eps' : '.ps';
  }
  if (_ascii(head, 60, 'BOOKMOBI') || _ascii(head, 60, 'TEXtREAd')) {
    return '.mobi';
  }
  if (_ascii(head, 0, r'{\rtf')) return '.rtf';
  if (_at(head, 0, [0x1F, 0x8B])) return '.xopp';
  // Testo: nessun byte nullo all'inizio.
  final n = head.length < 4096 ? head.length : 4096;
  if (n == 0) return '.txt';
  var start = 0;
  if (_at(head, 0, [0xEF, 0xBB, 0xBF])) start = 3;
  if (_at(head, 0, [0xFF, 0xFE]) || _at(head, 0, [0xFE, 0xFF])) return '.txt';
  for (var i = 0; i < n; i++) {
    if (head[i] == 0) return null;
  }
  final text = String.fromCharCodes(head.sublist(start, n))
      .trimLeft()
      .toLowerCase();
  if (text.startsWith('<!doctype html') || text.startsWith('<html')) {
    return '.html';
  }
  if (text.startsWith('<?xml') || text.startsWith('<')) return '.xml';
  if (text.startsWith('{') || text.startsWith('[')) return '.json';
  return '.txt';
}

/// Formato di un file: dall'estensione e, se manca o non è nota, dai byte
/// iniziali [head].
ReaderFormat detectFormat(String path, [List<int>? head]) {
  final ext = readerExtension(path);
  final known = formatOfExtension(ext);
  if (known != null) {
    // Un file che dice di essere PDF/immagine ma non lo è: si guarda dentro.
    if (head != null && head.isNotEmpty) {
      final sniff = sniffExtension(head);
      if (known.family == ReaderFamily.pdf &&
          sniff != null &&
          sniff != '.pdf') {
        return formatOfExtension(sniff) ?? known;
      }
    }
    return known;
  }
  if (head == null) return unknownFormat(ext);
  final sniff = sniffExtension(head);
  return (sniff == null ? null : formatOfExtension(sniff)) ??
      unknownFormat(ext);
}
