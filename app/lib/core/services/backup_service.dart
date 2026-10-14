import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../../utils/parse.dart';
import '../database/app_database.dart';
import '../database/schema.dart';

class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Intestazione di un backup letto, mostrata prima di confermare il ripristino.
class BackupInfo {
  const BackupInfo({
    required this.createdAt,
    required this.schemaVersion,
    required this.rowCounts,
  });

  final DateTime? createdAt;
  final int schemaVersion;

  /// Righe per tabella presenti nel backup.
  final Map<String, int> rowCounts;

  int get totalRows => rowCounts.values.fold(0, (a, b) => a + b);
}

/// Backup e ripristino dei dati personali.
///
/// Il backup JSON contiene tutte le tabelle personali ([kPersonalTables]),
/// i luoghi creati dall'utente (`external_id` che inizia con `user:`) e i
/// colori scelti per le università. I dati pubblici (università, lauree,
/// luoghi) non sono inclusi: si riottengono con un aggiornamento dati.
class BackupService {
  BackupService(this._db);
  final AppDatabase _db;

  /// Identificatore del formato (resta quello storico per leggere i backup
  /// già esportati).
  static const format = 'university-manager-backup';

  /// true se [json] sembra un backup (e non, per esempio, un data pack).
  static bool looksLikeBackup(String json) =>
      json.contains('"format":"$format"') ||
      json.contains('"format": "$format"');
  static const version = 1;
  static const userPlacePrefix = 'user:';
  static const _placesKey = 'places';
  static const _colorsKey = 'universityColors';

  /// Impostazioni legate al dispositivo: non vengono sovrascritte dal
  /// ripristino (account e stato della sincronizzazione di OneDrive e
  /// Google Drive).
  static const deviceLocalSettings = {
    'onedrive_account',
    'onedrive_last_result',
    'gdrive_account',
    'gdrive_last_result',
  };

  /// Impostazioni di sicurezza o legate a questo computer: non si esportano
  /// né si ripristinano (un backup ricevuto da altri potrebbe indirizzare
  /// l'accesso a OneDrive, gli appunti o i programmi da avviare altrove).
  static const protectedSettings = {
    'install_id',
    'onedrive_tenant',
    'onedrive_client_id',
    'onedrive_account',
    'gdrive_account',
    'appunti_root',
    // impostazioni dismesse (Antigravity) e pulizia una tantum del dispositivo
    'agy_path',
    'legacy_gemini_removed',
    'whisper_cli_path',
    'catalog_base_url',
    'update_url',
  };

  // ---------------------------------------------------------------- export

  Future<Map<String, Object?>> exportMap() => _mapFrom(_db.db);

  /// Dati personali di una copia del database (.db) esportata dall'app, nel
  /// formato del backup JSON (si ripristinano poi con [importJson]).
  static Future<String> jsonFromDatabaseFile(String path) async {
    final Database other;
    try {
      other = await AppDatabase.openReadOnlyFile(path);
    } on Exception {
      throw BackupException('Il file non è un database di UniNotes.');
    }
    try {
      if ((await other.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'courses'",
      )).isEmpty) {
        throw BackupException('Il file non è un database di UniNotes.');
      }
      return jsonEncode(await _mapFrom(other));
    } finally {
      await other.close();
    }
  }

  static Future<Map<String, Object?>> _mapFrom(Database db) async {
    final tables = <String, Object?>{};
    for (final t in kPersonalTables) {
      try {
        final rows = await db.query(t, orderBy: _orderBy(t));
        tables[t] = t == 'app_settings'
            ? [
                for (final r in rows)
                  if (!protectedSettings.contains(r['key'])) r,
              ]
            : rows;
      } on DatabaseException {
        // tabella assente in una copia di una versione precedente
      }
    }
    try {
      tables[_placesKey] = await db.query(
        'places',
        where: 'external_id LIKE ?',
        whereArgs: ['$userPlacePrefix%'],
        orderBy: 'id',
      );
    } on DatabaseException {
      tables[_placesKey] = const <Map<String, Object?>>[];
    }
    List<Map<String, Object?>> unis;
    try {
      unis = await db.query('universities', columns: ['id', 'color']);
    } on DatabaseException {
      unis = const [];
    }
    return {
      'format': format,
      'version': version,
      'schemaVersion': kSchemaVersion,
      'createdAt': isoLocal(DateTime.now()),
      _colorsKey: {for (final u in unis) u['id'] as String: u['color']},
      'tables': tables,
    };
  }

  Future<String> exportJson() async => jsonEncode(await exportMap());

  static String _orderBy(String table) => switch (table) {
    'app_settings' => 'key',
    'place_personal' => 'place_external_id',
    'plan_years' => 'year',
    _ => 'id',
  };

  /// Copia completa del file SQLite (dati pubblici inclusi) in [destPath].
  /// Usa `VACUUM INTO` (copia coerente e compatta); se non disponibile copia
  /// il file del database.
  Future<File> exportDatabaseFile(String destPath) async {
    final dest = File(destPath);
    if (await dest.exists()) await dest.delete();
    await dest.parent.create(recursive: true);
    try {
      await _db.db.execute('VACUUM INTO ?', [destPath]);
      return dest;
    } on DatabaseException {
      final src = _db.db.path;
      if (src == inMemoryDatabasePath || !await File(src).exists()) {
        throw BackupException(
          'Impossibile copiare il database su questo dispositivo.',
        );
      }
      if (await dest.exists()) await dest.delete();
      return File(src).copy(destPath);
    }
  }

  // ---------------------------------------------------------------- import

  /// Valida il backup e ne restituisce l'intestazione senza modificare nulla.
  BackupInfo inspect(String json) {
    final parsed = _parse(json);
    return BackupInfo(
      createdAt: asDateTime(parsed.root['createdAt']),
      schemaVersion: asInt(parsed.root['schemaVersion']) ?? 0,
      rowCounts: {for (final e in parsed.tables.entries) e.key: e.value.length},
    );
  }

  /// Sostituisce tutti i dati personali con quelli del backup, in un'unica
  /// transazione: se qualcosa va storto il database resta invariato.
  /// I dati pubblici non vengono toccati (tranne i luoghi creati dall'utente
  /// e i colori delle università). Restituisce le righe ripristinate per tabella.
  Future<Map<String, int>> importJson(String json) async {
    final parsed = _parse(json);
    final restored = <String, int>{};

    await _db.db.transaction((txn) async {
      final keep = {...deviceLocalSettings, ...protectedSettings};
      final localSettings = await txn.query(
        'app_settings',
        where: 'key IN (${List.filled(keep.length, '?').join(',')})',
        whereArgs: keep.toList(),
      );

      for (final t in kPersonalTables.reversed) {
        await txn.delete(t);
      }
      await txn.delete(
        'places',
        where: 'external_id LIKE ?',
        whereArgs: ['$userPlacePrefix%'],
      );

      for (final t in kPersonalTables) {
        final rows = parsed.tables[t] ?? const [];
        final columns = await _columns(txn, t);
        var n = 0;
        for (final row in rows) {
          final data = _filter(row, columns);
          if (data.isEmpty) continue;
          if (t == 'app_settings' && !await _keepSetting(data, localSettings)) {
            continue;
          }
          await txn.insert(t, data);
          n++;
        }
        restored[t] = n;
      }
      for (final s in localSettings) {
        await txn.insert(
          'app_settings',
          s,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      restored[_placesKey] = await _restoreUserPlaces(
        txn,
        parsed.tables[_placesKey] ?? const [],
      );
      await _restoreColors(txn, parsed.root[_colorsKey]);
    });
    return restored;
  }

  /// Le impostazioni legate al dispositivo si prendono dal backup solo se il
  /// dispositivo non ne ha già una e il percorso indicato esiste qui.
  static Future<bool> _keepSetting(
    Map<String, Object?> row,
    List<Map<String, Object?>> localSettings,
  ) async {
    final key = row['key'];
    if (protectedSettings.contains(key)) return false;
    if (!deviceLocalSettings.contains(key)) return true;
    if (localSettings.any((s) => s['key'] == key)) return false;
    final value = asString(row['value']);
    return value != null && await File(value).exists();
  }

  Future<int> _restoreUserPlaces(
    Transaction txn,
    List<Map<String, Object?>> rows,
  ) async {
    final columns = await _columns(txn, 'places');
    var n = 0;
    for (final row in rows) {
      final ext = asString(row['external_id']);
      if (ext == null || !ext.startsWith(userPlacePrefix)) continue;
      final data = _filter(row, columns);
      // L'id potrebbe essere già usato da un luogo pubblico: in quel caso
      // se ne assegna uno nuovo.
      final id = data['id'];
      if (id != null &&
          (await txn.query(
            'places',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [id],
          )).isNotEmpty) {
        data.remove('id');
      }
      await txn.insert('places', data);
      n++;
    }
    return n;
  }

  Future<void> _restoreColors(Transaction txn, Object? colors) async {
    if (colors is! Map) return;
    for (final e in colors.entries) {
      final color = asInt(e.value);
      if (color == null) continue;
      await txn.update(
        'universities',
        {'color': color},
        where: 'id = ?',
        whereArgs: [e.key.toString()],
      );
    }
  }

  static Future<Set<String>> _columns(DatabaseExecutor ex, String table) async {
    final info = await ex.rawQuery('PRAGMA table_info($table)');
    return {for (final c in info) c['name'] as String};
  }

  /// Tiene solo le colonne esistenti; converte valori non SQL in testo.
  static Map<String, Object?> _filter(
    Map<String, Object?> row,
    Set<String> columns,
  ) {
    final out = <String, Object?>{};
    for (final e in row.entries) {
      if (!columns.contains(e.key)) continue;
      final v = e.value;
      out[e.key] = switch (v) {
        null || num() || String() => v,
        bool() => v ? 1 : 0,
        _ => jsonEncode(v),
      };
    }
    return out;
  }

  static _ParsedBackup _parse(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json.startsWith('﻿') ? json.substring(1) : json);
    } on FormatException catch (e) {
      throw BackupException('File di backup non valido (JSON): ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw BackupException(
        'File di backup non valido: atteso un oggetto JSON.',
      );
    }
    if (decoded['format'] != format) {
      if (decoded['format'] == 'university-manager-datapack') {
        throw BackupException(
          'Questo file contiene corsi ed esami, non i tuoi dati esportati: '
          'il piano di studi si aggiorna da Impostazioni → Il mio percorso → '
          'Aggiorna database.',
        );
      }
      throw BackupException('Il file non è un backup di UniNotes.');
    }
    final v = asInt(decoded['version']) ?? 0;
    if (v < 1 || v > version) {
      throw BackupException(
        'Versione del backup ($v) non supportata da questa app.',
      );
    }
    final rawTables = decoded['tables'];
    if (rawTables is! Map<String, Object?>) {
      throw BackupException('Backup non valido: sezione "tables" mancante.');
    }
    final tables = <String, List<Map<String, Object?>>>{};
    for (final t in [...kPersonalTables, _placesKey]) {
      final rows = rawTables[t];
      if (rows == null) continue;
      if (rows is! List || rows.any((r) => r is! Map<String, Object?>)) {
        throw BackupException('Backup non valido: tabella "$t" malformata.');
      }
      tables[t] = rows.cast<Map<String, Object?>>();
    }
    return _ParsedBackup(decoded, tables);
  }
}

class _ParsedBackup {
  _ParsedBackup(this.root, this.tables);
  final Map<String, Object?> root;
  final Map<String, List<Map<String, Object?>>> tables;
}
