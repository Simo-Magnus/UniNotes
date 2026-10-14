import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/database/schema.dart';
import 'package:university_notes/core/services/backup_service.dart';

Future<void> _seed(AppDatabase db) async {
  final d = db.db;
  // Dati pubblici.
  await d.insert('universities', {
    'id': 'polito',
    'name': 'Politecnico di Torino',
    'short_name': 'PoliTo',
    'color': 0xFF1565C0,
  });
  await d.insert('universities', {
    'id': 'unito',
    'name': 'Università di Torino',
    'short_name': 'UniTO',
    'color': 0xFFC62828,
  });
  await d.insert('degrees', {
    'id': 'polito:ing',
    'university_id': 'polito',
    'name': 'Ing. Informatica',
  });
  await d.insert('places', {
    'external_id': 'osm:node:1',
    'category_id': 'library',
    'name': 'Biblioteca centrale',
    'lat': 45.06,
    'lon': 7.66,
  });
  await d.insert('benefits', {
    'external_id': 'polito:benefit:o365',
    'category': 'software',
    'title': 'Microsoft 365',
  });
  // Luogo creato dall'utente.
  await d.insert('places', {
    'external_id': 'user:casa-studio',
    'category_id': 'study_room',
    'name': 'Aula studio sotto casa',
    'lat': 45.07,
    'lon': 7.67,
  });

  // Dati personali.
  final c1 = await d.insert('courses', {
    'external_id': 'polito:course:A',
    'university_id': 'polito',
    'name': 'Analisi I',
    'cfu': 10.0,
    'status': 'completed',
    'color': 0xFF00FF00,
  });
  final c2 = await d.insert('courses', {
    'university_id': 'unito',
    'name': 'Psicologia generale',
    'cfu': 9.0,
  });
  await d.insert('events', {
    'external_id': 'e1',
    'course_id': c1,
    'type': 'lecture',
    'title': 'Analisi I',
    'start_at': '2026-10-05T08:30:00',
    'end_at': '2026-10-05T10:00:00',
    'notes': 'portare calcolatrice',
  });
  await d.insert('exams', {
    'course_id': c1,
    'kind': 'final',
    'title': 'Appello',
    'date': '2027-01-20',
    'status': 'passed',
    'grade': 30,
    'laude': 1,
    'study_materials': jsonEncode(['Lezioni 1-8']),
  });
  final m = await d.insert('modules', {
    'course_id': c2,
    'name': 'Modulo 1',
    'sort': 0,
  });
  final t = await d.insert('topics', {
    'module_id': m,
    'name': 'Percezione',
    'status': 'in_progress',
  });
  await d.insert('study_sessions', {
    'course_id': c2,
    'topic_id': t,
    'start_at': '2026-10-02T15:00:00',
    'duration_minutes': 45,
    'activity_type': 'theory',
  });
  await d.insert('books', {
    'course_id': c1,
    'title': 'Analisi 1',
    'format': 'paper',
    'ownership_status': 'owned',
  });
  await d.insert('materials', {
    'course_id': c1,
    'title': 'L01.pdf',
    'kind': 'lecture',
  });
  await d.insert('place_personal', {
    'place_external_id': 'osm:node:1',
    'favorite': 1,
    'notes': 'ottima',
  });
  await d.insert('app_settings', {'key': 'surname_initial', 'value': 'M'});
  await d.insert('app_settings', {
    'key': 'onedrive_account',
    'value': 'questo-dispositivo@example.org',
  });
}

/// Contenuto delle tabelle; l'account OneDrive è un'impostazione del
/// dispositivo e viene ignorato.
Future<Map<String, List<Map<String, Object?>>>> _dump(
  AppDatabase db,
  List<String> tables,
) async => {
  for (final t in tables)
    t: t == 'app_settings'
        ? await db.db.query(
            t,
            where: "key != 'onedrive_account'",
            orderBy: 'key',
          )
        : await db.db.query(t),
};

void main() {
  late AppDatabase db;
  late BackupService backup;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    backup = BackupService(db);
    await _seed(db);
  });
  tearDown(() => db.close());

  test('export contiene tabelle personali, luoghi utente e colori', () async {
    final map = jsonDecode(await backup.exportJson()) as Map<String, Object?>;
    expect(map['format'], BackupService.format);
    expect(map['version'], 1);
    expect(map['schemaVersion'], kSchemaVersion);
    final tables = map['tables'] as Map<String, Object?>;
    for (final t in kPersonalTables) {
      expect(tables.containsKey(t), isTrue, reason: t);
    }
    final places = tables['places'] as List;
    expect(places.map((p) => (p as Map)['external_id']), ['user:casa-studio']);
    expect((map['universityColors'] as Map)['polito'], 0xFF1565C0);
  });

  test(
    'roundtrip export → cancellazione → import ripristina i dati personali',
    () async {
      final before = await _dump(db, kPersonalTables);
      final json = await backup.exportJson();

      // Cancella e altera tutto il personale.
      for (final t in kPersonalTables.reversed) {
        await db.db.delete(t);
      }
      await db.db.delete('places', where: "external_id LIKE 'user:%'");
      await db.db.insert('courses', {'name': 'Corso spurio'});
      await db.db.update('universities', {'color': 0xFF000000});

      final restored = await backup.importJson(json);
      expect(restored['courses'], 2);
      expect(restored['places'], 1);

      final after = await _dump(db, kPersonalTables);
      for (final t in kPersonalTables) {
        expect(after[t], before[t], reason: 'tabella $t');
      }
      final user = await db.db.query(
        'places',
        where: 'external_id = ?',
        whereArgs: ['user:casa-studio'],
      );
      expect(user.single['name'], 'Aula studio sotto casa');
      final polito = await db.db.query('universities', where: "id = 'polito'");
      expect(polito.single['color'], 0xFF1565C0);
    },
  );

  test('le tabelle pubbliche restano invariate', () async {
    final json = await backup.exportJson();
    await db.db.insert('benefits', {
      'external_id': 'unito:benefit:x',
      'category': 'discount',
      'title': 'Sconto nuovo',
    });
    final publicBefore = await _dump(db, [
      'degrees',
      'place_categories',
      'benefits',
    ]);
    final publicPlacesBefore = await db.db.query(
      'places',
      where: "external_id NOT LIKE 'user:%'",
      orderBy: 'id',
    );

    await backup.importJson(json);

    expect(
      await _dump(db, ['degrees', 'place_categories', 'benefits']),
      publicBefore,
    );
    expect(
      await db.db.query(
        'places',
        where: "external_id NOT LIKE 'user:%'",
        orderBy: 'id',
      ),
      publicPlacesBefore,
    );
  });

  test('l\'account OneDrive del dispositivo non viene sovrascritto', () async {
    final json = await backup.exportJson();
    await db.db.update('app_settings', {
      'value': 'nuovo@example.org',
    }, where: "key = 'onedrive_account'");
    await backup.importJson(json);
    final v = await db.db.query(
      'app_settings',
      where: "key = 'onedrive_account'",
    );
    expect(v.single['value'], 'nuovo@example.org');
  });

  test('ripristino da una copia del database (.db)', () async {
    final dir = await Directory.systemTemp.createTemp('un_db_copy_');
    try {
      final copy = await backup.exportDatabaseFile('${dir.path}/copia.db');
      final json = await BackupService.jsonFromDatabaseFile(copy.path);
      expect(BackupService.looksLikeBackup(json), isTrue);
      expect(backup.inspect(json).totalRows, greaterThan(0));
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('JSON non valido o di formato diverso lascia il DB invariato', () async {
    final before = await _dump(db, [...kPersonalTables, 'places']);
    await expectLater(
      backup.importJson('{non json'),
      throwsA(isA<BackupException>()),
    );
    await expectLater(
      backup.importJson(
        jsonEncode({'format': 'university-manager-datapack', 'version': 1}),
      ),
      throwsA(isA<BackupException>()),
    );
    await expectLater(
      backup.importJson(
        jsonEncode({
          'format': BackupService.format,
          'version': 99,
          'tables': {},
        }),
      ),
      throwsA(isA<BackupException>()),
    );
    await expectLater(
      backup.importJson(
        jsonEncode({
          'format': BackupService.format,
          'version': 1,
          'tables': {'courses': 'oops'},
        }),
      ),
      throwsA(isA<BackupException>()),
    );
    expect(await _dump(db, [...kPersonalTables, 'places']), before);
  });

  test('un errore a metà ripristino annulla tutto (atomicità)', () async {
    final before = await _dump(db, [...kPersonalTables, 'places']);
    final map = jsonDecode(await backup.exportJson()) as Map<String, Object?>;
    final tables = map['tables'] as Map<String, Object?>;
    // Riga che viola NOT NULL su topics.name: fallisce dopo aver già
    // cancellato e reinserito courses/events/exams/modules.
    (tables['topics'] as List).add({'id': 999, 'module_id': 1, 'name': null});
    await expectLater(backup.importJson(jsonEncode(map)), throwsA(anything));
    expect(await _dump(db, [...kPersonalTables, 'places']), before);
  });

  test('colonne sconosciute vengono ignorate', () async {
    final map = jsonDecode(await backup.exportJson()) as Map<String, Object?>;
    final courses = (map['tables'] as Map<String, Object?>)['courses'] as List;
    (courses.first as Map<String, Object?>)['colonna_futura'] = 'x';
    map['tables'] = {
      ...map['tables'] as Map<String, Object?>,
      'tabella_futura': [],
    };
    final restored = await backup.importJson(jsonEncode(map));
    expect(restored['courses'], 2);
  });

  test('inspect legge intestazione e conteggi', () async {
    final info = backup.inspect(await backup.exportJson());
    expect(info.rowCounts['courses'], 2);
    expect(info.rowCounts['places'], 1);
    expect(info.createdAt, isNotNull);
    expect(info.schemaVersion, kSchemaVersion);
  });

  test('exportDatabaseFile crea una copia SQLite leggibile', () async {
    final dir = await Directory.systemTemp.createTemp('um_backup_test');
    try {
      final f = await backup.exportDatabaseFile('${dir.path}/copia.db');
      expect(await f.exists(), isTrue);
      final header = (await f.openRead(0, 15).first);
      expect(String.fromCharCodes(header), 'SQLite format 3');
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
