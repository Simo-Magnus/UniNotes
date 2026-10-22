import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/database/schema.dart';
import 'package:university_notes/core/database/sync_schema.dart';
import 'package:university_notes/core/services/backup_service.dart';
import 'package:university_notes/core/services/calendar_export.dart';
import 'package:university_notes/features/cloud/data_sync.dart';
import 'package:university_notes/features/exams/exam_ui.dart';
import 'package:university_notes/features/study/study_timer.dart';
import 'package:university_notes/models/calendar_entry.dart';
import 'package:university_notes/models/calendar_event.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/repositories/book_repository.dart';
import 'package:university_notes/repositories/calendar_repository.dart';
import 'package:university_notes/repositories/course_repository.dart';
import 'package:university_notes/repositories/exam_repository.dart';
import 'package:university_notes/repositories/profile_repository.dart';
import 'package:university_notes/repositories/study_repository.dart';
import 'package:university_notes/utils/dates.dart';
import 'package:university_notes/utils/parse.dart';

/// Secondo giro della caccia ai crash, categoria «tempo e integrità dei dati
/// nel tempo» (R2-E): migrazioni da ogni versione storica dello schema,
/// orologi diversi tra dispositivi, ora legale, istanti UTC, orologio
/// spostato indietro.

/// Istruzioni dello schema in ordine: la versione k ha le prime k.
const _steps = [
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

/// La sincronizzazione (colonne sync_*, trigger) è arrivata con la v12.
const _syncSince = 12;

Future<Set<String>> _cols(DatabaseExecutor db, String t) async => {
  for (final c in await db.rawQuery('PRAGMA table_info($t)'))
    c['name'] as String,
};

/// Inserisce solo le colonne che la tabella ha in quella versione.
Future<int?> _put(Database db, String t, Map<String, Object?> v) async {
  final cols = await _cols(db, t);
  if (cols.isEmpty) return null;
  return db.insert(t, {
    for (final e in v.entries)
      if (cols.contains(e.key)) e.key: e.value,
  });
}

/// Database com'era alla versione [v] dello schema (stesse istruzioni delle
/// versioni pubblicate: lo schema è solo additivo, `git log -p` di
/// schema.dart), con dati realistici di uno studente.
Future<void> _oldDatabase(String path, int v) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: v,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        for (final step in _steps.take(v)) {
          for (final s in step) {
            await db.execute(s);
          }
        }
        for (final c in kDefaultPlaceCategories) {
          await db.insert('place_categories', c);
        }
      },
    ),
  );
  if (v >= _syncSince) await SyncSchema.ensure(db);
  final analisi = await _put(db, 'courses', {
    'external_id': 'polito:course:01ABC',
    'university_id': 'polito',
    'name': 'Analisi I',
    'year': 1,
    'cfu': 10.0,
    'status': 'active',
    'books_status': 'completo',
    'user_edited': 1,
    'custom_name': 'Analisi 1 (mia)',
  });
  final mano = await _put(db, 'courses', {'name': 'Laboratorio', 'cfu': 6.0});
  await _put(db, 'events', {
    'external_id': 'polito:event:1',
    'course_id': analisi,
    'type': 'lecture',
    'title': 'Lezione di Analisi',
    // ora che non esiste (passaggio all'ora legale)
    'start_at': '2027-03-28T02:30:00',
    'end_at': '2027-03-28T04:00:00',
  });
  await _put(db, 'exams', {
    'external_id': 'polito:exam:01ABC',
    'course_id': analisi,
    'title': 'Scritto',
    'date': '2028-02-29',
    'time': '09:00',
    'status': 'passed',
    'grade': 28,
    'notes': 'Portare la calcolatrice',
    'imported_notes': 'Portare la calcolatrice',
    'imported_topics': 'Limiti',
  });
  await _put(db, 'exams', {'course_id': mano, 'status': 'planned'});
  final m = await _put(db, 'modules', {
    'course_id': analisi,
    'name': 'Limiti',
    'notes': 'nota',
  });
  // stesso nome nello stesso insegnamento: identificativi #2
  await _put(db, 'modules', {'course_id': analisi, 'name': 'limiti '});
  final t = await _put(db, 'topics', {
    'module_id': m,
    'name': 'Asintoti',
    'status': 'done',
    'theory_done': 1,
  });
  await _put(db, 'study_sessions', {
    'course_id': analisi,
    'topic_id': t,
    'module_id': m,
    // ora doppia (ritorno all'ora solare)
    'start_at': '2026-10-25T02:30:00',
    'end_at': '2026-10-25T04:00:00',
    'duration_minutes': 90,
    'focus': 1,
  });
  await _put(db, 'books', {
    'external_id': 'polito:book:1',
    'course_id': analisi,
    'title': 'Analisi matematica 1',
    'ownership_status': 'owned',
    'last_page': 120,
    'last_opened_at': '2026-10-01T10:00:00',
    'catalog_choice': 'kept',
  });
  await _put(db, 'materials', {'course_id': analisi, 'title': 'Esercizi'});
  await _put(db, 'attachments', {
    'module_id': m,
    'title': 'Registrazione',
    'path': r'C:\Users\x\appunti\Analisi I\lezione.m4a',
    'created_at': '2026-10-05T10:00:00',
    'kinds': 'teoria',
  });
  await _put(db, 'place_personal', {
    'place_external_id': 'polito:place:1',
    'favorite': 1,
  });
  await _put(db, 'app_settings', {
    'key': 'exclusion_patterns',
    'value': 'Inglese',
  });
  await _put(db, 'profile', {
    'id': 1,
    'university_id': 'polito',
    'university_name': 'Politecnico di Torino',
    'degree_id': 'polito:ing-inf',
    'degree_name': 'Ingegneria informatica',
    'degree_type': 'L',
    'duration_years': 3,
    'current_year': 2,
    'reference_aa': '2026/27',
    'created_at': '2025-10-01T10:00:00',
    'start_year': 1,
  });
  await _put(db, 'plan_years', {
    'year': 1,
    'academic_year': '2025/26',
    'status': 'completato',
  });
  await _put(db, 'mail_accounts', {
    'label': 'Ateneo',
    'email': 'a@b.it',
    'username': 'a',
    'imap_host': 'imap',
    'imap_port': 993,
    'smtp_host': 'smtp',
    'smtp_port': 465,
  });
  await db.close();
}

/// Righe di ogni tabella (per verificare che nulla si perda).
Future<Map<String, int>> _counts(Database db) async => {
  for (final r in await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%' AND name != 'sync_tombstones'",
  ))
    '${r['name']}':
        (await db.rawQuery('SELECT COUNT(*) AS n FROM "${r['name']}"'))
                .first['n']
            as int,
};

/// Un dispositivo per i test della sincronizzazione.
class _Device {
  _Device(this.name, this.db, this.root)
    : sync = DataSync(db, stateDir: () async => root);
  final String name;
  final AppDatabase db;
  final Directory root;
  final DataSync sync;

  static Future<_Device> create(String name, Directory tmp) async {
    final root = Directory(p.join(tmp.path, name))..createSync();
    return _Device(
      name,
      await AppDatabase.open(path: p.join(root.path, 'db.sqlite')),
      root,
    );
  }

  Directory get dati => Directory(p.join(root.path, 'dati'))..createSync();
  String get own => DataSync.ownFileName(name, name);

  Future<void> merge() =>
      sync.mergeFolder(dati, ownName: own, device: name, installId: name);

  void exchange(_Device o) {
    final f = File(p.join(o.dati.path, o.own));
    if (f.existsSync()) f.copySync(p.join(dati.path, o.own));
  }

  Future<List<Map<String, Object?>>> q(String sql) => db.db.rawQuery(sql);
}

Future<void> _syncAll(_Device a, _Device b) async {
  for (var i = 0; i < 3; i++) {
    a.exchange(b);
    await a.merge();
    b.exchange(a);
    await b.merge();
  }
}

/// Primo giorno del [year] in cui, nel fuso del dispositivo, da una
/// mezzanotte alla successiva non passano 24 ore (passaggio all'ora legale);
/// null se il fuso non ha l'ora legale.
DateTime? _shortDay(int year) {
  for (var d = DateTime(year); d.year == year; d = addDays(d, 1)) {
    if (addDays(d, 1).difference(d) < const Duration(hours: 24)) return d;
  }
  return null;
}

void main() {
  late Directory tmp;
  setUpAll(sqfliteFfiInit);
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uninotes_r2e_');
    AppDatabase.recoveredCopy = null;
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('migrazioni da ogni versione storica', () {
    late Map<String, Set<String>> current;
    setUpAll(() async {
      final fresh = await AppDatabase.openInMemory();
      current = {
        for (final r in await fresh.db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%'",
        ))
          '${r['name']}': await _cols(fresh.db, '${r['name']}'),
      };
      await fresh.close();
    });

    for (var v = 1; v <= kSchemaVersion; v++) {
      test('versione $v → $kSchemaVersion: schema completo, nessun dato '
          'perso, dati leggibili; riaprire non cambia nulla', () async {
        final path = p.join(tmp.path, 'v$v.db');
        await _oldDatabase(path, v);
        final raw = await databaseFactoryFfi.openDatabase(path);
        final before = await _counts(raw);
        await raw.close();

        var db = await AppDatabase.open(path: path);
        expect(AppDatabase.recoveredCopy, isNull);
        expect(
          (await db.db.rawQuery('PRAGMA user_version')).first.values.first,
          kSchemaVersion,
        );
        // tutte le tabelle e le colonne dello schema attuale
        for (final e in current.entries) {
          expect(
            await _cols(db.db, e.key),
            containsAll(e.value),
            reason: 'tabella ${e.key}',
          );
        }
        // nessuna riga persa (le tabelle nate dopo partono vuote)
        final after = await _counts(db.db);
        for (final e in before.entries) {
          expect(after[e.key], e.value, reason: 'righe di ${e.key}');
        }
        expect(
          (await db.db.rawQuery('PRAGMA integrity_check')).first.values.first,
          'ok',
        );
        expect(await db.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
        // ogni riga sincronizzata ha il suo identificativo, unico
        for (final s in SyncSchema.tables.where((s) => s.hasSyncId)) {
          expect(
            await db.db.rawQuery(
              'SELECT 1 FROM ${s.table} WHERE sync_id IS NULL '
              'OR sync_mtime IS NULL',
            ),
            isEmpty,
            reason: s.table,
          );
          expect(
            await db.db.rawQuery(
              'SELECT sync_id FROM ${s.table} GROUP BY sync_id '
              'HAVING COUNT(*) > 1',
            ),
            isEmpty,
            reason: s.table,
          );
        }
        // valori conservati
        final c = (await db.db.query(
          'courses',
          where: "external_id = 'polito:course:01ABC'",
        )).single;
        expect(c['name'], 'Analisi I');
        expect(c['cfu'], 10.0);
        final x = (await db.db.query(
          'exams',
          where: 'external_id IS NOT NULL',
        )).single;
        expect(x['grade'], 28);
        expect(x['date'], '2028-02-29');
        expect(x['notes'], 'Portare la calcolatrice');
        // note importate dal seed: considerate non modificate (v4)
        expect(x['imported_notes'], 'Portare la calcolatrice');
        final s = (await db.db.query('study_sessions')).single;
        expect(s['start_at'], '2026-10-25T02:30:00');
        expect(s['duration_minutes'], 90);
        expect(s['focus'], v >= 9 ? 1 : 0);
        // le schermate leggono i dati senza errori
        expect(await CourseRepository(db).all(), hasLength(2));
        final exams = await ExamRepository(db).all();
        expect(exams, hasLength(2));
        expect(
          exams.firstWhere((e) => e.grade == 28).date,
          DateTime(2028, 2, 29),
        );
        expect(await StudyRepository(db).sessions(), hasLength(1));
        expect(await BookRepository(db).all(), hasLength(1));
        final profile = await ProfileRepository(db).load();
        if (v >= 6) {
          expect(profile!.currentYear, 2);
          expect(profile.startYear, v >= 13 ? 1 : null);
        } else {
          expect(profile, isNull);
        }
        final events = await CalendarRepository(db)
            .eventsBetween(DateTime(2027, 3, 27), DateTime(2027, 3, 30));
        expect(events, hasLength(1));
        final mtimes = await db.db.rawQuery(
          'SELECT sync_id, sync_mtime FROM courses ORDER BY id',
        );
        await db.close();

        // seconda apertura: identica (idempotente)
        db = await AppDatabase.open(path: path);
        expect(
          await db.db.rawQuery(
            'SELECT sync_id, sync_mtime FROM courses ORDER BY id',
          ),
          mtimes,
        );
        expect(await _counts(db.db), after);
        await db.close();
      });
    }

    test('database di una versione più recente (colonna e tabella '
        'sconosciute): si apre, i dati sconosciuti restano', () async {
      final path = p.join(tmp.path, 'futuro.db');
      var db = await AppDatabase.open(path: path);
      await db.db.execute('ALTER TABLE courses ADD COLUMN futura TEXT');
      await db.db.execute('CREATE TABLE futura_tabella (x TEXT)');
      await db.db.insert('futura_tabella', {'x': 'dato'});
      await db.db.insert('courses', {'name': 'Fisica', 'futura': 'valore'});
      await db.db.execute('PRAGMA user_version = ${kSchemaVersion + 3}');
      await db.close();

      db = await AppDatabase.open(path: path);
      expect((await db.db.query('courses')).single['futura'], 'valore');
      expect((await db.db.query('futura_tabella')).single['x'], 'dato');
      // la modifica di una colonna sconosciuta conta per la sincronizzazione
      final m0 = (await db.db.query('courses')).single['sync_mtime'] as int;
      await db.db.update('courses', {'futura': 'nuovo'});
      final m1 = (await db.db.query('courses')).single['sync_mtime'] as int;
      expect(m1, isNot(m0));
      await db.close();
    });
  });

  group('repairSchema: casi limite', () {
    test(
      'tabella persa con colonne aggiunte dopo (allegati, v4 + v10): si '
      'ricrea con tutte le colonne, prima la tabella poi le colonne',
      () async {
        final path = p.join(tmp.path, 'parziale.db');
        var db = await AppDatabase.open(path: path);
        await db.db.execute('DROP TABLE attachments');
        await db.close();

        db = await AppDatabase.open(path: path);
        expect(
          await _cols(db.db, 'attachments'),
          containsAll(['module_id', 'kinds', 'sync_id', 'sync_mtime']),
        );
        await db.db.insert('attachments', {
          'title': 'x',
          'created_at': '2026-10-05T10:00:00',
        });
        await db.close();
      },
    );

    test('colonna NOT NULL con valore predefinito persa su righe esistenti: '
        'torna con il valore predefinito, le righe restano', () async {
      final path = p.join(tmp.path, 'colonna.db');
      var db = await AppDatabase.open(path: path);
      for (var i = 0; i < 3; i++) {
        await db.db.insert('study_sessions', {
          'start_at': '2026-10-0${i + 1}T10:00:00',
          'duration_minutes': 30,
        });
      }
      for (final k in ['ins', 'upd', 'del']) {
        await db.db.execute('DROP TRIGGER sync_${k}_study_sessions');
      }
      await db.db.execute('ALTER TABLE study_sessions DROP COLUMN focus');
      await db.close();

      db = await AppDatabase.open(path: path);
      final rows = await db.db.query('study_sessions');
      expect(rows, hasLength(3));
      expect(rows.map((r) => r['focus']), everyElement(0));
      expect(await StudyRepository(db).sessions(), hasLength(3));
      await db.close();
    });

    test('identificativi doppi già presenti (indice non unico): l\'apertura '
        'non fallisce e li rende unici', () async {
      final path = p.join(tmp.path, 'doppi.db');
      var db = await AppDatabase.open(path: path);
      final c = await db.db.insert('courses', {'name': 'A'});
      for (var i = 0; i < 3; i++) {
        await db.db.insert('modules', {'course_id': c, 'name': 'Uguale'});
      }
      await db.db.update('modules', {'sync_id': 'stesso', 'sync_mtime': 5});
      await db.close();

      db = await AppDatabase.open(path: path);
      final ids = [
        for (final r in await db.db.query('modules', orderBy: 'id'))
          r['sync_id'],
      ];
      expect(ids, ['stesso', 'stesso#2', 'stesso#3']);
      await db.close();
    });
  });

  group('backup di altre versioni e piattaforme', () {
    test('backup di una versione vecchia (senza colonne nuove né '
        'sincronizzazione) e di una più nuova (colonne sconosciute), da '
        'Windows: si ripristina, i dati si leggono', () async {
      final db = await AppDatabase.openInMemory();
      final future = DateTime.now()
          .add(const Duration(days: 90))
          .millisecondsSinceEpoch;
      final json = jsonEncode({
        'format': BackupService.format,
        'version': 1,
        'schemaVersion': kSchemaVersion + 2,
        'createdAt': '2030-01-01T10:00:00',
        'tables': {
          'courses': [
            {'id': 1, 'name': 'Analisi I', 'campo_futuro': 'x'},
            {
              'id': 2,
              'name': 'Fisica',
              'sync_id': 'c:#abc',
              // backup fatto con l'orologio avanti
              'sync_mtime': future,
            },
          ],
          'exams': [
            {'id': 1, 'course_id': 1, 'date': '2028-02-29', 'grade': 30},
          ],
          'modules': [
            {'id': 1, 'course_id': 1, 'name': 'Limiti'},
          ],
          'attachments': [
            {
              'id': 1,
              'module_id': 1,
              'title': 'Lezione',
              'path': r'C:\Users\x\appunti\Analisi\lezione.m4a',
              'created_at': '2026-10-05T10:00:00',
            },
          ],
          'study_sessions': [
            {
              'id': 1,
              'course_id': 1,
              'start_at': '2027-03-28T02:30:00',
              'duration_minutes': 45,
            },
          ],
        },
      });
      final n = await BackupService(db).importJson(json);
      expect(n['courses'], 2);
      expect(await CourseRepository(db).all(), hasLength(2));
      expect(
        (await ExamRepository(db).all()).single.date,
        DateTime(2028, 2, 29),
      );
      expect(await StudyRepository(db).sessions(), hasLength(1));
      // modifica dopo il ripristino: viene dopo l'orario del backup
      await db.db.update('courses', {'name': 'Fisica I'}, where: 'id = 2');
      final m =
          (await db.db.query('courses', where: 'id = 2')).single['sync_mtime']
              as int;
      expect(m, greaterThan(future));
      await db.close();
    });
  });

  group('orologi diversi tra dispositivi', () {
    test('trigger: una modifica dopo un orario nel futuro viene dopo di '
        'quello (non prima)', () async {
      final db = await AppDatabase.openInMemory();
      final future = DateTime.now()
          .add(const Duration(days: 400))
          .millisecondsSinceEpoch;
      final id = await db.db.insert('courses', {'name': 'Fisica'});
      // riga arrivata dalla sincronizzazione da un dispositivo avanti
      await db.db.update('courses', {'name': 'Fisica I', 'sync_mtime': future});
      await db.db.update('courses', {'name': 'Fisica 1'});
      final m = (await db.db.query('courses')).single['sync_mtime'] as int;
      expect(m, greaterThan(future));
      await db.db.delete('courses', where: 'id = ?', whereArgs: [id]);
      final d =
          (await db.db.query(SyncSchema.tombstones)).single['deleted_at']
              as int;
      expect(d, greaterThan(m));
      await db.close();
    });

    test(
      'dispositivo con l\'orologio avanti: le modifiche fatte dopo '
      'sull\'altro non vengono annullate e le eliminazioni restano',
      () async {
        final a = await _Device.create('A', tmp);
        final b = await _Device.create('B', tmp);
        for (final d in [a, b]) {
          final c = await d.db.db.insert('courses', {
            'external_id': 'polito:course:01ABC',
            'name': 'Analisi I',
          });
          final m = await d.db.db.insert('modules', {
            'course_id': c,
            'name': 'Limiti',
          });
          await d.db.db.insert('topics', {'module_id': m, 'name': 'Asintoti'});
          await d.db.db.insert('topics', {'module_id': m, 'name': 'Derivate'});
        }
        await _syncAll(a, b);
        // A ha l'orologio 30 giorni avanti: la sua modifica è «nel futuro»
        final future = DateTime.now()
            .add(const Duration(days: 30))
            .millisecondsSinceEpoch;
        await a.db.db.update('topics', {
          'status': 'review',
          'sync_mtime': future,
        }, where: "name = 'Asintoti'");
        await _syncAll(a, b);
        expect(
          (await b.q("SELECT status FROM topics WHERE name = 'Asintoti'"))
              .single['status'],
          'review',
        );
        // dopo, sull'altro dispositivo (ora giusta) lo studente la cambia
        await b.db.db.update('topics', {
          'status': 'done',
        }, where: "name = 'Asintoti'");
        await _syncAll(a, b);
        for (final d in [a, b]) {
          expect(
            (await d.q("SELECT status FROM topics WHERE name = 'Asintoti'"))
                .single['status'],
            'done',
            reason: d.name,
          );
        }
        // e poi lo elimina: non torna
        await b.db.db.delete('topics', where: "name = 'Asintoti'");
        await _syncAll(a, b);
        for (final d in [a, b]) {
          expect((await d.q('SELECT name FROM topics')).map((r) => r['name']), [
            'Derivate',
          ], reason: d.name);
        }
        await a.db.close();
        await b.db.close();
      },
    );
  });

  group('ora legale e giorni di calendario', () {
    final short = _shortDay(2027);

    test('prova il giorno dopo il passaggio all\'ora legale: «domani», non '
        '«oggi»', () {
      final day = short ?? DateTime(2027, 3, 28);
      final next = addDays(day, 1);
      final exam = Exam(courseId: 1, date: next);
      expect(daysUntil(exam, now: day.add(const Duration(hours: 10))), 1);
      expect(
        daysUntil(
          Exam(courseId: 1, date: addDays(day, 10)),
          now: addDays(day, -5),
        ),
        15,
      );
    });

    test('evento di un giorno intero nel giorno di 23 ore: finisce a '
        'mezzanotte, non il giorno dopo all\'1:00', () {
      final day = short ?? DateTime(2027, 3, 28);
      final e = CalendarEvent(
        type: EventType.event,
        title: 'Festa',
        start: day,
        allDay: true,
      );
      expect(e.effectiveEnd, addDays(day, 1));
      final entry = CalendarEntry(
        kind: CalendarEntryKind.event,
        title: e.title,
        start: e.start,
        end: e.effectiveEnd,
        color: Colors.blue,
        allDay: true,
      );
      expect(entryTouchesDay(entry, day), isTrue);
      expect(entryTouchesDay(entry, addDays(day, 1)), isFalse);
    });

    test('prova di un giorno intero nel giorno di 23 ore: nel calendario '
        'finisce a mezzanotte', () async {
      final day = short ?? DateTime(2027, 3, 28);
      final db = await AppDatabase.openInMemory();
      final c = await db.db.insert('courses', {'name': 'Chimica'});
      await db.db.insert('exams', {'course_id': c, 'date': isoDate(day)});
      final entries = await CalendarRepository(db)
          .entriesBetween(day, addDays(day, 1));
      final x = entries.singleWhere((e) => e.exam != null);
      expect(x.end, addDays(day, 1));
      await db.close();
    });
  });

  group('istanti e orologio', () {
    test('file .ics con una prova dell\'anno 800 o del 9999: date di 4 '
        'cifre, fine dopo l\'inizio', () {
      final ics = buildIcs([
        (
          exam: Exam(id: 1, courseId: 1, date: DateTime(800, 1, 1)),
          course: 'A',
        ),
        (
          exam: Exam(id: 2, courseId: 1, date: DateTime(9999, 12, 31)),
          course: 'B',
        ),
      ], now: DateTime(2026, 10, 22));
      expect(ics, contains('DTSTART;VALUE=DATE:08000101'));
      expect(ics, contains('DTEND;VALUE=DATE:08000102'));
      expect(ics, contains('DTSTART;VALUE=DATE:99991231'));
    });

    test('istante UTC salvato nell\'ora locale (non con i campi UTC)', () {
      final utc = DateTime.utc(2026, 10, 5, 8);
      expect(isoLocal(utc), isoLocal(utc.toLocal()));
      expect(DateTime.parse(isoLocal(utc)), utc.toLocal());
    });

    test('orologio del sistema spostato indietro mentre si studia: il '
        'tempo già studiato resta e la fine non precede l\'inizio', () {
      var now = DateTime(2026, 10, 5, 10);
      final timer = StudyTimer(clock: () => now, tick: false);
      timer.start();
      now = now.add(const Duration(minutes: 30));
      timer.pause();
      timer.start();
      // l'orologio torna indietro di un'ora
      now = now.subtract(const Duration(hours: 1));
      expect(timer.elapsed, const Duration(minutes: 30));
      final s = timer.stop()!;
      expect(s.durationMinutes, 30);
      expect(s.end!.isBefore(s.start), isFalse);
    });

    test('profilo creato prima del cambio d\'anno accademico (31 agosto → '
        '1° settembre): anno di partenza giusto', () {
      final p = StudentProfile.fromMap({
        'id': 1,
        'university_id': 'x',
        'university_name': 'X',
        'degree_id': 'x:l',
        'degree_name': 'L',
        'degree_type': 'L',
        'duration_years': 3,
        'current_year': 2,
        'reference_aa': '2026/27',
      });
      expect(deriveStartYear(p, createdAt: DateTime(2026, 8, 31, 23, 59)), 1);
      expect(deriveStartYear(p, createdAt: DateTime(2026, 9, 1)), 2);
      expect(deriveStartYear(p, createdAt: DateTime(2030)), 2);
    });
  });
}
