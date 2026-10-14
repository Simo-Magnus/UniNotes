import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'schema.dart';

/// Accesso al database SQLite locale.
///
/// Su Android usa sqflite nativo, su Windows/Linux sqflite_common_ffi.
/// [openInMemory] serve ai test.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const fileName = 'university_manager.db';

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static bool _ffiInitialized = false;

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

  static Future<AppDatabase> open({String? path}) async {
    final dbPath = path ?? await defaultPath();
    final db = await _factory().openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: kSchemaVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return AppDatabase._(db);
  }

  /// Apre in sola lettura un altro file SQLite (es. una copia del database
  /// esportata dall'app, da ripristinare).
  static Future<Database> openReadOnlyFile(String path) => _factory()
      .openDatabase(path, options: OpenDatabaseOptions(readOnly: true));

  static Future<AppDatabase> openInMemory() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: kSchemaVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    for (final stmt in [
      ...kSchemaV1,
      ...kMigrationV2,
      ...kMigrationV3,
      ...kMigrationV4,
      ...kMigrationV5,
      ...kMigrationV6,
      ...kMigrationV7,
      ...kMigrationV8,
      ...kMigrationV9,
      ...kMigrationV10,
      ...kMigrationV11,
    ]) {
      batch.execute(stmt);
    }
    for (final c in kDefaultPlaceCategories) {
      batch.insert('place_categories', c);
    }
    await batch.commit(noResult: true);
  }

  /// Le migrazioni future devono solo aggiungere colonne/tabelle:
  /// mai cancellare dati dell'utente.
  static Future<void> _onUpgrade(Database db, int from, int to) async {
    if (from < 2) {
      for (final stmt in kMigrationV2) {
        await db.execute(stmt);
      }
    }
    if (from < 3) {
      for (final stmt in kMigrationV3) {
        await db.execute(stmt);
      }
    }
    if (from < 4) {
      for (final stmt in kMigrationV4) {
        await db.execute(stmt);
      }
    }
    if (from < 5) {
      for (final stmt in kMigrationV5) {
        await db.execute(stmt);
      }
    }
    if (from < 6) {
      for (final stmt in kMigrationV6) {
        await db.execute(stmt);
      }
    }
    if (from < 7) {
      for (final stmt in kMigrationV7) {
        await db.execute(stmt);
      }
    }
    if (from < 8) {
      for (final stmt in kMigrationV8) {
        await db.execute(stmt);
      }
    }
    if (from < 9) {
      for (final stmt in kMigrationV9) {
        await db.execute(stmt);
      }
    }
    if (from < 10) {
      for (final stmt in kMigrationV10) {
        await db.execute(stmt);
      }
    }
    if (from < 11) {
      for (final stmt in kMigrationV11) {
        await db.execute(stmt);
      }
    }
  }

  Future<void> close() => db.close();
}
