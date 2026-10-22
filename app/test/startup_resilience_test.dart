import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/database/schema.dart';

/// Avvio con database vecchi, tornati indietro di versione, parziali o
/// danneggiati: l'app si apre sempre, senza perdere dati (CRASH-1).
void main() {
  late Directory tmp;

  setUpAll(sqfliteFfiInit);
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uninotes_db_');
    AppDatabase.recoveredCopy = null;
  });
  tearDown(() async {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String dbPath() => p.join(tmp.path, AppDatabase.fileName);

  Future<Set<String>> columns(AppDatabase db, String table) async => {
    for (final c in await db.db.rawQuery('PRAGMA table_info($table)'))
      c['name'] as String,
  };

  Future<int> userVersion(AppDatabase db) async =>
      (await db.db.rawQuery('PRAGMA user_version')).first.values.first as int;

  group('migrazioni', () {
    test('database della versione 1 dello schema: si aggiorna fino ad oggi '
        'e i dati restano', () async {
      final old = await databaseFactoryFfi.openDatabase(
        dbPath(),
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            for (final s in kSchemaV1) {
              await db.execute(s);
            }
          },
        ),
      );
      await old.insert('courses', {'name': 'Analisi 1', 'external_id': 'x'});
      await old.close();

      final db = await AppDatabase.open(path: dbPath());
      expect(await userVersion(db), kSchemaVersion);
      expect(await columns(db, 'courses'), contains('custom_name'));
      expect(await columns(db, 'profile'), contains('start_year'));
      final rows = await db.db.query('courses');
      expect(rows.single['name'], 'Analisi 1');
      await db.close();
    });

    test('database tornato indietro di versione (app più vecchia, poi di '
        'nuovo aggiornata): nessun «duplicate column»', () async {
      var db = await AppDatabase.open(path: dbPath());
      await db.db.insert('courses', {'name': 'Fisica'});
      // un'app più vecchia ha riaperto il database: user_version più basso,
      // colonne nuove già presenti
      await db.db.execute('PRAGMA user_version = 5');
      await db.close();

      db = await AppDatabase.open(path: dbPath());
      expect(await userVersion(db), kSchemaVersion);
      expect((await db.db.query('courses')).single['name'], 'Fisica');
      await db.close();
    });

    test('database con una tabella mancante (parziale): si ricrea, il resto '
        'resta', () async {
      var db = await AppDatabase.open(path: dbPath());
      await db.db.insert('courses', {'name': 'Chimica'});
      await db.db.execute('DROP TABLE plan_years');
      await db.db.execute('DROP TABLE place_categories');
      await db.db.execute('DROP INDEX idx_events_start');
      await db.close();

      db = await AppDatabase.open(path: dbPath());
      expect(await columns(db, 'plan_years'), contains('status'));
      expect(await db.db.query('place_categories'), isNotEmpty);
      final idx = await db.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE name = 'idx_events_start'",
      );
      expect(idx, isNotEmpty);
      expect((await db.db.query('courses')).single['name'], 'Chimica');
      await db.close();
    });

    test('database con una colonna mancante pur con la versione attuale: '
        'la colonna torna', () async {
      var db = await AppDatabase.open(path: dbPath());
      for (final k in ['ins', 'upd', 'del']) {
        await db.db.execute('DROP TRIGGER sync_${k}_courses');
      }
      await db.db.execute('ALTER TABLE courses DROP COLUMN custom_name');
      await db.close();

      db = await AppDatabase.open(path: dbPath());
      expect(await columns(db, 'courses'), contains('custom_name'));
      await db.close();
    });

    test('istruzioni dello schema ripetute: idempotenti', () async {
      final db = await AppDatabase.openInMemory();
      for (final step in [kSchemaV1, kMigrationV6, kMigrationV13]) {
        for (final s in step) {
          await AppDatabase.runSchemaStatement(db.db, s);
        }
      }
      await AppDatabase.repairSchema(db.db);
      await db.close();
    });
  });

  group('file danneggiato', () {
    test('byte casuali al posto del database: messo da parte (non '
        'eliminato) e database nuovo', () async {
      final rnd = Random(7);
      final bytes = List<int>.generate(64 * 1024, (_) => rnd.nextInt(256));
      File(dbPath()).writeAsBytesSync(bytes);

      final db = await AppDatabase.open(path: dbPath());
      expect(await db.db.query('courses'), isEmpty);
      final aside = AppDatabase.recoveredCopy;
      expect(aside, isNotNull);
      expect(File(aside!).readAsBytesSync(), bytes);
      await db.close();
    });

    test('database troncato a metà: messo da parte e database nuovo', () async {
      var db = await AppDatabase.open(path: dbPath());
      for (var i = 0; i < 400; i++) {
        await db.db.insert('courses', {'name': 'Insegnamento $i ${'x' * 200}'});
      }
      await db.close();
      final f = File(dbPath());
      final all = f.readAsBytesSync();
      // intestazione intatta, pagine dello schema e dei dati in parte perse
      f.writeAsBytesSync(all.sublist(0, 100) + List.filled(all.length ~/ 3, 0));

      db = await AppDatabase.open(path: dbPath());
      expect(await db.db.query('courses'), isEmpty);
      expect(AppDatabase.recoveredCopy, isNotNull);
      await db.close();
    });

    test(
      'una tabella rovinata: le altre si recuperano nel database nuovo',
      () async {
        var db = await AppDatabase.open(path: dbPath());
        await db.db.insert('courses', {'name': 'Salvato'});
        await db.db.insert('events', {
          'type': 'event',
          'title': 'Perso',
          'start_at': '2026-10-05T10:00:00',
        });
        final root =
            (await db.db.rawQuery(
                  "SELECT rootpage FROM sqlite_master WHERE name = 'events'",
                )).first['rootpage']
                as int;
        final pageSize =
            (await db.db.rawQuery('PRAGMA page_size')).first.values.first
                as int;
        await db.close();
        // pagina della tabella degli eventi sovrascritta
        final raf = File(dbPath()).openSync(mode: FileMode.append);
        raf.setPositionSync((root - 1) * pageSize);
        raf.writeFromSync(List.filled(pageSize, 0xAB));
        raf.closeSync();

        db = await AppDatabase.open(path: dbPath());
        expect(AppDatabase.recoveredCopy, isNotNull);
        expect(AppDatabase.recoveredRows, greaterThan(0));
        expect((await db.db.query('courses')).single['name'], 'Salvato');
        expect(await db.db.query('events'), isEmpty);
        await db.close();
      },
    );

    test('errore che non è un danno al file: il database non si sposta', () {
      expect(
        AppDatabase.isCorruptionError(Exception('database is locked')),
        isFalse,
      );
    });
  });
}
