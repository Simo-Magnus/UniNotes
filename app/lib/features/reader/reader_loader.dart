import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'djvu/djvu_document.dart';
import 'djvu/djvu_text.dart';
import 'parsers/archives.dart';
import 'parsers/cfb.dart';
import 'parsers/ebooks.dart';
import 'parsers/ink.dart';
import 'parsers/kfx.dart';
import 'parsers/legacy_office.dart';
import 'parsers/notes_apps.dart';
import 'parsers/odf.dart';
import 'parsers/onenote.dart';
import 'parsers/ooxml.dart';
import 'parsers/postscript.dart';
import 'parsers/rtf.dart';
import 'parsers/text_formats.dart';
import 'parsers/windows_ink.dart';
import 'reader_document.dart';
import 'reader_formats.dart';

/// Contenuto pronto per una vista del lettore.
sealed class ReaderContent {
  const ReaderContent();
}

/// Azioni proposte accanto all'avviso del documento.
enum ReaderAction {
  /// "Apri con…": l'app predefinita del sistema (es. Adobe Digital
  /// Editions per i token .acsm).
  openWith,

  /// Il lettore OneNote dell'app (Microsoft Graph).
  oneNote,
}

class DocContent extends ReaderContent {
  const DocContent(this.doc, {this.actions = const {}});
  final RDoc doc;
  final Set<ReaderAction> actions;
}

/// Documento DjVu con il testo nascosto di ogni pagina.
class DjvuContent extends ReaderContent {
  const DjvuContent(this.doc, this.texts);
  final DjvuDocument doc;
  final List<DjvuPageText> texts;

  String? get notice => texts.every((t) => t.text.trim().isEmpty)
      ? 'Questo DjVu non ha un livello di testo: la ricerca non è disponibile.'
      : null;
}

class PdfContent extends ReaderContent {
  const PdfContent(this.path, {this.notice});
  final String path;
  final String? notice;
}

class ImageContent extends ReaderContent {
  const ImageContent({this.path, this.bytes, this.svg = false});
  final String? path;
  final Uint8List? bytes;
  final bool svg;
}

class MediaContent extends ReaderContent {
  const MediaContent(
    this.path, {
    required this.video,
    this.transcript,
    this.transcriptPath,
  });
  final String path;
  final bool video;

  /// Trascrizione con lo stesso nome (.srt, .vtt, .md, .txt), se c'è.
  final RDoc? transcript;
  final String? transcriptPath;
}

class InkContent extends ReaderContent {
  const InkContent(this.doc);
  final InkDoc doc;
}

class OutlineContent extends ReaderContent {
  const OutlineContent(this.doc);
  final OutlineDoc doc;
}

class ArchiveEntry {
  const ArchiveEntry(this.name, this.size);
  final String name;
  final int size;
}

class ArchiveContent extends ReaderContent {
  const ArchiveContent(this.entries, {this.actions = const {}, this.notice});
  final List<ArchiveEntry> entries;
  final Set<ReaderAction> actions;
  final String? notice;
}

/// Nessuna vista: messaggio e azioni "Apri con…" / "Condividi".
class InfoContent extends ReaderContent {
  const InfoContent(this.message, {this.onenote = false});
  final String message;

  /// Suggerire il lettore OneNote dell'app (Microsoft Graph).
  final bool onenote;
}

/// Sopra questa dimensione i documenti si analizzano in un isolate.
const _isolateThreshold = 384 * 1024;

/// Cartella dei file temporanei del lettore (PDF estratti, file di
/// archivi). Impostabile nei test.
Future<Directory> Function() readerTempDir = () async =>
    Directory(p.join(Directory.systemTemp.path, 'university_notes_reader'));

Future<String> _writeTemp(String key, String fileName, Uint8List bytes) async {
  final dir = Directory(
    p.join(
      (await readerTempDir()).path,
      '${key.hashCode.toUnsigned(32).toRadixString(16)}_${bytes.length}',
    ),
  );
  await dir.create(recursive: true);
  final f = File(p.join(dir.path, fileName));
  if (!await f.exists() || await f.length() != bytes.length) {
    await f.writeAsBytes(bytes, flush: true);
  }
  return f.path;
}

Future<Uint8List> _head(File f) async {
  final raf = await f.open();
  try {
    return await raf.read(4096);
  } finally {
    await raf.close();
  }
}

/// Carica [path] per il lettore: rileva il formato e prepara il contenuto.
/// Gli errori di lettura diventano [InfoContent] con un messaggio chiaro.
Future<(ReaderFormat, ReaderContent)> loadReaderContent(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    return (
      unknownFormat(readerExtension(path)),
      const InfoContent('Il file non esiste più su questo dispositivo.'),
    );
  }
  final head = await _head(file);
  final format = detectFormat(path, head);
  try {
    return (format, await _load(file, format, head));
  } on EncryptedDocumentException {
    return (
      format,
      const InfoContent(
        'Il documento è protetto da password: aprilo con l\'app di Office per leggerlo.',
      ),
    );
  } on DrmProtectedException catch (e) {
    return (format, InfoContent(drmMessage(e.kind)));
  } on DjvuIndirectException {
    return (
      format,
      const InfoContent(
        'Questo è un documento DjVu "indiretto": il file contiene solo '
        'l\'elenco delle pagine, che sono file .djvu separati nella stessa '
        'cartella. Apri direttamente le pagine, oppure riuniscile in un '
        'solo file (es. con "djvmcvt -b" di DjVuLibre).',
      ),
    );
  } on UnsupportedInkException catch (e) {
    return (
      format,
      InfoContent('${e.message} Aprilo con un\'app per Windows Ink.'),
    );
  } catch (e) {
    return (
      format,
      InfoContent('Impossibile leggere il file come ${format.label}: $e'),
    );
  }
}

/// Spiegazione per un e-book protetto (l'app non toglie le protezioni).
String drmMessage(DrmKind kind) => switch (kind) {
  DrmKind.adobe =>
    'L\'e-book è protetto con il DRM di Adobe (ADEPT): aprilo con Adobe '
        'Digital Editions o con un lettore compatibile autorizzato con il tuo '
        'Adobe ID. L\'app non può togliere la protezione.',
  DrmKind.lcp =>
    'L\'e-book è protetto con Readium LCP: aprilo con Thorium Reader o con '
        'un\'app compatibile LCP, con la passphrase del negozio o della '
        'biblioteca. L\'app non può togliere la protezione.',
  DrmKind.apple =>
    'L\'e-book è protetto con il DRM di Apple (FairPlay): si legge solo in '
        'Apple Libri.',
  DrmKind.kindle =>
    'L\'e-book è protetto dal DRM di Amazon: aprilo con l\'app Kindle o sul '
        'lettore Kindle.',
  DrmKind.kfx =>
    'Questo file KFX è protetto dal DRM di Amazon: si legge solo con l\'app '
        'Kindle o sul lettore Kindle dell\'account che l\'ha acquistato. '
        'L\'app non può e non deve togliere la protezione.',
  DrmKind.generic =>
    'L\'e-book è protetto da DRM e non si può leggere qui. Aprilo con '
        'l\'app del negozio (Kindle, Kobo, Libri…).',
};

/// DRM nei PDF: Adobe ADEPT (/EBX_HANDLER) o FileOpen (/FOPN_). I PDF
/// con la sola password si aprono nel lettore, che la chiede.
Future<DrmKind?> pdfDrm(File f) async {
  final raf = await f.open();
  try {
    final len = await raf.length();
    const chunk = 1 << 20;
    final parts = <Uint8List>[await raf.read(chunk)];
    if (len > chunk) {
      await raf.setPosition(len - chunk > chunk ? len - chunk : chunk);
      parts.add(await raf.read(chunk));
    }
    for (final b in parts) {
      final s = latin1.decode(b);
      if (s.contains('/EBX_HANDLER')) return DrmKind.adobe;
      if (s.contains('/FOPN_')) return DrmKind.generic;
    }
    return null;
  } finally {
    await raf.close();
  }
}

/// Documento DjVu e testo di tutte le pagine (anche in un isolate).
DjvuContent djvuContent(Uint8List bytes) {
  final doc = DjvuDocument.parse(bytes);
  return DjvuContent(doc, [
    for (var i = 0; i < doc.pages.length; i++) doc.text(i),
  ]);
}

Future<ReaderContent> _load(
  File file,
  ReaderFormat format,
  Uint8List head,
) async {
  final ext = format.extension;
  switch (format.viewer) {
    case ReaderViewer.pdf:
      final drm = await pdfDrm(file);
      if (drm != null) {
        return InfoContent(
          drm == DrmKind.adobe
              ? 'Il PDF è protetto con il DRM di Adobe (ADEPT): aprilo con '
                    'Adobe Digital Editions. L\'app non può togliere la '
                    'protezione.'
              : 'Il PDF è protetto da DRM (FileOpen o simili): aprilo con il '
                    'programma indicato dall\'editore.',
        );
      }
      return PdfContent(file.path);
    case ReaderViewer.djvu:
      final bytes = await file.readAsBytes();
      return _run(() => djvuContent(bytes), bytes.length);
    case ReaderViewer.media:
      final t = await findTranscript(file.path);
      return MediaContent(
        file.path,
        video: format.family == ReaderFamily.video,
        transcript: t?.$2,
        transcriptPath: t?.$1,
      );
    case ReaderViewer.image:
      return _image(file, ext);
    case ReaderViewer.archive:
      final bytes = await file.readAsBytes();
      final archive = await ReaderArchive.open(bytes);
      final onepkg = ext == '.onepkg';
      return ArchiveContent(
        [for (final i in archive.items) ArchiveEntry(i.name, i.size)],
        actions: onepkg ? const {ReaderAction.oneNote} : const {},
        notice: onepkg
            ? 'Pacchetto OneNote: tocca una sezione (.one) per leggerne testo '
                  'e immagini.'
            : null,
      );
    case ReaderViewer.container:
      final bytes = await file.readAsBytes();
      final preview = containerPreview(bytes);
      final pdf = preview.pdf;
      final what = switch (ext) {
        '.pages' ||
        '.key' ||
        '.numbers' => 'un\'anteprima del documento salvata da ${format.label}',
        _ => 'il PDF incorporato nel file ${format.label}',
      };
      if (pdf != null) {
        final out = await _writeTemp(
          file.path,
          '${p.basenameWithoutExtension(file.path)}.pdf',
          pdf,
        );
        return PdfContent(out, notice: 'Mostrato $what.');
      }
      if (preview.images.isNotEmpty) {
        return DocContent(
          galleryDoc(
            preview.images,
            notice:
                'Il formato ${format.label} non si legge direttamente: '
                'mostrate le immagini incorporate (${preview.images.length}).',
          ),
        );
      }
      return InfoContent(
        'Il file ${format.label} non contiene un\'anteprima leggibile. '
        'Aprilo con l\'app ${format.label} o esportalo in PDF.',
      );
    case ReaderViewer.ink:
      final bytes = await file.readAsBytes();
      final doc = await _run(
        () => switch (ext) {
          '.excalidraw' => parseExcalidraw(bytes),
          '.ink' || '.isf' || '.inkml' => parseWindowsInk(bytes),
          _ => parseXopp(bytes),
        },
        bytes.length,
      );
      return InkContent(doc);
    case ReaderViewer.outline:
      final bytes = await file.readAsBytes();
      return OutlineContent(
        ext == '.opml' ? parseOpml(bytes) : parseMindMap(bytes),
      );
    case ReaderViewer.info:
      return InfoContent(_infoMessage(format));
    case ReaderViewer.document:
      final bytes = await file.readAsBytes();
      // Fumetti: .cbr e .cbz si riconoscono dal contenuto (spesso un .cbz
      // è in realtà un RAR e viceversa).
      if ((ext == '.cbr' || ext == '.cbz') && isRar(bytes)) {
        return DocContent(
          await _run(
            () async => comicDoc(await RarArchive.open(bytes)),
            bytes.length,
          ),
        );
      }
      final path = file.path;
      return DocContent(
        await _run(() => parseDocument(bytes, ext, path: path), bytes.length),
        actions: switch (ext) {
          '.one' => const {ReaderAction.oneNote, ReaderAction.openWith},
          '.acsm' ||
          '.kfx' ||
          '.kfx-zip' ||
          '.kpf' ||
          '.ps' ||
          '.eps' => const {ReaderAction.openWith},
          _ => const {},
        },
      );
  }
}

Future<T> _run<T>(FutureOr<T> Function() f, int size) =>
    size > _isolateThreshold ? Isolate.run(f) : Future.sync(f);

String _infoMessage(ReaderFormat f) =>
    'Questo tipo di file (${f.label}) non si può mostrare nell\'app.';

Future<ReaderContent> _image(File file, String ext) async {
  if (ext == '.svg') {
    return ImageContent(bytes: await file.readAsBytes(), svg: true);
  }
  if (const {'.tif', '.tiff', '.tga', '.ico'}.contains(ext)) {
    final bytes = await file.readAsBytes();
    final png = await _run(() {
      final image = img.decodeImage(bytes);
      return image == null ? null : img.encodePng(image);
    }, bytes.length);
    if (png == null) throw const FormatException('immagine non decodificabile');
    return ImageContent(bytes: png);
  }
  return ImageContent(path: file.path);
}

const _embedExt = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

/// Immagini incorporate in una nota Markdown (`![[foto.png]]`,
/// `![](allegati/foto.png)`): accanto alla nota, nelle cartelle degli
/// allegati più comuni o, in un vault di Obsidian, in una sottocartella.
EmbedResolver noteEmbeds(String notePath) {
  final dir = p.dirname(notePath);
  return (name) {
    final clean = name.split('|').first.trim();
    if (!_embedExt.contains(p.extension(clean).toLowerCase())) return null;
    for (final c in [
      p.join(dir, clean),
      for (final a in ['attachments', 'Attachments', 'allegati', 'assets'])
        p.join(dir, a, clean),
    ]) {
      // solo file dentro la cartella della nota (niente «..», percorsi
      // assoluti o di rete come «\\server\x.png»)
      if (!p.isWithin(dir, p.normalize(c))) continue;
      final f = File(c);
      if (f.existsSync()) return f.readAsBytesSync();
    }
    final found = findNear(dir, p.basename(clean));
    return found == null ? null : File(found).readAsBytesSync();
  };
}

/// File di nome [name] in [dir] o nelle sottocartelle (fino a [depth]
/// livelli, senza le cartelle nascoste), o null.
String? findNear(String dir, String name, {int depth = 3}) {
  final lower = name.toLowerCase();
  final d = Directory(dir);
  if (!d.existsSync()) return null;
  final subdirs = <Directory>[];
  try {
    for (final e in d.listSync(followLinks: false)) {
      final base = p.basename(e.path);
      if (e is File && base.toLowerCase() == lower) return e.path;
      if (e is Directory && !base.startsWith('.')) subdirs.add(e);
    }
  } on FileSystemException {
    return null;
  }
  if (depth <= 0) return null;
  for (final s in subdirs) {
    final r = findNear(s.path, name, depth: depth - 1);
    if (r != null) return r;
  }
  return null;
}

/// Documento da byte, per estensione (anche dentro un isolate). [path]
/// serve alle note Markdown per le immagini incorporate.
RDoc parseDocument(Uint8List bytes, String ext, {String? path}) {
  // File OLE2 con estensione diversa (es. .doc rinominato in .xls).
  if (Cfb.isCfb(bytes)) {
    final kind = legacyKind(Cfb(bytes));
    switch (kind) {
      case '.doc':
        return parseDoc(bytes);
      case '.xls':
        return parseXls(bytes);
      case '.ppt':
        return parsePpt(bytes);
    }
    if (const {
      '.docx',
      '.xlsx',
      '.pptx',
      '.docm',
      '.xlsm',
      '.pptm',
    }.contains(ext)) {
      // OOXML cifrato: il contenitore OLE2 ha "EncryptedPackage".
      throw const EncryptedDocumentException();
    }
  }
  return switch (ext) {
    '.docx' || '.docm' || '.dotx' || '.dotm' => parseDocx(bytes),
    '.pptx' || '.pptm' || '.ppsx' || '.ppsm' || '.potx' => parsePptx(bytes),
    '.xlsx' || '.xlsm' || '.xltx' => parseXlsx(bytes),
    '.doc' || '.dot' => parseDoc(bytes),
    '.ppt' || '.pps' || '.pot' => parsePpt(bytes),
    '.xls' || '.xlt' => parseXls(bytes),
    '.odt' || '.ott' => parseOdt(bytes),
    '.odp' || '.otp' => parseOdp(bytes),
    '.ods' || '.ots' => parseOds(bytes),
    '.rtf' => parseRtf(bytes),
    '.epub' => parseEpub(bytes),
    '.mobi' || '.azw' || '.azw3' || '.prc' => parseMobi(bytes),
    '.fb2' => parseFb2(bytes),
    '.xps' || '.oxps' => parseXps(bytes),
    '.cbz' || '.cbr' => parseCbz(bytes),
    '.enex' => parseEnex(bytes),
    '.canvas' => parseCanvas(bytes),
    '.one' => parseOneNote(
      bytes,
      title: path == null ? '' : p.basenameWithoutExtension(path),
    ),
    '.ps' || '.eps' => parsePostScript(bytes),
    '.acsm' => parseAcsm(bytes),
    '.kfx' || '.kfx-zip' || '.kpf' => parseKfx(bytes),
    '.md' || '.markdown' when path != null => markdownDoc(
      decodeText(bytes),
      embed: noteEmbeds(path),
    ),
    _ => textFormatDoc(bytes, ext),
  };
}

/// Trascrizione di una registrazione: stesso nome con estensione .srt,
/// .vtt, .md o .txt nella stessa cartella o in una cartella vicina con un
/// nome da trascrizioni (negli appunti: Registrazioni/x.flac →
/// Trascrizioni/x.md).
Future<(String, RDoc)?> findTranscript(String audioPath) async {
  final base = p.basenameWithoutExtension(audioPath);
  final dir = Directory(p.dirname(audioPath));
  const exts = ['.srt', '.vtt', '.md', '.txt'];
  // Cartelle vicine con un nome da trascrizioni (senza elencare la cartella
  // madre, che può essere enorme: Download, radice del disco, ...).
  const nearby = [
    'Trascrizioni',
    'Trascrizione',
    'Transcripts',
    'Sottotitoli',
    'Subtitles',
  ];
  final dirs = <Directory>[
    dir,
    for (final n in nearby) Directory(p.join(dir.parent.path, n)),
  ];
  for (final d in dirs) {
    for (final ext in exts) {
      final f = File(p.join(d.path, '$base$ext'));
      if (!await f.exists()) continue;
      final text = decodeText(await f.readAsBytes());
      if (ext == '.srt' || ext == '.vtt') return (f.path, subtitlesDoc(text));
      final timed = parseTimedLines(text);
      if (timed.length >= 3) return (f.path, cuesDoc(timed));
      return (f.path, ext == '.md' ? markdownDoc(text) : plainTextDoc(text));
    }
  }
  return null;
}

/// Note e pagine che rimandano ad altri file dell'archivio (esportazioni
/// di Notion, vault di Obsidian): si estrae tutto l'archivio.
const _linkedExt = {'.md', '.markdown', '.html', '.htm', '.csv', '.txt'};

/// Estrae un file di un archivio (ZIP, RAR, CAB) in una cartella
/// temporanea. Per le note di un archivio ZIP non troppo grande si estrae
/// tutto con le cartelle, così i collegamenti tra le pagine e le immagini
/// funzionano.
Future<String> extractArchiveEntry(String archivePath, String entry) async {
  final bytes = await File(archivePath).readAsBytes();
  final archive = await ReaderArchive.open(bytes);
  if (archive is ZipArchive &&
      _linkedExt.contains(p.extension(entry).toLowerCase())) {
    final items = archive.items;
    final total = items.fold(0, (s, i) => s + i.size);
    if (items.length <= 5000 && total <= 200 * 1024 * 1024) {
      final root = Directory(
        p.join(
          (await readerTempDir()).path,
          '${archivePath.hashCode.toUnsigned(32).toRadixString(16)}_'
          '${bytes.length}_x',
        ),
      );
      String? out;
      for (final i in items) {
        final rel = p.normalize(i.name.replaceAll('\\', '/'));
        if (rel.startsWith('..') || p.isAbsolute(rel)) continue;
        final f = File(p.join(root.path, rel));
        final data = await archive.read(i.name);
        if (data == null) continue;
        if (!await f.exists() || await f.length() != data.length) {
          await f.parent.create(recursive: true);
          await f.writeAsBytes(data, flush: true);
        }
        if (i.name == entry) out = f.path;
      }
      if (out != null) return out;
    }
  }
  final data = await archive.read(entry);
  if (data == null) throw FileSystemException('Voce non trovata', entry);
  return _writeTemp('$archivePath|$entry', p.basename(entry), data);
}
