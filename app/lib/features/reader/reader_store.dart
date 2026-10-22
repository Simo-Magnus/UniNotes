import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/services/portable_path.dart';
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
    // anche 12.0 (dati sincronizzati da un'altra versione o piattaforma)
    final pos = j['p'];
    if (pos is! num || !pos.isFinite) return null;
    return ReaderBookmark(
      pos.toInt(),
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

  /// Impostazioni dell'app (scelte «Non chiedere più» del lettore).
  SettingsRepository get settings => _settings;

  static const recentKey = 'reader_recent';

  /// File recenti ricordati: in «File» se ne mostrano [shownRecent], gli
  /// altri con «Mostra altri».
  static const maxRecent = 50;

  /// Recenti mostrati subito in «File»: circa due settimane di studio
  /// (dispense, libri e registrazioni dei corsi del semestre) senza
  /// allungare troppo la pagina sul telefono.
  static const shownRecent = 20;

  /// Chiave del file: percorso e dimensione.
  static String keyFor(String path, int size) =>
      'reader:${sha1.convert(utf8.encode('${p.normalize(path)}|$size')).toString().substring(0, 20)}';

  /// Chiave del file per il lettore: per i file dentro l'app (libri,
  /// materiali, allegati) dal percorso relativo, uguale su tutti i
  /// dispositivi, così posizione e segnalibri si sincronizzano
  /// (impostazioni `reader:` in SyncSchema).
  static Future<String> keyOf(String path) async {
    var size = 0;
    try {
      size = await File(path).length();
    } catch (_) {}
    return keyFor(portablePath(path), size);
  }

  Future<ReaderFileState> load(String path) async {
    var raw = await _settings.get(await keyOf(path));
    // chiave delle versioni precedenti (percorso assoluto del dispositivo)
    if (raw == null) {
      var size = 0;
      try {
        size = await File(path).length();
      } catch (_) {}
      raw = await _settings.get(keyFor(path, size));
    }
    if (raw == null) return const ReaderFileState();
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const ReaderFileState();
      // Un campo rovinato non deve far perdere gli altri: i segnalibri si
      // riscrivono al primo salvataggio della posizione.
      final pos = j['pos'];
      final bm = j['bm'];
      return ReaderFileState(
        position: pos is num && pos.isFinite ? pos.toInt() : null,
        bookmarks: [
          if (bm is List)
            for (final b in bm) ?ReaderBookmark.fromJson(b),
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
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      // voci rovinate saltate una per una (le altre restano)
      return [
        for (final e in list)
          if (e is Map && e['path'] is String && e['path'] != '')
            RecentFile(
              e['path'] as String,
              e['title']?.toString() ?? p.basename(e['path'] as String),
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

  /// Rimette l'elenco dei recenti com'era (es. «Annulla» dopo averne tolto
  /// uno o averlo cancellato).
  Future<void> setRecent(List<RecentFile> list) => _settings.set(
    recentKey,
    list.isEmpty
        ? null
        : jsonEncode([
            for (final r in list.take(maxRecent))
              {
                'path': r.path,
                'title': r.title,
                'at': r.opened.toIso8601String(),
              },
          ]),
  );
}
