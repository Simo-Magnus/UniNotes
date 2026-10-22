import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/error_log.dart';
import 'schema.dart';
import 'sync_schema.dart';

/// Accesso al database SQLite locale.
///
/// Su Android usa sqflite nativo, su Windows/Linux sqflite_common_ffi.
/// [openInMemory] serve ai test.
///
/// Robustezza all'avvio:
/// - le istruzioni dello schema (tabelle, indici, colonne) si eseguono solo
///   per ciò che manca, così un database già (in parte) aggiornato, tornato
///   indietro di versione con un'app più vecchia o arrivato da un'altra
///   versione si apre senza «duplicate column» o «table already exists»;
/// - a ogni apertura le tabelle e le colonne mancanti (database parziale) si
///   ricreano, senza toccare i dati;
/// - un file danneggiato (non è un database SQLite o è corrotto) si mette da
///   parte con un altro nome, mai eliminato, e l'app riparte con un database
///   nuovo ([recoveredCopy]).
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const fileName = 'university_manager.db';

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static bool _ffiInitialized = false;

  /// Percorso della copia danneggiata messa da parte all'ultima apertura
  /// (null = nessuna): l'app lo dice allo studente una volta.
  static String? recoveredCopy;

  /// Android: sqflite nativo. Desktop: FFI (sqlite3.dll incluso dal plugin).
  static DatabaseFactory _factory() {
    if (_isDesktop) {
      if (!_ffiInitialized) {
        sqfliteFfiInit();
        _ffiInitialized = true;
      }
      return databaseFactoryFfi;
    }
    return sqflite.databaseFactory;
  }

  static Future<String> defaultPath() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return p.join(dir.path, fileName);
  }

  static OpenDatabaseOptions get _options => OpenDatabaseOptions(
    version: kSchemaVersion,
    onConfigure: _onConfigure,
    onCreate: _onCreate,
    onUpgrade: _onUpgrade,
    onOpen: _onOpen,
  );

  static Future<AppDatabase> open({String? path}) async {
    final dbPath = path ?? await defaultPath();
    final factory = _factory();
    try {
      return AppDatabase._(
        await factory.openDatabase(dbPath, options: _options),
      );
    } catch (e, st) {
      if (!isCorruptionError(e) || !await File(dbPath).exists()) rethrow;
      await ErrorLog.record(e, st, context: 'Database danneggiato');
      final aside = await _setAside(dbPath);
      final fresh = await factory.openDatabase(dbPath, options: _options);
      recoveredRows = await salvage(fresh, aside);
      recoveredCopy = aside;
      return AppDatabase._(fresh);
    }
  }

  /// Righe ancora leggibili recuperate dalla copia danneggiata all'ultima
  /// apertura (vedi [salvage]).
  static int recoveredRows = 0;

  /// Copia nel database nuovo [db] le tabelle ancora leggibili del file
  /// danneggiato [asidePath] (una tabella con pagine rovinate si salta, le
  /// altre si recuperano). Solo le colonne presenti in entrambi. Restituisce
  /// le righe recuperate; mai un'eccezione.
  @visibleForTesting
  static Future<int> salvage(Database db, String asidePath) async {
    var n = 0;
    try {
      await db.execute('ATTACH DATABASE ? AS vecchio', [asidePath]);
    } catch (_) {
      return 0; // non è nemmeno un database: niente da recuperare
    }
    try {
      await db.execute('PRAGMA foreign_keys = OFF');
      final tables = [
        for (final r in await db.rawQuery(
          "SELECT name FROM main.sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%'",
        ))
          '${r['name']}',
      ];
      for (final t in tables) {
        try {
          final mine = {
            for (final c in await db.rawQuery('PRAGMA main.table_info($t)'))
              '${c['name']}',
          };
          final cols = [
            for (final c in await db.rawQuery('PRAGMA vecchio.table_info($t)'))
              if (mine.contains('${c['name']}')) '"${c['name']}"',
          ];
          if (cols.isEmpty) continue;
          final list = cols.join(', ');
          // (rawUpdate restituisce le righe toccate dall'istruzione)
          n += await db.rawUpdate(
            'INSERT OR IGNORE INTO main."$t" ($list) '
            'SELECT $list FROM vecchio."$t"',
          );
        } catch (_) {
          // tabella illeggibile nella copia danneggiata: resta vuota
        }
      }
    } catch (_) {
      // copia illeggibile già dallo schema
    } finally {
      try {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.execute('DETACH DATABASE vecchio');
      } catch (_) {}
    }
    return n;
  }

  /// Il database non è leggibile come SQLite (SQLITE_CORRUPT, SQLITE_NOTADB):
  /// non è un errore passeggero (a differenza di disco pieno, file bloccato,
  /// permessi).
  static bool isCorruptionError(Object e) {
    if (e is! DatabaseException) return false;
    final code = e.getResultCode();
    if (code != null) {
      final primary = code & 0xff;
      if (primary == 11 || primary == 26) return true;
    }
    final s = '$e'.toLowerCase();
    return s.contains('file is not a database') ||
        s.contains('database disk image is malformed') ||
        s.contains('file is encrypted or is not a database');
  }

  /// Rinomina il database [dbPath] (e i file -wal, -shm, -journal) in
  /// `<nome>.danneggiato-<data>`; restituisce il nuovo percorso.
  static Future<String> _setAside(String dbPath) async {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final aside = '$dbPath.danneggiato-$stamp';
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final f = File('$dbPath$suffix');
      if (!await f.exists()) continue;
      try {
        await f.rename('$aside$suffix');
      } on FileSystemException {
        // file bloccato: si copia e poi si toglie quello danneggiato
        await f.copy('$aside$suffix');
        await f.delete();
      }
    }
    return aside;
  }

  /// Apre in sola lettura un altro file SQLite (es. una copia del database
  /// esportata dall'app, da ripristinare).
  static Future<Database> openReadOnlyFile(String path) => _factory()
      .openDatabase(path, options: OpenDatabaseOptions(readOnly: true));

  static Future<AppDatabase> openInMemory() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: _options,
    );
    return AppDatabase._(db);
  }

  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
    if (_isDesktop) {
      // un'altra connessione che scrive (motore in background, seconda
      // finestra): si aspetta fino a 5 s invece di «database is locked»
      try {
        await db.rawQuery('PRAGMA busy_timeout = 5000');
      } catch (_) {}
    }
  }

  /// Tutte le istruzioni dello schema, in ordine.
  static const List<List<String>> _steps = [
    kSchemaV1,
    kMigrationV2,
    kMigrationV3,
    kMigrationV4,
    kMigrationV5,
    kMigrationV6,
    kMigrationV7,
    kMigrationV8,
    kMigrationV9,
    kMigrationV10,
    kMigrationV11,
    kMigrationV12,
    kMigrationV13,
  ];

  static Future<void> _onCreate(Database db, int version) async {
    for (final step in _steps) {
      for (final stmt in step) {
        await runSchemaStatement(db, stmt);
      }
    }
    await _defaultCategories(db);
  }

  static Future<void> _defaultCategories(DatabaseExecutor db) async {
    final batch = db.batch();
    for (final c in kDefaultPlaceCategories) {
      batch.insert(
        'place_categories',
        c,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Le migrazioni future devono solo aggiungere colonne/tabelle:
  /// mai cancellare dati dell'utente. La migrazione alla versione k+1 è
  /// `_steps[k]`.
  static Future<void> _onUpgrade(Database db, int from, int to) async {
    for (var v = from < 1 ? 0 : from; v < _steps.length && v < to; v++) {
      for (final stmt in _steps[v]) {
        await runSchemaStatement(db, stmt);
      }
    }
  }

  static Future<void> _onOpen(Database db) async {
    try {
      await repairSchema(db);
      // metadati della sincronizzazione tra dispositivi (sync_schema.dart)
      await SyncSchema.ensure(db);
    } catch (e, st) {
      // disco pieno: i dati si leggono lo stesso (le scritture daranno
      // errore finché non si libera spazio); la preparazione si rifà al
      // prossimo avvio
      if (!isDiskFullError(e)) rethrow;
      await ErrorLog.record(e, st, context: 'Apertura del database');
    }
  }

  static final _addColumn = RegExp(
    r'^\s*ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)',
    caseSensitive: false,
  );
  static final _create = RegExp(
    r'^\s*CREATE\s+(TABLE|INDEX)\s+(?!IF\s+NOT\s+EXISTS)',
    caseSensitive: false,
  );

  /// Esegue un'istruzione dello schema solo se serve: `ALTER TABLE … ADD
  /// COLUMN` se la colonna manca, `CREATE TABLE/INDEX` con `IF NOT EXISTS`.
  /// Le altre istruzioni (es. un UPDATE di una migrazione) si eseguono così
  /// come sono.
  @visibleForTesting
  static Future<void> runSchemaStatement(
    DatabaseExecutor db,
    String stmt,
  ) async {
    final add = _addColumn.firstMatch(stmt);
    if (add != null) {
      final cols = await db.rawQuery('PRAGMA table_info(${add[1]})');
      if (cols.isEmpty) return; // tabella assente: la ricrea repairSchema
      if (cols.any(
        (c) => '${c['name']}'.toLowerCase() == add[2]!.toLowerCase(),
      )) {
        return;
      }
      await db.execute(stmt);
      return;
    }
    await db.execute(
      stmt.replaceFirstMapped(_create, (m) => '${m[0]}IF NOT EXISTS '),
    );
  }

  /// Ricrea tabelle, indici e colonne mancanti (database parziale, per
  /// esempio una tabella persa o una versione dello schema segnata ma non
  /// applicata del tutto). Solo istruzioni di struttura: nessun dato cambia.
  /// Senza nulla da fare costa una lettura dello schema.
  @visibleForTesting
  static Future<void> repairSchema(DatabaseExecutor db) async {
    final present = <String, Set<String>>{};
    final indexes = <String>{};
    for (final r in await db.rawQuery(
      "SELECT type, name FROM sqlite_master WHERE type IN ('table', 'index')",
    )) {
      final name = '${r['name']}'.toLowerCase();
      if (r['type'] == 'index') {
        indexes.add(name);
      } else {
        present[name] = {};
      }
    }
    final missing = <String>[];
    final createTable = RegExp(
      r'^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)',
      caseSensitive: false,
    );
    final createIndex = RegExp(
      r'^\s*CREATE\s+INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)',
      caseSensitive: false,
    );
    for (final step in _steps) {
      for (final stmt in step) {
        final t = createTable.firstMatch(stmt);
        if (t != null) {
          if (!present.containsKey(t[1]!.toLowerCase())) missing.add(stmt);
          continue;
        }
        final i = createIndex.firstMatch(stmt);
        if (i != null) {
          if (!indexes.contains(i[1]!.toLowerCase())) missing.add(stmt);
          continue;
        }
        final a = _addColumn.firstMatch(stmt);
        if (a == null) continue; // non di struttura
        final table = a[1]!.toLowerCase();
        final cols = present[table];
        if (cols == null) {
          // tabella che manca: si ricrea prima, poi le sue colonne
          missing.add(stmt);
          continue;
        }
        if (cols.isEmpty) {
          for (final c in await db.rawQuery('PRAGMA table_info($table)')) {
            cols.add('${c['name']}'.toLowerCase());
          }
        }
        if (!cols.contains(a[2]!.toLowerCase())) missing.add(stmt);
      }
    }
    if (missing.isEmpty) return;
    for (final stmt in missing) {
      await runSchemaStatement(db, stmt);
    }
    if (missing.any((s) => s.contains('place_categories'))) {
      await _defaultCategories(db);
    }
  }

  Future<void> close() => db.close();
}
