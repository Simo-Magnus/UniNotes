import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../models/course.dart';
import '../notes/notes_store.dart';
import '../notes/safe_files.dart';

/// Un file arrivato da fuori: «Condividi → UniNotes» (Android), «Apri in
/// UniNotes» (iPhone, iPad), trascinamento nella finestra (PC, Mac).
class IncomingFile {
  const IncomingFile(this.path, this.name, {this.temporary = false});

  /// Percorso sul dispositivo.
  final String path;

  /// Nome da usare nell'app (quello originale, ripulito).
  final String name;

  /// Copia temporanea fatta dal codice nativo (cache dell'app): dopo il
  /// salvataggio, o se lo studente annulla, si elimina.
  final bool temporary;
}

/// Dove salvare i file arrivati: la cartella di un insegnamento o
/// «Da ordinare», dentro Materiali (sincronizzata come
/// `UniNotes/Materiali/<cartella>` su Google Drive e OneDrive).
class IncomingDestination {
  const IncomingDestination._(this.folder, this.label);

  static const unsortedName = 'Da ordinare';
  static const unsorted = IncomingDestination._(unsortedName, unsortedName);

  /// Cartella dell'insegnamento: solo il suo nome (niente sigla dell'ateneo).
  factory IncomingDestination.course(Course c) =>
      IncomingDestination._(NotesStore.safeName(c.name), c.name);

  /// Sottocartella in Materiali.
  final String folder;

  /// Nome mostrato.
  final String label;

  @override
  bool operator ==(Object other) =>
      other is IncomingDestination && other.folder == folder;

  @override
  int get hashCode => folder.hashCode;
}

/// File condivisi con l'app dal sistema (Android, iOS). Il codice nativo
/// copia ogni file nella cache dell'app e avvisa con `available`; l'app li
/// prende con `take` (una sola volta), anche all'avvio quando l'app è stata
/// aperta proprio da «Condividi».
class IncomingFiles {
  IncomingFiles({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'io.github.simomagnus.universitynotes/incoming';

  final MethodChannel _channel;

  /// [onAvailable] quando arrivano file con l'app già aperta.
  void listen(void Function() onAvailable) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'available') onAvailable();
      return null;
    });
  }

  void dispose() => _channel.setMethodCallHandler(null);

  /// File in attesa (vuoto se non ce ne sono o sulle piattaforme senza
  /// canale nativo).
  Future<List<IncomingFile>> take() async {
    try {
      return parse(await _channel.invokeMethod<Object?>('take'));
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Elenco ricevuto dal codice nativo: mappe `{path, name, temporary}` (o
  /// percorsi semplici, anche `file://`). Voci senza percorso o ripetute si
  /// scartano; i nomi diventano nomi di file validi.
  static List<IncomingFile> parse(Object? raw) {
    if (raw is! List) return const [];
    final seen = <String>{};
    final out = <IncomingFile>[];
    for (final it in raw) {
      String? path;
      String? name;
      var temporary = false;
      if (it is String) {
        path = it;
      } else if (it is Map) {
        final v = it['path'];
        path = v is String ? v : null;
        final n = it['name'];
        name = n is String ? n : null;
        temporary = it['temporary'] == true;
      }
      if (path == null || path.trim().isEmpty) continue;
      if (path.startsWith('file://')) {
        try {
          path = Uri.parse(path).toFilePath();
        } catch (_) {
          continue;
        }
      }
      if (!seen.add(path)) continue;
      final base = (name == null || name.trim().isEmpty)
          ? p.basename(path)
          : p.basename(name.replaceAll('\\', '/'));
      out.add(IncomingFile(path, safeFileName(base), temporary: temporary));
    }
    return out;
  }

  /// Nome di file valido su tutti i sistemi (estensione conservata).
  static String safeFileName(String name) {
    final ext = p.extension(name);
    final stem = ext.isEmpty ? name : name.substring(0, name.length - ext.length);
    // (estensione non più lunga di 16 caratteri: un nome senza punti ma con
    // un punto in fondo a migliaia di caratteri superava il limite del file
    // system)
    final cleanExt = cutText(
      ext.replaceAll(RegExp(r'[^A-Za-z0-9.]'), ''),
      16,
    ).replaceAll(RegExp(r'\.+$'), '');
    final s = NotesStore.safeName(stem);
    return '$s$cleanExt';
  }

  /// Copia [files] in `<materiali>/<cartella>`; con un nome già presente
  /// aggiunge « (2)», « (3)»… Le copie temporanee si eliminano. Restituisce i
  /// percorsi relativi a [materials] dei file salvati.
  static Future<List<String>> store(
    List<IncomingFile> files,
    Directory materials,
    IncomingDestination dest,
  ) async {
    final dir = Directory(p.join(materials.path, dest.folder));
    await dir.create(recursive: true);
    final saved = <String>[];
    for (final f in files) {
      final src = File(f.path);
      if (!await src.exists()) continue;
      final name = uniqueName(dir, f.name);
      final target = p.join(dir.path, name);
      // (con il disco pieno non resta un file troncato accanto agli altri)
      await copyFileSafely(src, target);
      saved.add('${dest.folder}/$name');
      if (f.temporary) await discard([f]);
    }
    return saved;
  }

  /// Elimina le copie temporanee (lo studente ha annullato).
  static Future<void> discard(List<IncomingFile> files) async {
    for (final f in files) {
      if (!f.temporary) continue;
      try {
        await File(f.path).delete();
      } catch (_) {}
    }
  }

  /// Nome libero in [dir]: «nome.ext», poi «nome (2).ext»…
  static String uniqueName(Directory dir, String name) => _unique(
    name,
    (c) =>
        File(p.join(dir.path, c)).existsSync() ||
        File(p.join(dir.path, '$c.part')).existsSync(),
  );

  /// Come [uniqueName], tra i nomi [taken] (es. una cartella di Drive).
  static String uniqueAmong(Set<String> taken, String name) =>
      _unique(name, taken.contains);

  static String _unique(String name, bool Function(String) used) {
    final ext = p.extension(name);
    final stem = name.substring(0, name.length - ext.length);
    var candidate = name;
    var n = 2;
    while (used(candidate)) {
      candidate = '$stem ($n)$ext';
      n++;
    }
    return candidate;
  }
}
