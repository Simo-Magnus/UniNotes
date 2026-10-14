import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Elemento di «Eliminati di recente».
class TrashEntry {
  TrashEntry({
    required this.id,
    required this.title,
    required this.deletedAt,
    required this.files,
    this.course,
  });

  final String id;
  final String title;
  final String? course;
  final DateTime deletedAt;

  /// File spostati: (nome nel cestino, percorso originale).
  final List<(String, String)> files;

  bool get isAudio => files.any(
    (f) => const {
      '.m4a',
      '.wav',
      '.flac',
      '.aac',
      '.ogg',
      '.mp3',
    }.contains(p.extension(f.$2).toLowerCase()),
  );

  Map<String, Object?> toJson() => {
    'titolo': title,
    'corso': ?course,
    'eliminato': deletedAt.toIso8601String(),
    'file': [
      for (final (name, origin) in files) {'nome': name, 'origine': origin},
    ],
  };

  static TrashEntry? fromJson(String id, Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['eliminato'] ?? ''}');
    if (at == null) return null;
    return TrashEntry(
      id: id,
      title: '${j['titolo'] ?? id}',
      course: j['corso'] is String ? j['corso'] as String : null,
      deletedAt: at,
      files: [
        for (final f in (j['file'] as List? ?? const []))
          if (f is Map && f['nome'] is String && f['origine'] is String)
            (f['nome'] as String, f['origine'] as String),
      ],
    );
  }
}

/// «Eliminati di recente»: le registrazioni e gli appunti eliminati restano
/// 30 giorni in una cartella nascosta dentro la cartella degli appunti
/// (`.eliminati`, come `.cestino-onedrive` e `.cestino-googledrive` per i
/// file eliminati su un altro dispositivo) e si possono ripristinare. Le
/// cartelle che iniziano con «.» non si sincronizzano: sul servizio cloud il
/// file eliminato va nel cestino del servizio.
class RecycleBin {
  RecycleBin(this._root, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Future<Directory> Function() _root;
  final DateTime Function() _now;

  static const dirName = '.eliminati';
  static const keep = Duration(days: 30);

  /// Giorni che restano prima della cancellazione definitiva (almeno 0).
  static int daysLeft(DateTime deletedAt, DateTime now) {
    final left = deletedAt.add(keep).difference(now);
    if (left.isNegative) return 0;
    return (left.inHours / 24).ceil();
  }

  static bool expired(DateTime deletedAt, DateTime now) =>
      !now.isBefore(deletedAt.add(keep));

  Future<Directory> dir() async =>
      Directory(p.join((await _root()).path, dirName));

  /// Sposta [files] nel cestino come un solo elemento. I file che non
  /// esistono si ignorano. Con [originDir] il ripristino li rimette in
  /// quella cartella invece che in quella di partenza.
  Future<TrashEntry?> trash(
    List<File> files, {
    required String title,
    String? course,
    String? originDir,
  }) async {
    final existing = [
      for (final f in files)
        if (await f.exists()) f,
    ];
    if (existing.isEmpty) return null;
    final now = _now();
    final base = await dir();
    var id = '${now.millisecondsSinceEpoch}';
    for (var i = 2; await Directory(p.join(base.path, id)).exists(); i++) {
      id = '${now.millisecondsSinceEpoch}-$i';
    }
    final folder = Directory(p.join(base.path, id));
    await folder.create(recursive: true);
    final moved = <(String, String)>[];
    final used = <String>{};
    for (final f in existing) {
      var name = p.basename(f.path);
      for (var i = 2; !used.add(name.toLowerCase()); i++) {
        name =
            '${p.basenameWithoutExtension(f.path)} ($i)${p.extension(f.path)}';
      }
      await moveFile(f, p.join(folder.path, name));
      moved.add((
        name,
        originDir == null ? f.path : p.join(originDir, p.basename(f.path)),
      ));
    }
    final entry = TrashEntry(
      id: id,
      title: title,
      course: course,
      deletedAt: now,
      files: moved,
    );
    await File(p.join(folder.path, 'info.json'))
        .writeAsString(jsonEncode(entry.toJson()));
    return entry;
  }

  /// Elementi del cestino, dal più recente (quelli scaduti si cancellano).
  Future<List<TrashEntry>> list() async {
    await purge();
    final base = await dir();
    if (!await base.exists()) return const [];
    final out = <TrashEntry>[];
    await for (final e in base.list()) {
      if (e is! Directory) continue;
      final info = File(p.join(e.path, 'info.json'));
      if (!await info.exists()) continue;
      try {
        final entry = TrashEntry.fromJson(
          p.basename(e.path),
          jsonDecode(await info.readAsString()),
        );
        if (entry != null) out.add(entry);
      } catch (_) {
        // elemento illeggibile: resta finché non scade la cartella
      }
    }
    out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return out;
  }

  /// Rimette i file al loro posto (con « (ripristinato)» se nel frattempo
  /// è comparso un file con lo stesso nome). Restituisce i file ripristinati.
  Future<List<File>> restore(TrashEntry e) async {
    final folder = Directory(p.join((await dir()).path, e.id));
    final out = <File>[];
    // il suffisso è lo stesso per tutti i file dell'elemento (registrazione
    // e dati restano collegati dal nome)
    var suffix = '';
    for (var i = 1; ; i++) {
      final s = i == 1
          ? ''
          : (i == 2 ? ' (ripristinato)' : ' (ripristinato $i)');
      final clash = await Future.wait([
        for (final (_, origin) in e.files)
          File(_withSuffix(origin, s)).exists(),
      ]);
      if (!clash.contains(true)) {
        suffix = s;
        break;
      }
    }
    for (final (name, origin) in e.files) {
      final src = File(p.join(folder.path, name));
      if (!await src.exists()) continue;
      final dest = _withSuffix(origin, suffix);
      await File(dest).parent.create(recursive: true);
      out.add(await moveFile(src, dest));
    }
    await _deleteDir(folder);
    return out;
  }

  /// «Annulla» dopo un ripristino: i file [restored] (restituiti da
  /// [restore]) tornano nel cestino come l'elemento [e] di prima, con la
  /// stessa data di eliminazione (i 30 giorni non ripartono).
  Future<void> undoRestore(TrashEntry e, List<File> restored) async {
    final folder = Directory(p.join((await dir()).path, e.id));
    await folder.create(recursive: true);
    for (final f in restored) {
      if (!await f.exists()) continue;
      final name = _trashNameOf(e, f.path) ?? p.basename(f.path);
      await moveFile(f, p.join(folder.path, name));
    }
    await File(p.join(folder.path, 'info.json'))
        .writeAsString(jsonEncode(e.toJson()));
  }

  /// Nome nel cestino del file ripristinato in [path] (anche con il
  /// suffisso « (ripristinato)»).
  static String? _trashNameOf(TrashEntry e, String path) {
    for (final (name, origin) in e.files) {
      if (p.equals(origin, path)) return name;
    }
    for (final (name, origin) in e.files) {
      final base = p.basenameWithoutExtension(origin);
      if (p.equals(p.dirname(origin), p.dirname(path)) &&
          p.extension(origin).toLowerCase() ==
              p.extension(path).toLowerCase() &&
          p.basenameWithoutExtension(path).startsWith('$base (ripristinato')) {
        return name;
      }
    }
    return null;
  }

  static String _withSuffix(String path, String suffix) => suffix.isEmpty
      ? path
      : p.join(
          p.dirname(path),
          '${p.basenameWithoutExtension(path)}$suffix${p.extension(path)}',
        );

  Future<void> deleteForever(TrashEntry e) async =>
      _deleteDir(Directory(p.join((await dir()).path, e.id)));

  /// Cancella gli elementi più vecchi di 30 giorni. Restituisce quanti.
  Future<int> purge() async {
    final base = await dir();
    if (!await base.exists()) return 0;
    final now = _now();
    var n = 0;
    await for (final e in base.list()) {
      if (e is! Directory) continue;
      DateTime? at;
      final info = File(p.join(e.path, 'info.json'));
      try {
        if (await info.exists()) {
          at = TrashEntry.fromJson(
            p.basename(e.path),
            jsonDecode(await info.readAsString()),
          )?.deletedAt;
        }
      } catch (_) {}
      at ??= (await e.stat()).modified;
      if (expired(at, now)) {
        await _deleteDir(e);
        n++;
      }
    }
    return n;
  }

  static Future<void> _deleteDir(Directory d) async {
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } on FileSystemException {
      // file in uso: si riprova alla prossima pulizia
    }
  }
}

/// Sposta [f] in [dest] anche fra unità diverse (copia ed elimina).
Future<File> moveFile(File f, String dest) async {
  try {
    return await f.rename(dest);
  } on FileSystemException {
    final out = await f.copy(dest);
    await f.delete();
    return out;
  }
}
