import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/book.dart';
import '../../features/notes/safe_files.dart';
import '../../repositories/book_repository.dart';

/// Esito della copia nell'app dei libri collegati a un percorso esterno.
class LinkedImportResult {
  int copied = 0;
  int missing = 0;
  final List<String> errors = [];
}

/// Archivio di file dentro l'app (cartella privata `libri`, `materiali` o
/// `allegati`).
///
/// Nel database si salva solo il nome del file (`stored_file`), relativo
/// alla cartella: resta valido anche se cambia il percorso dell'app.
class BookLibrary {
  BookLibrary({
    Future<Directory> Function()? baseDir,
    this.folderName = booksFolder,
  }) : _baseDir = baseDir ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDir;
  final String folderName;

  static const booksFolder = 'libri';
  static const materialsFolder = 'materiali';
  static const attachmentsFolder = 'allegati';

  /// Evidenziazioni dei PDF (lib/features/reader/pdf_highlights.dart).
  static const highlightsFolder = 'evidenziazioni';

  Future<Directory> directory() async {
    final dir = Directory(p.join((await _baseDir()).path, folderName));
    await dir.create(recursive: true);
    return dir;
  }

  /// File del libro nell'app, se c'è ancora su questo dispositivo.
  Future<File?> fileOf(Book b) => fileNamed(b.storedFile);

  /// File salvato con nome [name], se esiste ancora.
  Future<File?> fileNamed(String? name) async {
    if (!_plainName(name)) return null;
    final f = File(p.join((await directory()).path, name));
    return await f.exists() ? f : null;
  }

  /// Nome di un file della cartella, senza percorsi: un valore arrivato da
  /// un altro dispositivo o da un backup rovinato («../x», «C:\x») non deve
  /// far leggere o cancellare file fuori dall'archivio dell'app.
  static bool _plainName(String? name) =>
      name != null &&
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains(r'\') &&
      !name.contains(':');

  /// Copia [sourcePath] nell'app e restituisce il nome del file salvato.
  Future<String> store(String sourcePath) async {
    final src = File(sourcePath);
    if (!await src.exists()) {
      throw FileSystemException('File non trovato', sourcePath);
    }
    final dir = await directory();
    final name = uniqueName(dir, p.basename(sourcePath));
    final tmp = File(p.join(dir.path, '$name.part'));
    try {
      await src.copy(tmp.path);
      await tmp.rename(p.join(dir.path, name));
    } catch (_) {
      // disco pieno o file sorgente sparito a metà: niente copie parziali
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    return name;
  }

  /// Elimina il file salvato (nessun errore se manca già).
  Future<void> remove(String? storedFile) async {
    if (!_plainName(storedFile)) return;
    final f = File(p.join((await directory()).path, storedFile));
    if (await f.exists()) await f.delete();
  }

  /// Spazio occupato dai libri nell'app, in byte.
  Future<int> totalBytes() async {
    var total = 0;
    await for (final e
        in (await directory()).list().handleError((Object _) {})) {
      if (e is! File) continue;
      try {
        total += await e.length();
      } on FileSystemException {
        // file tolto nel frattempo
      }
    }
    return total;
  }

  /// Copia nell'app i libri che hanno solo un percorso esterno valido
  /// (ad esempio collegati a un file sul PC).
  Future<LinkedImportResult> importLinked(BookRepository repo) async {
    final r = LinkedImportResult();
    for (final b in await repo.all()) {
      if (await fileOf(b) != null) continue;
      final path = b.filePath?.trim();
      if (path == null || path.isEmpty) continue;
      if (!await fileExistsQuick(path)) {
        r.missing++;
        continue;
      }
      try {
        final name = await store(path);
        await repo.update(b.withFile(storedFile: () => name));
        r.copied++;
      } catch (e) {
        r.errors.add('${b.title}: $e');
      }
    }
    return r;
  }

  /// Copia nell'app i materiali che hanno solo un percorso esterno valido
  /// (ad esempio collegati a un file sul PC).
  Future<LinkedImportResult> importLinkedMaterials(BookRepository repo) async {
    final r = LinkedImportResult();
    for (final m in await repo.materials()) {
      if (await fileNamed(m.storedFile) != null) continue;
      final path = m.localPath?.trim();
      if (path == null || path.isEmpty) continue;
      if (!await fileExistsQuick(path)) {
        r.missing++;
        continue;
      }
      try {
        final name = await store(path);
        await repo.updateMaterial(m.withFile(storedFile: () => name));
        r.copied++;
      } catch (e) {
        r.errors.add('${m.title}: $e');
      }
    }
    return r;
  }

  static bool isPdf(String name) => p.extension(name).toLowerCase() == '.pdf';

  /// Nome sicuro e non ancora usato nella cartella.
  static String uniqueName(Directory dir, String original) {
    // anche l'estensione senza caratteri non validi su Windows, e non
    // lunga a dismisura (un «nome» con migliaia di caratteri dopo l'ultimo
    // punto superava il limite di 255 del file system)
    var ext = p
        .extension(original)
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F ]'), '_');
    ext = cutText(ext, 16).replaceAll(RegExp(r'[. ]+$'), '');
    var base = p
        .basenameWithoutExtension(original)
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .trim();
    // punti e spazi finali non esistono su Windows; «CON», «aux.pdf»… sono
    // nomi riservati (il file non si crea): si aggiunge un trattino basso
    base = cutText(base, 80).replaceAll(RegExp(r'[. ]+$'), '');
    if (base.isEmpty) base = 'libro';
    if (isWindowsReservedName('$base$ext')) base = '${base}_';
    var name = '$base$ext';
    for (var i = 2; File(p.join(dir.path, name)).existsSync(); i++) {
      name = '$base ($i)$ext';
    }
    return name;
  }
}
