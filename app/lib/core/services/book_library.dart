import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/book.dart';
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

  Future<Directory> directory() async {
    final dir = Directory(p.join((await _baseDir()).path, folderName));
    await dir.create(recursive: true);
    return dir;
  }

  /// File del libro nell'app, se c'è ancora su questo dispositivo.
  Future<File?> fileOf(Book b) => fileNamed(b.storedFile);

  /// File salvato con nome [name], se esiste ancora.
  Future<File?> fileNamed(String? name) async {
    if (name == null || name.isEmpty) return null;
    final f = File(p.join((await directory()).path, name));
    return await f.exists() ? f : null;
  }

  /// Copia [sourcePath] nell'app e restituisce il nome del file salvato.
  Future<String> store(String sourcePath) async {
    final src = File(sourcePath);
    if (!await src.exists()) {
      throw FileSystemException('File non trovato', sourcePath);
    }
    final dir = await directory();
    final name = _uniqueName(dir, p.basename(sourcePath));
    final tmp = File(p.join(dir.path, '$name.part'));
    await src.copy(tmp.path);
    await tmp.rename(p.join(dir.path, name));
    return name;
  }

  /// Elimina il file salvato (nessun errore se manca già).
  Future<void> remove(String? storedFile) async {
    if (storedFile == null || storedFile.isEmpty) return;
    final f = File(p.join((await directory()).path, storedFile));
    if (await f.exists()) await f.delete();
  }

  /// Spazio occupato dai libri nell'app, in byte.
  Future<int> totalBytes() async {
    var total = 0;
    await for (final e in (await directory()).list()) {
      if (e is File) total += await e.length();
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
      if (!await File(path).exists()) {
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
      if (!await File(path).exists()) {
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
  static String _uniqueName(Directory dir, String original) {
    final ext = p.extension(original);
    var base = p
        .basenameWithoutExtension(original)
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .trim();
    if (base.isEmpty) base = 'libro';
    if (base.length > 80) base = base.substring(0, 80);
    var name = '$base$ext';
    for (var i = 2; File(p.join(dir.path, name)).existsSync(); i++) {
      name = '$base ($i)$ext';
    }
    return name;
  }
}
