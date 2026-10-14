import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../repositories/settings_repository.dart';

/// Segnalibro in un file: posizione (pagina, blocco o secondi) ed etichetta.
class ReaderBookmark {
  const ReaderBookmark(this.position, this.label, this.created);
  final int position;
  final String label;
  final DateTime created;

  Map<String, Object> toJson() => {
    'p': position,
    'l': label,
    'c': created.toIso8601String(),
  };

  static ReaderBookmark? fromJson(Object? j) {
    if (j is! Map) return null;
    final pos = j['p'];
    if (pos is! int) return null;
    return ReaderBookmark(
      pos,
      j['l']?.toString() ?? '',
      DateTime.tryParse(j['c']?.toString() ?? '') ?? DateTime(2000),
    );
  }
}

/// Stato di lettura di un file: ultima posizione e segnalibri.
class ReaderFileState {
  const ReaderFileState({this.position, this.bookmarks = const []});
  final int? position;
  final List<ReaderBookmark> bookmarks;
}

/// File aperto di recente.
class RecentFile {
  const RecentFile(this.path, this.title, this.opened);
  final String path;
  final String title;
  final DateTime opened;

  String get name => p.basename(path);
}

/// Memoria del lettore nelle impostazioni dell'app (`app_settings`):
/// una voce per file, chiave = hash di percorso + dimensione (un file
/// sostituito con un altro diverso riparte dall'inizio), più l'elenco dei
/// file recenti.
class ReaderStore {
  ReaderStore(this._settings);
  final SettingsRepository _settings;

  static const recentKey = 'reader_recent';
  static const maxRecent = 30;

  /// Chiave del file: percorso e dimensione.
  static String keyFor(String path, int size) =>
      'reader:${sha1.convert(utf8.encode('${p.normalize(path)}|$size')).toString().substring(0, 20)}';

  static Future<String> keyOf(String path) async {
    var size = 0;
    try {
      size = await File(path).length();
    } catch (_) {}
    return keyFor(path, size);
  }

  Future<ReaderFileState> load(String path) async {
    final raw = await _settings.get(await keyOf(path));
    if (raw == null) return const ReaderFileState();
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return ReaderFileState(
        position: j['pos'] as int?,
        bookmarks: [
          for (final b in (j['bm'] as List? ?? const []))
            ?ReaderBookmark.fromJson(b),
        ],
      );
    } catch (_) {
      return const ReaderFileState();
    }
  }

  Future<void> _save(String path, ReaderFileState s) => keyOf(path).then(
    (key) => _settings.set(
      key,
      jsonEncode({
        'pos': ?s.position,
        'bm': [for (final b in s.bookmarks) b.toJson()],
      }),
    ),
  );

  Future<void> savePosition(String path, int position) async {
    final s = await load(path);
    await _save(
      path,
      ReaderFileState(position: position, bookmarks: s.bookmarks),
    );
  }

  Future<List<ReaderBookmark>> addBookmark(
    String path,
    ReaderBookmark b,
  ) async {
    final s = await load(path);
    final list = [
      for (final x in s.bookmarks)
        if (x.position != b.position) x,
      b,
    ]..sort((a, b) => a.position.compareTo(b.position));
    await _save(path, ReaderFileState(position: s.position, bookmarks: list));
    return list;
  }

  Future<List<ReaderBookmark>> removeBookmark(String path, int position) async {
    final s = await load(path);
    final list = [
      for (final x in s.bookmarks)
        if (x.position != position) x,
    ];
    await _save(path, ReaderFileState(position: s.position, bookmarks: list));
    return list;
  }

  Future<List<RecentFile>> recent() async {
    final raw = await _settings.get(recentKey);
    if (raw == null) return const [];
    try {
      return [
        for (final e in (jsonDecode(raw) as List).cast<Map>())
          RecentFile(
            e['path'].toString(),
            e['title']?.toString() ?? p.basename(e['path'].toString()),
            DateTime.tryParse(e['at']?.toString() ?? '') ?? DateTime(2000),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> addRecent(String path, {String? title, DateTime? now}) async {
    final list = [
      RecentFile(path, title ?? p.basename(path), now ?? DateTime.now()),
      for (final r in await recent())
        if (p.normalize(r.path) != p.normalize(path)) r,
    ].take(maxRecent);
    await _settings.set(
      recentKey,
      jsonEncode([
        for (final r in list)
          {'path': r.path, 'title': r.title, 'at': r.opened.toIso8601String()},
      ]),
    );
  }

  Future<void> removeRecent(String path) async {
    final list = [
      for (final r in await recent())
        if (r.path != path) r,
    ];
    await _settings.set(
      recentKey,
      jsonEncode([
        for (final r in list)
          {'path': r.path, 'title': r.title, 'at': r.opened.toIso8601String()},
      ]),
    );
  }

  Future<void> clearRecent() => _settings.set(recentKey, null);
}
