import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/router/error_screens.dart';
import 'package:university_notes/core/services/backup_service.dart';
import 'package:university_notes/core/services/error_log.dart';
import 'package:university_notes/repositories/calendar_repository.dart';
import 'package:university_notes/repositories/settings_repository.dart';
import 'package:university_notes/repositories/study_repository.dart';

/// Gestione globale degli errori, registro locale e dati inattesi nel
/// database (da un'altra versione dell'app, sincronizzazione, backup):
/// nessuna schermata rotta (CRASH-1).
void main() {
  setUpAll(sqfliteFfiInit);

  group('registro degli errori', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('uninotes_log_');
      ErrorLog.directory = () async => tmp;
      ErrorLog.resetForTest();
    });
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('annota errore, contesto e pila; lo stesso errore ripetuto subito '
        'una volta sola', () async {
      final at = DateTime(2026, 10, 22, 10);
      await ErrorLog.record(
        StateError('rotto'),
        StackTrace.current,
        context: 'Prova',
        now: at,
      );
      await ErrorLog.record(
        StateError('rotto'),
        null,
        context: 'Prova',
        now: at.add(const Duration(seconds: 1)),
      );
      final text = await ErrorLog.read();
      expect(text, contains('Prova'));
      expect(text, contains('Bad state: rotto'));
      expect('Bad state: rotto'.allMatches(text).length, 1);
      await ErrorLog.clear();
      expect(await ErrorLog.read(), isEmpty);
    });

    test('registro grande: passa alla copia precedente, non cresce senza '
        'limite', () async {
      final f = File('${tmp.path}/${ErrorLog.fileName}');
      f.writeAsStringSync('x' * (ErrorLog.maxBytes + 10));
      await ErrorLog.record(Exception('nuovo'), null);
      expect(f.lengthSync(), lessThan(1000));
      expect(File('${f.path}.1').existsSync(), isTrue);
    });

    test('cartella non disponibile: nessuna eccezione', () async {
      ErrorLog.directory = () async => throw const FileSystemException('no');
      await ErrorLog.record(Exception('x'), null);
      expect(await ErrorLog.read(), isEmpty);
    });

    test('spazio esaurito riconosciuto (Windows, Android, SQLite)', () {
      expect(
        isDiskFullError(const FileSystemException('w', 'p', OSError('', 112))),
        isTrue,
      );
      expect(
        isDiskFullError(const FileSystemException('w', 'p', OSError('', 28))),
        isTrue,
      );
      expect(
        isDiskFullError(const FileSystemException('w', 'p', OSError('', 5))),
        isFalse,
      );
    });
  });

  group('schermate di errore', () {
    testWidgets('widget che non si costruisce: messaggio comprensibile al '
        'posto della schermata rossa', (tester) async {
      final previous = ErrorWidget.builder;
      ErrorWidget.builder = (d) => AppErrorWidget(details: d);
      try {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: _Broken())),
        );
        expect(tester.takeException(), isA<StateError>());
        expect(find.text('Qualcosa non ha funzionato'), findsOneWidget);
      } finally {
        ErrorWidget.builder = previous;
      }
    });

    testWidgets('anche in uno spazio minuscolo o senza limiti', (tester) async {
      final previous = ErrorWidget.builder;
      ErrorWidget.builder = (d) => AppErrorWidget(details: d);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: const [
                  SizedBox(width: 10, height: 10, child: _Broken()),
                  _Broken(),
                ],
              ),
            ),
          ),
        );
        // le due eccezioni dei widget rotti, nessun'altra (overflow, layout)
        expect(tester.takeException(), isNotNull);
        expect(find.byType(AppErrorWidget), findsNWidgets(2));
      } finally {
        ErrorWidget.builder = previous;
      }
    });

    testWidgets('avvio non riuscito: spiegazione e «Riprova»', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        StartupErrorApp(
          error: const FileSystemException('w', 'p', OSError('', 112)),
          onRetry: () async => retried++,
        ),
      );
      expect(find.textContaining('spazio sul dispositivo'), findsOneWidget);
      await tester.tap(find.byKey(const Key('startup-retry')));
      await tester.pump();
      expect(retried, 1);
    });
  });

  group('valori inattesi nel database', () {
    late AppDatabase db;
    setUp(() async => db = await AppDatabase.openInMemory());
    tearDown(() => db.close());

    test(
      'impostazione salvata come dati binari: si legge come testo',
      () async {
        await db.db.insert('app_settings', {
          'key': 'theme_mode',
          'value': Uint8List.fromList([1, 2]),
        });
        final s = SettingsRepository(db);
        expect(await s.get('theme_mode'), isA<String>());
        expect((await s.allSettings())['theme_mode'], isA<String>());
      },
    );

    test('evento e prova con date non leggibili: saltati, il calendario '
        'resta', () async {
      await db.db.insert('events', {
        'type': 'event',
        'title': 'Rotto',
        'start_at': 'domani alle 10',
      });
      await db.db.insert('events', {
        'type': 'event',
        'title': 'Buono',
        'start_at': '2026-10-05T10:00:00',
      });
      final course = await db.db.insert('courses', {'name': 'Analisi'});
      await db.db.insert('exams', {'course_id': course, 'date': '2026-10-1x'});
      final repo = CalendarRepository(db);
      final events = await repo.eventsOfType(EventType.event);
      expect(events.map((e) => e.title), ['Buono']);
      final entries = await repo.entriesBetween(
        DateTime(2026, 10, 1),
        DateTime(2026, 10, 31),
      );
      expect(entries.map((e) => e.title), ['Buono']);
    });

    test('sessione di studio con l\'inizio non leggibile: saltata', () async {
      await db.db.insert('study_sessions', {
        'start_at': 'boh',
        'duration_minutes': 30,
      });
      await db.db.insert('study_sessions', {
        'start_at': '2026-10-05T10:00:00',
        'duration_minutes': 45,
      });
      final list = await StudyRepository(db).sessions();
      expect(list.single.durationMinutes, 45);
    });

    test('profilo con durata e anno fuori intervallo: valori validi', () {
      final p = StudentProfile.fromMap({
        'university_id': 'u',
        'university_name': 'U',
        'degree_id': 'd',
        'degree_name': 'D',
        'degree_type': 'L',
        'duration_years': 0,
        'current_year': 1 << 40,
        'reference_aa': '2026/27',
      });
      expect(p.durationYears, 3);
      expect(p.currentYear, lessThanOrEqualTo(30));
      expect(planYearsOf(p).length, lessThanOrEqualTo(30));
    });
  });

  group('catalogo con valori sbagliati', () {
    test('durata del corso 0 o enorme: profilo valido', () {
      for (final d in [0, -2, 1 << 40]) {
        final sel = PathSelection(
          ateneo: const Ateneo(id: 'a', nome: 'A', tipo: TipoAteneo.statale),
          tipo: TipoCorso.fromKey('L'),
          corso: CorsoIndice(
            ateneoId: 'a',
            id: 'c',
            nome: 'C',
            tipo: TipoCorso.fromKey('L'),
            durataAnni: d,
          ),
          year: 2,
        );
        final p = sel.toProfile(DateTime(2026, 10, 1));
        expect(p.durationYears, 3);
        expect(p.currentYear, 2);
      }
    });
  });

  group('ripristino', () {
    late AppDatabase db;
    setUp(() async => db = await AppDatabase.openInMemory());
    tearDown(() => db.close());

    test(
      'backup con righe incompatibili: errore chiaro e dati invariati',
      () async {
        await db.db.insert('courses', {'name': 'Mio'});
        final json = jsonEncode({
          'format': BackupService.format,
          'version': 1,
          'tables': {
            'courses': [
              {'id': 1, 'name': 'Dal backup'},
            ],
            // modulo di un insegnamento che non c'è
            'modules': [
              {'id': 1, 'course_id': 99, 'name': 'Orfano'},
            ],
          },
        });
        await expectLater(
          BackupService(db).importJson(json),
          throwsA(isA<BackupException>()),
        );
        expect((await db.db.query('courses')).single['name'], 'Mio');
      },
    );

    test('copia del database danneggiata: errore chiaro', () async {
      final tmp = Directory.systemTemp.createTempSync('uninotes_bk_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final f = File('${tmp.path}/copia.db')
        ..writeAsBytesSync(List.generate(8192, (i) => (i * 31) % 256));
      await expectLater(
        BackupService.jsonFromDatabaseFile(f.path),
        throwsA(isA<BackupException>()),
      );
    });
  });
}

class _Broken extends StatelessWidget {
  const _Broken();
  @override
  Widget build(BuildContext context) => throw StateError('rotto');
}
