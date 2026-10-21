import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/database/sync_schema.dart';
import 'package:university_notes/core/services/backup_service.dart';
import 'package:university_notes/features/cloud/data_sync.dart';

/// Un dispositivo: database, cartella di stato e copia locale di `Dati`.
class _Device {
  _Device._(this.name, this.db, this.root, this.sync);
  final String name;
  final AppDatabase db;
  final Directory root;
  final DataSync sync;
  int applied = 0;

  static Future<_Device> create(String name, Directory tmp) async {
    final root = Directory(p.join(tmp.path, name))..createSync();
    // un file per dispositivo (i database in memoria sarebbero lo stesso)
    final db = await AppDatabase.open(path: p.join(root.path, 'db.sqlite'));
    late _Device d;
    final sync = DataSync(
      db,
      stateDir: () async => root,
      notesRoot: () async => p.join(root.path, 'appunti'),
    );
    d = _Device._(name, db, root, sync);
    return d;
  }

  Directory get dati => Directory(p.join(root.path, 'dati'))..createSync();
  String get own => DataSync.ownFileName(name, name);

  Future<DataMergeResult> merge() async {
    final r = await sync.mergeFolder(
      dati,
      ownName: own,
      device: name,
      installId: name,
    );
    applied += r.applied;
    return r;
  }

  /// «Carica» il proprio registro e «scarica» quelli degli altri (come il
  /// motore dei file con la cartella Dati del servizio).
  void exchange(List<_Device> others) {
    for (final o in others) {
      final f = File(p.join(o.dati.path, o.own));
      if (f.existsSync()) f.copySync(p.join(dati.path, o.own));
    }
  }

  Future<int> insert(String t, Map<String, Object?> v) => db.db.insert(t, v);

  Future<List<Map<String, Object?>>> q(String sql, [List<Object?>? a]) =>
      db.db.rawQuery(sql, a);

  Future<int> courseId(String ext) async =>
      (await q('SELECT id FROM courses WHERE external_id = ?', [
            ext,
          ])).first['id']
          as int;

  Future<int> topicId(String name) async =>
      (await q('SELECT id FROM topics WHERE name = ?', [name])).first['id']
          as int;
}

/// Stesso database dei corsi su un dispositivo (import del catalogo):
/// insegnamento, modulo e due argomenti.
Future<void> _catalog(_Device d) async {
  final c = await d.insert('courses', {
    'external_id': 'polito:course:01ABC',
    'name': 'Analisi I',
    'cfu': 10.0,
  });
  final m = await d.insert('modules', {'course_id': c, 'name': 'Limiti'});
  await d.insert('topics', {'module_id': m, 'name': 'Limiti notevoli'});
  await d.insert('topics', {'module_id': m, 'name': 'Asintoti'});
  await d.insert('exams', {
    'external_id': 'polito:exam:01ABC',
    'course_id': c,
    'title': 'Analisi I',
  });
}

/// Unione a giro finché nessuno ha più novità (come più sincronizzazioni).
Future<void> _syncAll(List<_Device> all, {int rounds = 3}) async {
  for (var i = 0; i < rounds; i++) {
    for (final d in all) {
      d.exchange(all.where((o) => o != d).toList());
      await d.merge();
    }
  }
}

Future<void> _later() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('data_sync_');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // database ancora aperto dopo un test fallito
    }
  });

  group('schema', () {
    test(
      'identificativi stabili, orari e segnaposto delle eliminazioni',
      () async {
        final d = await _Device.create('A', tmp);
        await _catalog(d);
        final topic = (await d.q('SELECT * FROM topics ORDER BY id')).first;
        expect(
          topic['sync_id'],
          't:m:c:polito:course:01ABC/limiti/limiti notevoli',
        );
        // solo inserita: orario negativo
        expect((topic['sync_mtime'] as int) < 0, isTrue);
        await _later();
        await d.db.db.update(
          'topics',
          {'status': 'done'},
          where: 'id = ?',
          whereArgs: [topic['id']],
        );
        final after =
            (await d.q('SELECT sync_mtime FROM topics WHERE id = ?', [
                  topic['id'],
                ])).first['sync_mtime']
                as int;
        expect(after > 0, isTrue);
        // un UPDATE senza cambiamenti non conta come modifica
        await d.db.db.update(
          'topics',
          {'status': 'done'},
          where: 'id = ?',
          whereArgs: [topic['id']],
        );
        expect(
          (await d.q('SELECT sync_mtime FROM topics WHERE id = ?', [
            topic['id'],
          ])).first['sync_mtime'],
          after,
        );
        // eliminazione a cascata: segnaposto anche per modulo e argomenti
        await d.db.db.delete('courses');
        final tombs = await d.q(
          'SELECT tbl, sync_id FROM ${SyncSchema.tombstones} ORDER BY tbl',
        );
        expect(tombs.map((t) => t['tbl']).toSet(), {
          'courses',
          'modules',
          'topics',
          'exams',
        });
        await d.db.close();
      },
    );

    test('impostazioni: solo quelle sincronizzate lasciano il segnaposto; '
        'ensure è idempotente', () async {
      final d = await _Device.create('A', tmp);
      await d.insert('app_settings', {'key': 'theme_mode', 'value': 'light'});
      await d.insert('app_settings', {
        'key': 'focus_daily_goal',
        'value': '90',
      });
      await d.db.db.delete('app_settings');
      final tombs = await d.q('SELECT sync_id FROM ${SyncSchema.tombstones}');
      expect(tombs.map((t) => t['sync_id']), ['focus_daily_goal']);
      await SyncSchema.ensure(d.db.db);
      await SyncSchema.ensure(d.db.db);
      final cols = await SyncSchema.columnsOf(d.db.db, 'topics');
      expect(cols.where((c) => c == 'sync_id'), hasLength(1));
      await d.db.close();
    });

    test('doppioni sullo stesso dispositivo: #2, #3 nell\'ordine', () async {
      final d = await _Device.create('A', tmp);
      final c = await d.insert('courses', {'external_id': 'x', 'name': 'X'});
      for (var i = 0; i < 3; i++) {
        await d.insert('modules', {'course_id': c, 'name': 'Esercizi'});
      }
      await SyncSchema.dedupe(d.db.db);
      final ids = (await d.q('SELECT sync_id FROM modules ORDER BY id'))
          .map((r) => r['sync_id']);
      expect(ids, ['m:c:x/esercizi', 'm:c:x/esercizi#2', 'm:c:x/esercizi#3']);
      await d.db.close();
    });
  });

  group('unione dei registri', () {
    SyncSnapshot snap(Map<String, SyncEntry> rows) =>
        SyncSnapshot(tables: {'topics': rows});

    test('per colonna vince la modifica più recente', () {
      final a = snap({
        't1': SyncEntry(
          values: {'status': 'done', 'notes': 'a'},
          times: {'status': 10, 'notes': 5},
        ),
      });
      final b = snap({
        't1': SyncEntry(
          values: {'status': 'started', 'notes': 'b'},
          times: {'status': 8, 'notes': 9},
        ),
      });
      final m = mergeSnapshots([a, b]).entry('topics', 't1')!;
      expect(m.values, {'status': 'done', 'notes': 'b'});
      expect(m.times, {'status': 10, 'notes': 9});
    });

    test('commutativa, idempotente, pari merito deciso ovunque uguale', () {
      final a = snap({
        't1': SyncEntry(values: {'status': 'done'}, times: {'status': 7}),
      });
      final b = snap({
        't1': SyncEntry(values: {'status': 'started'}, times: {'status': 7}),
        't2': SyncEntry(values: {'status': 'x'}, times: {'status': 1}),
      });
      final ab = mergeSnapshots([a, b]);
      final ba = mergeSnapshots([b, a]);
      expect(ab.encodeJson(), ba.encodeJson());
      expect(mergeSnapshots([ab, a, b]).encodeJson(), ab.encodeJson());
      expect(mergeSnapshots([ab, ab]).encodeJson(), ab.encodeJson());
    });

    test('eliminazione: vale se più recente di ogni modifica', () {
      final row = SyncEntry(values: {'status': 'done'}, times: {'status': 5});
      final del = SyncEntry(deleted: 6);
      final dead = mergeSnapshots([
        snap({'t1': row}),
        snap({'t1': del}),
      ]).entry('topics', 't1')!;
      expect(dead.alive, isFalse);
      expect(dead.values, isEmpty);
      expect(dead.deleted, 6);
      // modificata dopo l'eliminazione: torna
      final edited = SyncEntry(
        values: {'status': 'review'},
        times: {'status': 9},
      );
      final back = mergeSnapshots([
        snap({'t1': dead}),
        snap({'t1': edited}),
      ]).entry('topics', 't1')!;
      expect(back.alive, isTrue);
      expect(back.values['status'], 'review');
    });

    test('registro gzip: si rilegge uguale; file estranei ignorati', () {
      final s = snap({
        't1': SyncEntry(values: {'n': 1, 's': 'x'}, times: {'n': 3, 's': 4}),
        't2': SyncEntry(deleted: 2),
      });
      final back = SyncSnapshot.decode(s.encode())!;
      expect(back.encodeJson(), s.encodeJson());
      expect(SyncSnapshot.decode([1, 2, 3]), isNull);
      expect(SyncSnapshot.decode('{"format":"altro"}'.codeUnits), isNull);
    });
  });

  group('due dispositivi', () {
    test(
      'sessioni di Studio sommate, collegate all\'argomento giusto',
      () async {
        final a = await _Device.create('A', tmp);
        final b = await _Device.create('B', tmp);
        await _catalog(a);
        await _catalog(b);
        // ordine diverso degli id locali su B
        await b.insert('courses', {'name': 'Mio corso', 'external_id': null});
        await a.insert('study_sessions', {
          'course_id': await a.courseId('polito:course:01ABC'),
          'topic_id': await a.topicId('Asintoti'),
          'start_at': '2026-10-20T09:00:00',
          'duration_minutes': 50,
        });
        await b.insert('study_sessions', {
          'course_id': await b.courseId('polito:course:01ABC'),
          'start_at': '2026-10-20T15:00:00',
          'duration_minutes': 30,
        });
        await _syncAll([a, b]);
        for (final d in [a, b]) {
          final total = (await d.q(
            'SELECT SUM(duration_minutes) AS m, COUNT(*) AS n FROM study_sessions',
          )).first;
          expect(total['m'], 80, reason: d.name);
          expect(total['n'], 2, reason: d.name);
          final s = (await d.q(
            "SELECT s.*, t.name AS topic FROM study_sessions s "
            "LEFT JOIN topics t ON t.id = s.topic_id WHERE s.duration_minutes = 50",
          )).first;
          expect(s['topic'], 'Asintoti', reason: d.name);
          expect(s['course_id'], await d.courseId('polito:course:01ABC'));
        }
        // il corso creato a mano arriva anche su A, gli argomenti del
        // catalogo non si duplicano
        expect(
          (await a.q(
            "SELECT COUNT(*) AS n FROM courses WHERE name = 'Mio corso'",
          )).first['n'],
          1,
        );
        for (final d in [a, b]) {
          expect((await d.q('SELECT COUNT(*) AS n FROM topics')).first['n'], 2);
          expect(
            (await d.q('SELECT COUNT(*) AS n FROM modules')).first['n'],
            1,
          );
        }
        await a.db.close();
        await b.db.close();
      },
    );

    test(
      'stato degli argomenti, esami e voti; vince la modifica più recente',
      () async {
        final a = await _Device.create('A', tmp);
        final b = await _Device.create('B', tmp);
        await _catalog(a);
        await _catalog(b);
        await _syncAll([a, b]);
        await a.db.db.update('topics', {
          'status': 'done',
          'theory_done': 1,
        }, where: "name = 'Asintoti'");
        await _later();
        await b.db.db.update('topics', {
          'status': 'review',
        }, where: "name = 'Asintoti'");
        await b.db.db.update('exams', {'status': 'passed', 'grade': 28});
        await _syncAll([a, b]);
        for (final d in [a, b]) {
          final t = (await d.q("SELECT * FROM topics WHERE name = 'Asintoti'"))
              .first;
          // colonne diverse: si tengono entrambe le modifiche
          expect(t['status'], 'review', reason: d.name);
          expect(t['theory_done'], 1, reason: d.name);
          final x = (await d.q('SELECT * FROM exams')).first;
          expect(x['grade'], 28, reason: d.name);
          expect(x['status'], 'passed', reason: d.name);
        }
        await a.db.close();
        await b.db.close();
      },
    );

    test('eliminazioni propagate; unione ripetuta non cambia nulla', () async {
      final a = await _Device.create('A', tmp);
      final b = await _Device.create('B', tmp);
      await _catalog(a);
      await a.insert('study_sessions', {
        'start_at': '2026-10-21T08:00:00',
        'duration_minutes': 25,
      });
      await _syncAll([a, b]);
      expect((await b.q('SELECT COUNT(*) AS n FROM topics')).first['n'], 2);
      await b.db.db.delete('topics', where: "name = 'Asintoti'");
      await b.db.db.delete('study_sessions');
      await _syncAll([a, b]);
      for (final d in [a, b]) {
        expect((await d.q('SELECT name FROM topics')).map((r) => r['name']), [
          'Limiti notevoli',
        ], reason: d.name);
        expect(
          (await d.q('SELECT COUNT(*) AS n FROM study_sessions')).first['n'],
          0,
        );
      }
      // idempotente: nessuna novità, registro invariato
      a.exchange([b]);
      final again = await a.merge();
      expect(again.applied, 0);
      expect(again.ownChanged, isFalse);
      await a.db.close();
      await b.db.close();
    });

    test('primo collegamento: i valori iniziali del dispositivo nuovo non '
        'sovrascrivono i dati già nel cloud', () async {
      final a = await _Device.create('A', tmp);
      await _catalog(a);
      await a.db.db.update('topics', {
        'status': 'done',
      }, where: "name = 'Asintoti'");
      await a.insert('app_settings', {
        'key': 'focus_daily_goal',
        'value': '120',
      });
      await a.merge();
      await _later();
      // B arriva dopo: stesso catalogo importato ora, impostazione iniziale
      final b = await _Device.create('B', tmp);
      await _catalog(b);
      await b.insert('app_settings', {
        'key': 'focus_daily_goal',
        'value': '60',
      });
      await b.insert('app_settings', {'key': 'theme_mode', 'value': 'light'});
      b.exchange([a]);
      final r = await b.merge();
      expect(r.firstJoin, isTrue);
      final t = (await b.q("SELECT status FROM topics WHERE name = 'Asintoti'"))
          .first;
      expect(t['status'], 'done');
      expect(
        (await b.q(
          "SELECT value FROM app_settings WHERE key = 'focus_daily_goal'",
        )).first['value'],
        '120',
      );
      // le impostazioni del dispositivo non viaggiano
      a.exchange([b]);
      await a.merge();
      expect(
        await a.q("SELECT * FROM app_settings WHERE key = 'theme_mode'"),
        isEmpty,
      );
      await a.db.close();
      await b.db.close();
    });

    test(
      'scritture contemporanee: ognuno il suo registro, stesso risultato',
      () async {
        final a = await _Device.create('A', tmp);
        final b = await _Device.create('B', tmp);
        await _catalog(a);
        await _catalog(b);
        await _syncAll([a, b]);
        // entrambi scrivono prima di vedere l'altro
        await a.insert('study_sessions', {
          'start_at': '2026-10-21T10:00:00',
          'duration_minutes': 40,
        });
        await b.insert('study_sessions', {
          'start_at': '2026-10-21T10:30:00',
          'duration_minutes': 20,
        });
        await a.merge();
        await b.merge();
        await _syncAll([a, b]);
        final ra = File(p.join(a.dati.path, a.own)).readAsBytesSync();
        final rb = File(p.join(b.dati.path, b.own)).readAsBytesSync();
        expect(SyncSnapshot.decode(ra)!.tables, isNot(isEmpty));
        // stessi dati nei due registri (a meno del nome del dispositivo)
        String tables(List<int> x) {
          final s = SyncSnapshot.decode(x)!;
          return SyncSnapshot(tables: s.tables).encodeJson();
        }

        expect(tables(ra), tables(rb));
        for (final d in [a, b]) {
          expect(
            (await d.q('SELECT SUM(duration_minutes) AS m FROM study_sessions'))
                .first['m'],
            60,
          );
        }
        await a.db.close();
        await b.db.close();
      },
    );

    test(
      'insegnamento personalizzato con modulo e allegato agli appunti',
      () async {
        final a = await _Device.create('A', tmp);
        final b = await _Device.create('B', tmp);
        final c = await a.insert('courses', {'name': 'Laboratorio'});
        final m = await a.insert('modules', {
          'course_id': c,
          'name': 'Arduino',
        });
        await a.insert('attachments', {
          'module_id': m,
          'title': 'lezione.md',
          'path': p.join(
            a.root.path,
            'appunti',
            'Laboratorio',
            'Riassunti',
            'l.md',
          ),
          'created_at': '2026-10-21T08:00:00',
        });
        await _syncAll([a, b]);
        final att = (await b.q(
          'SELECT a.path, m.name FROM attachments a '
          'JOIN modules m ON m.id = a.module_id',
        )).first;
        expect(att['name'], 'Arduino');
        expect(
          att['path'],
          p.join(b.root.path, 'appunti', 'Laboratorio', 'Riassunti', 'l.md'),
        );
        await a.db.close();
        await b.db.close();
      },
    );

    test('backup ripristinato: si unisce, non cancella sugli altri', () async {
      final a = await _Device.create('A', tmp);
      final b = await _Device.create('B', tmp);
      await _catalog(a);
      final backup = await BackupService(a.db).exportJson();
      await a.insert('study_sessions', {
        'start_at': '2026-10-21T11:00:00',
        'duration_minutes': 15,
      });
      await _syncAll([a, b]);
      // backup vecchio ripristinato su A: la sessione nuova resta ovunque
      await BackupService(a.db).importJson(backup);
      await _syncAll([a, b]);
      for (final d in [a, b]) {
        expect(
          (await d.q('SELECT COUNT(*) AS n FROM study_sessions')).first['n'],
          1,
          reason: d.name,
        );
        expect((await d.q('SELECT COUNT(*) AS n FROM topics')).first['n'], 2);
      }
      await a.db.close();
      await b.db.close();
    });

    test('dati eliminati sul dispositivo: si riprendono dal cloud', () async {
      final a = await _Device.create('A', tmp);
      await _catalog(a);
      await a.insert('study_sessions', {
        'start_at': '2026-10-21T12:00:00',
        'duration_minutes': 45,
      });
      await a.merge();
      // «Elimina dati»: righe e base via, il registro nel cloud resta
      await a.db.db.delete('study_sessions');
      await a.db.db.delete('courses');
      File(p.join(a.root.path, DataSync.baseName)).deleteSync();
      final r = await a.merge();
      expect(r.firstJoin, isTrue);
      expect(
        (await a.q('SELECT SUM(duration_minutes) AS m FROM study_sessions'))
            .first['m'],
        45,
      );
      expect((await a.q('SELECT COUNT(*) AS n FROM topics')).first['n'], 2);
      await a.db.close();
    });

    test(
      'anno di partenza ed esami «Da completare» degli anni precedenti',
      () async {
        final a = await _Device.create('A', tmp);
        final b = await _Device.create('B', tmp);
        await _catalog(a);
        await _catalog(b);
        await _syncAll([a, b]);
        // onboarding al 3° anno su A: anno di partenza ed esame da completare
        await a.insert('profile', {
          'id': 1,
          'university_id': 'polito',
          'university_name': 'PoliTo',
          'degree_id': 'polito-l8',
          'degree_name': 'Ingegneria Informatica',
          'degree_type': 'L',
          'duration_years': 3,
          'current_year': 3,
          'reference_aa': '2026/27',
          'start_year': 3,
        });
        await a.db.db.update('exams', {'status': 'to_complete'});
        await _syncAll([a, b]);
        expect(
          (await b.q('SELECT start_year FROM profile')).single['start_year'],
          3,
        );
        expect(
          (await b.q('SELECT status FROM exams')).single['status'],
          'to_complete',
        );
        // su B lo studente lo segna «Da sostenere»: arriva anche su A
        await _later();
        await b.db.db.update('exams', {'status': 'planned'});
        await _syncAll([a, b]);
        expect(
          (await a.q('SELECT status FROM exams')).single['status'],
          'planned',
        );
        await a.db.close();
        await b.db.close();
      },
    );
  });
}
