import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'notes_store.dart' show NotesStore;
import 'safe_files.dart';

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
      // (orario con «:» anche per i titoli salvati con «08-30»)
      title: NotesStore.displayName('${j['titolo'] ?? id}'),
      course: j['corso'] is String ? j['corso'] as String : null,
      deletedAt: at,
      files: [
        for (final f in jsonList(j['file']))
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

  /// Dopo i 30 giorni un elemento si cancella solo se è visto scaduto da
  /// almeno questo tempo: con l'orologio del dispositivo portato avanti per
  /// errore (batteria della scheda madre, data sbagliata, fuso) tutto il
  /// cestino risultava scaduto e spariva in un colpo, senza rimedio. Così
  /// chi corregge l'orologio entro [grace] non perde nulla.
  static const grace = Duration(days: 3);

  /// File nella cartella dell'elemento con il momento in cui lo si è visto
  /// scaduto la prima volta.
  static const expiredMark = '.scaduto';

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
    final planned = <(File, String, String)>[];
    final used = <String>{};
    for (final f in existing) {
      var name = p.basename(f.path);
      for (var i = 2; !used.add(name.toLowerCase()); i++) {
        name =
            '${p.basenameWithoutExtension(f.path)} ($i)${p.extension(f.path)}';
      }
      planned.add((
        f,
        name,
        originDir == null ? f.path : p.join(originDir, p.basename(f.path)),
      ));
    }
    final entry = TrashEntry(
      id: id,
      title: title,
      course: course,
      deletedAt: now,
      files: [for (final (_, name, origin) in planned) (name, origin)],
    );
    // prima i dati dell'elemento (scritti in modo sicuro), poi i file: se
    // l'app si chiude a metà l'elemento si vede ed è ripristinabile (i file
    // non ancora spostati sono rimasti al loro posto)
    final moved = <(File, String)>[];
    try {
      await writeStringAtomic(
        File(p.join(folder.path, 'info.json')),
        jsonEncode(entry.toJson()),
      );
      for (final (f, name, _) in planned) {
        final dest = p.join(folder.path, name);
        await moveFile(f, dest);
        moved.add((f, dest));
      }
    } catch (_) {
      // file bloccato, disco pieno: si rimette a posto ciò che si è già
      // spostato (nessun file sparisce senza comparire nel cestino)
      var stuck = 0;
      for (final (f, dest) in moved.reversed) {
        try {
          await moveFile(File(dest), f.path);
        } catch (_) {
          stuck++;
        }
      }
      // un file rimasto nel cestino resta visibile lì (con i suoi dati)
      if (stuck == 0) await _deleteDir(folder);
      rethrow;
    }
    return entry;
  }

  /// Elementi del cestino, dal più recente (quelli scaduti si cancellano).
  Future<List<TrashEntry>> list() async {
    await purge();
    final base = await dir();
    if (!await base.exists()) return const [];
    final out = <TrashEntry>[];
    try {
      await for (final e in base.list()) {
        if (e is! Directory) continue;
        final info = File(p.join(e.path, 'info.json'));
        try {
          if (!await info.exists()) continue;
          final entry = TrashEntry.fromJson(
            p.basename(e.path),
            jsonDecode(await info.readAsString()),
          );
          if (entry != null) out.add(entry);
        } catch (_) {
          // elemento illeggibile: resta finché non scade la cartella
        }
      }
    } on FileSystemException {
      // cestino sparito o illeggibile durante l'elenco (disco scollegato,
      // sincronizzazione): si mostrano gli elementi già letti
    }
    out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return out;
  }

  /// Rimette i file al loro posto (con « (ripristinato)» se nel frattempo
  /// è comparso un file con lo stesso nome). Restituisce i file ripristinati.
  Future<List<File>> restore(TrashEntry e) async {
    final root = (await _root()).path;
    final folder = Directory(p.join(root, dirName, e.id));
    // origini nella cartella degli appunti attuale (se nel frattempo è
    // cambiata, i file tornavano in quella di prima, dove l'app non guarda)
    e = _here(e, root);
    final out = <File>[];
    // il suffisso è lo stesso per tutti i file dell'elemento (registrazione
    // e dati restano collegati dal nome)
    var suffix = '';
    for (var i = 1; ; i++) {
      final s = i == 1
          ? ''
          : (i == 2 ? ' (ripristinato)' : ' (ripristinato $i)');
      // solo i file ancora nel cestino (dopo un ripristino interrotto quelli
      // già rimessi a posto non sono un conflitto)
      final clash = await Future.wait([
        for (final (name, origin) in e.files)
          if (File(p.join(folder.path, name)).existsSync())
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

  /// Cartelle dei file degli appunti dentro la cartella di un insegnamento
  /// (`NoteFolder.dirName`, più «Claude», il nome di prima di «AI»).
  static const noteFolderNames = {
    'Registrazioni',
    'Trascrizioni',
    'Riassunti',
    'Appunti',
    'AI',
    'Claude',
  };

  /// Percorso di ripristino di un file eliminato da [origin] con la cartella
  /// degli appunti ora in [root] (stessa logica di `currentTargetDir` per le
  /// registrazioni rimaste): dentro la radice attuale resta com'è; un file
  /// di un insegnamento (`…/<insegnamento>/<Registrazioni|Appunti…>/<file>`)
  /// rimasto con la radice di prima va nella stessa cartella di quella
  /// attuale; un percorso che non è degli appunti resta quello.
  static String currentOrigin(String origin, String root) {
    if (p.isWithin(root, origin)) return origin;
    final parts = p.split(origin);
    if (parts.length < 4) return origin;
    final sub = parts[parts.length - 2];
    final course = parts[parts.length - 3];
    if (!noteFolderNames.contains(sub) || course.startsWith('.')) {
      return origin;
    }
    return p.join(root, course, sub, parts.last);
  }

  /// [e] con le origini nella cartella degli appunti [root] ([currentOrigin]).
  static TrashEntry _here(TrashEntry e, String root) => TrashEntry(
    id: e.id,
    title: e.title,
    course: e.course,
    deletedAt: e.deletedAt,
    files: [
      for (final (name, origin) in e.files) (name, currentOrigin(origin, root)),
    ],
  );

  /// «Annulla» dopo un ripristino: i file [restored] (restituiti da
  /// [restore]) tornano nel cestino come l'elemento [e] di prima, con la
  /// stessa data di eliminazione (i 30 giorni non ripartono).
  Future<void> undoRestore(TrashEntry e, List<File> restored) async {
    final root = (await _root()).path;
    final folder = Directory(p.join(root, dirName, e.id));
    await folder.create(recursive: true);
    final here = _here(e, root);
    for (final f in restored) {
      if (!await f.exists()) continue;
      final name = _trashNameOf(here, f.path) ?? p.basename(f.path);
      await moveFile(f, p.join(folder.path, name));
    }
    await writeStringAtomic(
      File(p.join(folder.path, 'info.json')),
      jsonEncode(e.toJson()),
    );
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
    try {
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
          at ??= (await e.stat()).modified;
        } catch (_) {
          continue;
        }
        if (!expired(at, now)) {
          // (orologio tornato a posto: l'annotazione non vale più)
          await _clearMark(e);
        } else if (await _graceOver(e, now)) {
          await _deleteDir(e);
          n++;
        }
      }
    } on FileSystemException {
      // cartella del cestino illeggibile: si riprova alla prossima pulizia
    }
    return n;
  }

  /// L'elemento scaduto [e] è stato visto scaduto da almeno [grace]. La
  /// prima volta (o se l'orologio è tornato indietro dopo l'annotazione) si
  /// annota il momento e si aspetta: non si cancella nulla.
  static Future<bool> _graceOver(Directory e, DateTime now) async {
    final mark = File(p.join(e.path, expiredMark));
    try {
      DateTime? seen;
      if (await mark.exists()) {
        seen = DateTime.tryParse((await mark.readAsString()).trim());
      }
      if (seen == null || seen.isAfter(now)) {
        await writeStringAtomic(mark, now.toIso8601String());
        return false;
      }
      return now.difference(seen) >= grace;
    } catch (_) {
      // annotazione non leggibile o non scrivibile (sola lettura): per
      // sicurezza non si cancella
      return false;
    }
  }

  static Future<void> _clearMark(Directory e) async {
    try {
      final mark = File(p.join(e.path, expiredMark));
      if (await mark.exists()) await mark.delete();
    } catch (_) {}
  }

  static Future<void> _deleteDir(Directory d) async {
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } on FileSystemException {
      // file in uso: si riprova alla prossima pulizia
    }
  }
}

/// Sposta [f] in [dest] anche fra unità diverse (copia ed elimina). Con la
/// copia: prima in `<dest>.part`, poi rinominata; se la copia o la
/// cancellazione dell'originale non riescono (disco pieno, file in uso) si
/// toglie la copia e l'originale resta com'era (mai un file a metà al posto
/// giusto, mai due copie).
Future<File> moveFile(File f, String dest) async {
  try {
    return await f.rename(dest);
  } on FileSystemException {
    final part = File('$dest.part');
    final File out;
    try {
      await f.copy(part.path);
      out = await part.rename(dest);
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
    try {
      await f.delete();
    } catch (_) {
      try {
        await out.delete();
      } catch (_) {}
      rethrow;
    }
    return out;
  }
}
