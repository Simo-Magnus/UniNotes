import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'djvu/djvu_document.dart';
import 'djvu/djvu_text.dart';
import '../../utils/safe_text.dart';
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
import 'reader_well_formed.dart';

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

/// File più grandi di così non si caricano in memoria per l'anteprima (un
/// telefono chiuderebbe l'app per mancanza di memoria): si propone di
/// aprirli con un'altra app. I PDF e i file audio/video non contano, perché
/// i loro lettori leggono dal disco un pezzo alla volta. Impostabile nei test.
int readerMaxBytes = (Platform.isAndroid || Platform.isIOS ? 200 : 600) *
    1024 *
    1024;

/// Tempo massimo di un'analisi in un isolate: un file costruito male non
/// deve tenere il lettore sulla rotella per sempre. Impostabile nei test.
Duration readerParseTimeout = const Duration(minutes: 2);

/// File troppo grande per l'anteprima (vedi [readerMaxBytes]).
class ReaderFileTooLargeException implements Exception {
  const ReaderFileTooLargeException(this.bytes);
  final int bytes;
  @override
  String toString() => 'File troppo grande ($bytes byte)';
}

/// Analisi interrotta dopo [readerParseTimeout].
class ReaderTimeoutException implements Exception {
  const ReaderTimeoutException();
  @override
  String toString() => 'Analisi del file interrotta: troppo lenta';
}

/// Byte di [f], se non supera [readerMaxBytes].
Future<Uint8List> _readAll(File f) async {
  final len = await f.length();
  if (len > readerMaxBytes) throw ReaderFileTooLargeException(len);
  return f.readAsBytes();
}

String _megabytes(int bytes) {
  final mb = bytes / (1024 * 1024);
  return mb >= 10 ? mb.round().toString() : mb.toStringAsFixed(1);
}

/// Messaggio per un errore di lettura del file (permessi, file sparito,
/// file in uso).
String fileErrorMessage(FileSystemException e) {
  final code = e.osError?.errorCode;
  final win = Platform.isWindows;
  // Windows: 2/3 non trovato, 5 accesso negato, 32/33 file in uso da un
  // altro programma. POSIX: 2 ENOENT, 1 EPERM, 13 EACCES, 16 EBUSY.
  if (code == 2 || (win && code == 3)) {
    return 'Il file non esiste più su questo dispositivo.';
  }
  if (win ? code == 5 : (code == 1 || code == 13)) {
    return 'L\'app non ha il permesso di leggere questo file. Aprilo con '
        'un\'altra app o copialo in una cartella accessibile.';
  }
  if (win ? (code == 32 || code == 33) : code == 16) {
    return 'Il file è in uso da un altro programma: chiudilo e riprova, '
        'oppure aprilo con un\'altra app.';
  }
  return 'Impossibile leggere il file: ${e.osError?.message ?? e.message}.';
}

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
    // una cartella trascinata nella sezione File
    if (await Directory(path).exists()) {
      return (
        unknownFormat(''),
        const InfoContent('È una cartella: apri uno dei file che contiene.'),
      );
    }
    return (
      unknownFormat(readerExtension(path)),
      const InfoContent('Il file non esiste più su questo dispositivo.'),
    );
  }
  // Anche i primi byte possono non leggersi (permesso negato, file
  // cancellato o spostato nel frattempo, unità di rete scollegata).
  Uint8List head;
  try {
    head = await _head(file);
  } on FileSystemException catch (e) {
    return (detectFormat(path), InfoContent(fileErrorMessage(e)));
  }
  final format = detectFormat(path, head);
  try {
    return (format, await _load(file, format, head));
  } on ReaderFileTooLargeException catch (e) {
    return (
      format,
      InfoContent(
        'Il file è troppo grande per l\'anteprima nell\'app '
        '(${_megabytes(e.bytes)} MB): aprilo con un\'altra app.',
      ),
    );
  } on ReaderTimeoutException {
    return (
      format,
      const InfoContent(
        'Il file richiede troppo tempo per essere letto (forse è danneggiato '
        'o costruito in modo insolito): aprilo con un\'altra app.',
      ),
    );
  } on FileSystemException catch (e) {
    return (format, InfoContent(fileErrorMessage(e)));
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
    return (format, InfoContent(unreadableMessage(format, e)));
  }
}

/// Messaggio per un file che il lettore non riesce ad analizzare: in
/// italiano, con il dettaglio tecnico solo quando dice qualcosa di utile.
String unreadableMessage(ReaderFormat format, Object e) {
  final base =
      'Impossibile leggere il file come ${format.label}: forse è danneggiato, '
      'incompleto o in una variante non supportata. Prova ad aprirlo con '
      'un\'altra app.';
  // Gli errori del parser (FormatException con un testo) spiegano cosa
  // manca; quelli interni (RangeError, TypeError, ...) no.
  if (e is FormatException && e.message.trim().isNotEmpty) {
    return '$base\n(${e.message.trim()})';
  }
  if (e is OutOfMemoryError || e is StackOverflowError) {
    return 'Il file è troppo complesso per l\'anteprima nell\'app: aprilo '
        'con un\'altra app.';
  }
  return base;
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
      final bytes = await _readAll(file);
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
      final bytes = await _readAll(file);
      // Elenco delle voci in un isolate per gli archivi grandi (un indice
      // rovinato non deve bloccare l'interfaccia).
      final entries = await _run(() async {
        final archive = await ReaderArchive.open(bytes);
        return [for (final i in archive.items) ArchiveEntry(i.name, i.size)];
      }, bytes.length);
      final onepkg = ext == '.onepkg';
      return ArchiveContent(
        entries,
        actions: onepkg ? const {ReaderAction.oneNote} : const {},
        notice: onepkg
            ? 'Pacchetto OneNote: tocca una sezione (.one) per leggerne testo '
                  'e immagini.'
            : null,
      );
    case ReaderViewer.container:
      final bytes = await _readAll(file);
      final preview = await _run(() => containerPreview(bytes), bytes.length);
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
      final bytes = await _readAll(file);
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
      final bytes = await _readAll(file);
      return OutlineContent(
        wellFormedOutline(
          await _run(
            () => ext == '.opml' ? parseOpml(bytes) : parseMindMap(bytes),
            bytes.length,
          ),
        ),
      );
    case ReaderViewer.info:
      return InfoContent(_infoMessage(format));
    case ReaderViewer.document:
      final bytes = await _readAll(file);
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
    size > _isolateThreshold ? runIsolated(f) : Future.sync(f);

/// Come [Isolate.run], ma con un tempo massimo ([readerParseTimeout] o
/// [timeout]): allo scadere l'isolate si ferma (niente calcoli e memoria
/// che restano occupati in sottofondo) e si lancia
/// [ReaderTimeoutException]. Un isolate che muore senza risultato (es.
/// memoria finita) diventa un [RemoteError]. Le eccezioni del calcolo
/// arrivano con il loro tipo, come con [Isolate.run].
Future<T> runIsolated<T>(FutureOr<T> Function() f, {Duration? timeout}) async {
  final port = RawReceivePort();
  final done = Completer<T>();
  port.handler = (Object? response) {
    if (done.isCompleted) return;
    if (response is List && response.length == 1) {
      done.complete(response[0] as T);
    } else if (response is List && response.length == 2) {
      final Object? error = response[0], stack = response[1];
      if (stack is StackTrace && error != null) {
        done.completeError(error, stack);
      } else {
        final e = RemoteError('$error', '$stack');
        done.completeError(e, e.stackTrace);
      }
    } else {
      final e = RemoteError('Analisi terminata senza risultato', '');
      done.completeError(e, StackTrace.empty);
    }
  };
  final Isolate isolate;
  try {
    isolate = await Isolate.spawn<(SendPort, FutureOr<T> Function())>(
      _isolateMain,
      (port.sendPort, f),
      onError: port.sendPort,
      onExit: port.sendPort,
      errorsAreFatal: true,
      debugName: 'lettore',
    );
  } catch (_) {
    port.close();
    rethrow;
  }
  final timer = Timer(timeout ?? readerParseTimeout, () {
    if (!done.isCompleted) done.completeError(const ReaderTimeoutException());
  });
  try {
    return await done.future;
  } finally {
    timer.cancel();
    port.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

Future<void> _isolateMain<T>((SendPort, FutureOr<T> Function()) msg) async {
  final (port, f) = msg;
  final T result;
  try {
    result = await f();
  } catch (e, s) {
    // Se l'errore non si può inviare diventa un errore non gestito
    // dell'isolate, che arriva come RemoteError (onError).
    Isolate.exit(port, List<Object?>.of([e, s]));
  }
  Isolate.exit(port, List<Object?>.filled(1, result));
}

String _infoMessage(ReaderFormat f) =>
    'Questo tipo di file (${f.label}) non si può mostrare nell\'app.';

Future<ReaderContent> _image(File file, String ext) async {
  if (ext == '.svg') {
    return ImageContent(bytes: await _readAll(file), svg: true);
  }
  if (const {'.tif', '.tiff', '.tga', '.ico'}.contains(ext)) {
    final bytes = await _readAll(file);
    final png = await _run(() => _toPng(bytes), bytes.length);
    if (png == null) throw const FormatException('immagine non decodificabile');
    return ImageContent(bytes: png);
  }
  return ImageContent(path: file.path);
}

/// Lato massimo delle immagini convertite (TIFF, TGA, ICO): come per le
/// altre immagini, oltre si riduce (memoria del telefono).
const _maxImageSide = 4096;

/// TIFF/TGA/ICO → PNG. Le dimensioni si leggono prima di decodificare: un
/// TIFF di 30000×30000 pixel chiederebbe gigabyte di memoria.
Uint8List? _toPng(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info != null && info.width * info.height > 80 * 1000 * 1000) {
    throw FormatException(
      'immagine troppo grande (${info.width}×${info.height} pixel)',
    );
  }
  var image = img.decodeImage(bytes);
  if (image == null) return null;
  if (image.width > _maxImageSide || image.height > _maxImageSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: _maxImageSide)
        : img.copyResize(image, height: _maxImageSide);
  }
  return img.encodePng(image);
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
      if (f.existsSync()) return _readEmbed(f);
    }
    final found = findNear(dir, p.basename(clean));
    return found == null ? null : _readEmbed(File(found));
  };
}

/// Immagine incorporata, o null se non si legge (permesso negato, file
/// sparito) o è enorme: la nota si mostra comunque.
Uint8List? _readEmbed(File f) {
  try {
    if (f.lengthSync() > 50 * 1024 * 1024) return null;
    return f.readAsBytesSync();
  } on FileSystemException {
    return null;
  }
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
/// serve alle note Markdown per le immagini incorporate. Il testo esce
/// sempre disegnabile ([wellFormedDoc]).
RDoc parseDocument(Uint8List bytes, String ext, {String? path}) =>
    wellFormedDoc(_parseDocumentRaw(bytes, ext, path: path));

RDoc _parseDocumentRaw(Uint8List bytes, String ext, {String? path}) {
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
      final String text;
      try {
        // una trascrizione illeggibile o enorme non deve impedire di
        // ascoltare la registrazione
        if (!await f.exists() || await f.length() > 32 * 1024 * 1024) continue;
        text = decodeText(await f.readAsBytes());
      } on FileSystemException {
        continue;
      }
      if (ext == '.srt' || ext == '.vtt') {
        return (f.path, wellFormedDoc(subtitlesDoc(text)));
      }
      final timed = parseTimedLines(text);
      if (timed.length >= 3) return (f.path, wellFormedDoc(cuesDoc(timed)));
      return (
        f.path,
        wellFormedDoc(ext == '.md' ? markdownDoc(text) : plainTextDoc(text)),
      );
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
  final bytes = await _readAll(File(archivePath));
  // La cartella si risolve qui: nell'isolate le variabili globali (anche
  // [readerTempDir] impostato nei test) ripartono dai valori iniziali.
  final temp = (await readerTempDir()).path;
  // Decompressione in un isolate per gli archivi grandi: la schermata non
  // si blocca e un archivio costruito male si ferma dopo il tempo massimo.
  return _run(
    () => _extract(archivePath, bytes, entry, temp),
    bytes.length,
  );
}

Future<String> _extract(
  String archivePath,
  Uint8List bytes,
  String entry,
  String temp,
) async {
  final archive = await ReaderArchive.open(bytes);
  if (archive is ZipArchive &&
      _linkedExt.contains(p.extension(entry).toLowerCase())) {
    final items = archive.items;
    final total = items.fold(0, (s, i) => s + i.size);
    if (items.length <= 5000 && total <= 200 * 1024 * 1024) {
      final root = Directory(
        p.join(
          temp,
          '${archivePath.hashCode.toUnsigned(32).toRadixString(16)}_'
          '${bytes.length}_x',
        ),
      );
      String? out;
      for (final i in items) {
        final rel = p.normalize(
          i.name.replaceAll('\\', '/').split('/').map(safeFileName).join('/'),
        );
        if (rel.startsWith('..') || p.isAbsolute(rel)) continue;
        final f = File(p.join(root.path, rel));
        // niente uscite dalla cartella («C:x», «\\server\x», «..»)
        if (!p.isWithin(root.path, f.path)) continue;
        try {
          final data = await archive.read(i.name);
          if (data == null) continue;
          if (!await f.exists() || await f.length() != data.length) {
            await f.parent.create(recursive: true);
            await f.writeAsBytes(data, flush: true);
          }
          if (i.name == entry) out = f.path;
        } on FileSystemException {
          // voce che non si può scrivere (un file e una cartella con lo
          // stesso nome, percorso troppo lungo): si salta
        } on FormatException {
          // voce rovinata, protetta o troppo grande: le altre restano
        }
      }
      if (out != null) return out;
    }
  }
  final data = await archive.read(entry);
  if (data == null) throw FileSystemException('Voce non trovata', entry);
  final dir = Directory(
    p.join(
      temp,
      '${'$archivePath|$entry'.hashCode.toUnsigned(32).toRadixString(16)}_'
      '${data.length}',
    ),
  );
  await dir.create(recursive: true);
  final f = File(p.join(dir.path, safeFileName(p.basename(entry))));
  if (!await f.exists() || await f.length() != data.length) {
    await f.writeAsBytes(data, flush: true);
  }
  return f.path;
}

/// Nome di file valido sul sistema (Windows rifiuta `<>:"|?*`, i caratteri
/// di controllo, i punti e gli spazi finali e i nomi riservati come CON o
/// NUL; gli altri solo il carattere nullo) e non più lungo di 120
/// caratteri, mantenendo l'estensione. Altrove i nomi restano uguali, così
/// i collegamenti tra le pagine di un'esportazione funzionano.
String safeFileName(String name, {bool? windows}) {
  final win = windows ?? Platform.isWindows;
  if (name == '.' || name == '..') return name;
  var n = name.replaceAll(win ? RegExp(r'[<>:"|?*\x00-\x1F]') : '\x00', '_');
  if (win) {
    n = n.replaceAll(RegExp(r'[. ]+$'), '');
    final stem = p.basenameWithoutExtension(n).toUpperCase();
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM\d|LPT\d)$').hasMatch(stem)) n = '_$n';
  }
  if (n.isEmpty) return '_';
  if (n.length > 120) {
    final ext = p.extension(n);
    n = ext.length < 20
        ? '${safePrefix(n, 120 - ext.length)}$ext'
        : safePrefix(n, 120);
  }
  return n;
}
