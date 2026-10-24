import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/agenda.dart';
import 'package:university_notes/core/reminders/apple_calendar_backend.dart';
import 'package:university_notes/core/reminders/device_calendar_backend.dart';
import 'package:university_notes/core/reminders/outlook_calendar_backend.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/calendar_export.dart';
import 'package:university_notes/core/services/error_log.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/academic/year_grades_screen.dart';
import 'package:university_notes/features/cloud/data_sync.dart';
import 'package:university_notes/features/courses/course_detail_screen.dart';
import 'package:university_notes/features/courses/courses_screen.dart';
import 'package:university_notes/features/dashboard/dashboard_screen.dart';
import 'package:university_notes/features/exams/exam_detail.dart';
import 'package:university_notes/features/exams/exam_form.dart';
import 'package:university_notes/features/exams/exam_status.dart';
import 'package:university_notes/features/exams/exam_ui.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/features/exams/previous_years_screen.dart';
import 'package:university_notes/features/reader/parsers/ooxml.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/utils/grade_math.dart';

/// Terzo giro della caccia ai crash, «resti» dei giri precedenti: fuso orario
/// del .ics e dei calendari, date al limite di `DateTime`, righe di
/// sincronizzazione con tipi sbagliati, voti fuori 18–30 dopo la
/// trasformazione di una prova in itinere, «Annulla» dell'archiviazione di
/// un insegnamento a scelta, numeri seriali di Excel enormi.

/// Agenda con una prova alla data [date] e all'ora [time] (null = giornata
/// intera).
AgendaItem _item(DateTime date, {String? time}) => AgendaItem(
  key: 'esame-1',
  kind: AgendaKind.exam,
  title: 'Esame: Analisi',
  subject: 'Analisi',
  date: date,
  time: time,
  examId: 1,
);

Future<AppServices> _empty() async {
  final db = await AppDatabase.openInMemory();
  for (final t in ['courses', 'exams', 'modules', 'topics', 'events']) {
    await db.db.delete(t);
  }
  return AppServices(db);
}

Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
}

Future<void> _pump(WidgetTester tester, AppServices s, Widget home) async {
  await tester.pumpWidget(
    Provider<AppServices>.value(
      value: s,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('it', 'IT'),
        supportedLocales: const [Locale('it', 'IT')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    ),
  );
  await _settle(tester);
}

/// Gli overflow di layout sono un difetto d'aspetto, non un crash.
void Function(FlutterErrorDetails)? _previous;

void _collect() {
  final previous = _previous = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.toString().contains('overflowed by')) return;
    previous?.call(d);
  };
}

void _release() => FlutterError.onError = _previous;

void _noCrash(WidgetTester tester, String reason) {
  final e = tester.takeException();
  if (e != null) {
    fail('$reason: ${e is FlutterError ? e.toStringDeep() : e}');
  }
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  group('1. fuso orario delle prove (.ics, calendario del telefono, Outlook)', () {
    test('ora italiana → istante UTC: inverno, estate e cambi d\'ora', () {
      DateTime? r(int y, int mo, int d, int h, [int mi = 0]) =>
          romeWallToUtc(DateTime(y, mo, d, h, mi));
      // inverno UTC+1, estate UTC+2
      expect(r(2027, 1, 20, 9, 30), DateTime.utc(2027, 1, 20, 8, 30));
      expect(r(2027, 7, 15, 9, 30), DateTime.utc(2027, 7, 15, 7, 30));
      // domenica 28/3/2027: dalle 02:00 alle 03:00 l'ora non esiste
      expect(r(2027, 3, 28, 1, 59), DateTime.utc(2027, 3, 28, 0, 59));
      expect(r(2027, 3, 28, 2, 30), DateTime.utc(2027, 3, 28, 1, 30));
      expect(r(2027, 3, 28, 3), DateTime.utc(2027, 3, 28, 1));
      // domenica 31/10/2027: le 02:30 ci sono due volte (vale la prima)
      expect(r(2027, 10, 31, 2, 30), DateTime.utc(2027, 10, 31, 0, 30));
      expect(r(2027, 10, 31, 3), DateTime.utc(2027, 10, 31, 2));
      expect(r(2027, 10, 30, 23), DateTime.utc(2027, 10, 30, 21));
      // il fuso del DateTime passato non conta: contano le cifre
      expect(
        romeWallToUtc(DateTime.utc(2027, 7, 15, 9, 30)),
        DateTime.utc(2027, 7, 15, 7, 30),
      );
    });

    test('AgendaItem: istanti uguali per ogni fuso, giorno intero invariato', () {
      final summer = _item(DateTime(2027, 7, 15), time: '09:30');
      expect(summer.startInstant, DateTime.utc(2027, 7, 15, 7, 30));
      expect(summer.endInstant, DateTime.utc(2027, 7, 15, 9, 30));
      final winter = _item(DateTime(2027, 2, 10), time: '09:00');
      expect(winter.startInstant, DateTime.utc(2027, 2, 10, 8));
      final all = _item(DateTime(2027, 2, 10));
      expect(all.dayStartUtc, DateTime.utc(2027, 2, 10));
      expect(all.dayEndUtc, DateTime.utc(2027, 2, 11));
    });

    test('Android, Apple e Outlook scrivono lo stesso istante', () {
      final item = _item(DateTime(2027, 7, 15), time: '09:30');
      final instant = DateTime.utc(2027, 7, 15, 7, 30);
      final a = AndroidCalendarBackend.eventArgs('1', item, const []);
      final i = AppleCalendarBackend.eventArgs('1', item, const []);
      expect(a['startMs'], instant.millisecondsSinceEpoch);
      expect(i['startMs'], instant.millisecondsSinceEpoch);
      expect(a['endMs'], instant.add(const Duration(hours: 2)).millisecondsSinceEpoch);
      expect(i['endMs'], a['endMs']);
      final o = OutlookCalendarBackend.eventJson(item, const []);
      expect((o['start'] as Map)['dateTime'], '2027-07-15T07:30:00');
      expect((o['start'] as Map)['timeZone'], 'UTC');
      expect((o['end'] as Map)['dateTime'], '2027-07-15T09:30:00');
    });

    test('.ics: cifre della prova con TZID=Europe/Rome e VTIMEZONE; la fine '
        'si calcola sulle cifre (anche a cavallo della mezzanotte)', () {
      final ics = buildIcs([
        (
          exam: Exam(
            id: 1,
            courseId: 1,
            date: DateTime(2027, 7, 15),
            time: '23:30',
          ),
          course: 'Analisi',
        ),
      ], now: DateTime.utc(2026, 10, 22));
      expect(ics, contains('DTSTART;TZID=Europe/Rome:20270715T233000'));
      expect(ics, contains('DTEND;TZID=Europe/Rome:20270716T013000'));
      expect(ics, contains('BEGIN:VTIMEZONE\r\nTZID:Europe/Rome'));
      // regole dell'ora legale europea nel VTIMEZONE
      expect(ics, contains('RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU'));
      expect(ics, contains('RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU'));
    });
  });

  group('2. date al limite di DateTime (anno 275760)', () {
    final last = DateTime(275760, 9, 13);

    test('AgendaItem: inizio, fine e istanti non lanciano', () {
      final timed = _item(last, time: '10:00');
      expect(() => timed.start, returnsNormally);
      expect(() => timed.end, returnsNormally);
      expect(() => timed.startInstant, returnsNormally);
      expect(() => timed.endInstant, returnsNormally);
      expect(timed.end.isBefore(timed.start), isFalse);
      final all = _item(last);
      expect(() => all.end, returnsNormally);
      expect(() => all.dayStartUtc, returnsNormally);
      expect(() => all.dayEndUtc, returnsNormally);
      expect(all.dayEndUtc.isBefore(all.dayStartUtc), isFalse);
    });

    test('calendari e file .ics con quella data non lanciano', () {
      for (final time in <String?>['10:00', null]) {
        final item = _item(last, time: time);
        expect(
          () => AndroidCalendarBackend.eventArgs('1', item, const []),
          returnsNormally,
        );
        expect(
          () => AppleCalendarBackend.eventArgs('1', item, const []),
          returnsNormally,
        );
        expect(
          () => OutlookCalendarBackend.eventJson(item, const [60]),
          returnsNormally,
        );
        expect(
          () => buildIcs([
            (
              exam: Exam(id: 1, courseId: 1, date: last, time: time),
              course: 'A',
            ),
          ]),
          returnsNormally,
        );
      }
    });

    test('Exam.dateTime con quella data e un\'ora non lancia', () {
      final e = Exam(courseId: 1, date: last, time: '10:00');
      expect(() => e.dateTime, returnsNormally);
    });
  });

  group('3. sincronizzazione con tipi sbagliati nel database locale', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('uninotes_r3_sync_');
      ErrorLog.directory = () async => tmp;
      ErrorLog.resetForTest();
    });
    tearDown(() {
      ErrorLog.resetForTest();
      tmp.deleteSync(recursive: true);
    });

    test('sync_mtime e place_id scritti come testo: si salta la riga, le '
        'altre si uniscono e l\'errore resta nel registro', () async {
      final db = await AppDatabase.open(path: p.join(tmp.path, 'c.sqlite'));
      addTearDown(db.close);
      final c = await db.db.insert('courses', {'name': 'Analisi'});
      await db.db.insert('exams', {'course_id': c, 'title': 'buono'});
      await db.db.insert('exams', {'course_id': c, 'title': 'rotto'});
      await db.db.insert('events', {
        'type': 'lesson',
        'title': 'buono',
        'start_at': '2027-01-10T09:00:00',
      });
      await db.db.insert('events', {
        'type': 'lesson',
        'title': 'rotto',
        'start_at': '2027-01-11T09:00:00',
      });
      // valori di un'altra versione o scritti a mano: SQLite li accetta
      await db.db.execute(
        "UPDATE exams SET sync_mtime = 'ieri' WHERE title = 'rotto'",
      );
      await db.db.execute(
        "UPDATE events SET place_id = 'aula-7' WHERE title = 'rotto'",
      );
      final dati = Directory(p.join(tmp.path, 'dati'))..createSync();
      final sync = DataSync(db, stateDir: () async => tmp);
      final own = DataSync.ownFileName('A', 'A');
      final r = await sync.mergeFolder(
        dati,
        ownName: own,
        device: 'A',
        installId: 'A',
      );
      expect(r.ownChanged, isTrue);
      final snap = SyncSnapshot.decode(
        File(p.join(dati.path, own)).readAsBytesSync(),
      )!;
      String? titleOf(String table, String title) {
        for (final e in snap.tables[table]!.values) {
          if (e.values['title'] == title) return title;
        }
        return null;
      }

      expect(titleOf('exams', 'buono'), 'buono');
      expect(titleOf('exams', 'rotto'), isNull);
      expect(titleOf('events', 'buono'), 'buono');
      expect(titleOf('events', 'rotto'), isNull);
      // le righe rotte restano nel database (nessun dato perso)
      expect(await db.db.query('exams'), hasLength(2));
      expect(await db.db.query('events'), hasLength(2));
      final log = await ErrorLog.read();
      expect(log, contains('Sincronizzazione'));
      expect(log, contains('saltata'));
    });
  });

  group('4. voti fuori 18-30 (prova in itinere diventata esame finale)', () {
    test('medie con punteggi qualsiasi: nessuna eccezione, numeri finiti', () {
      final courses = {
        1: const Course(id: 1, name: 'A', cfu: 6),
        2: const Course(id: 2, name: 'B', cfu: 9),
      };
      for (final g in [-3, 0, 5, 17, 31, 99999, 9223372036854775807]) {
        final exams = [
          Exam(
            id: 1,
            courseId: 1,
            status: ExamStatus.passed,
            grade: g,
          ),
          Exam(
            id: 2,
            courseId: 2,
            status: ExamStatus.passed,
            grade: 28,
          ),
          Exam(
            id: 3,
            courseId: 2,
            kind: ExamKind.midterm,
            status: ExamStatus.passed,
            grade: g,
          ),
        ];
        final r = weightedAverage(exams, courses);
        expect(r.weightedAverage!.isFinite, isTrue, reason: '$g');
        expect(r.arithmeticAverage!.isFinite, isTrue, reason: '$g');
        expect(r.graduationBase!.isFinite, isTrue, reason: '$g');
        expect(midtermAverage(exams)!.isFinite, isTrue, reason: '$g');
        expect(gradeLabel(exams.first), '$g');
        expect(shortGradeLabel(exams.first), '$g');
      }
    });

    test('esito del menù «Voto» con un voto fuori scala: una voce che esiste',
        () {
      for (final g in [-3, 0, 5, 17, 31, 99999]) {
        final code = outcomeCode(ExamStatus.passed, g);
        expect(kOutcomeCodes, contains(code), reason: '$g');
      }
    });

    testWidgets('dettaglio: «Cambia tipo» da prova in itinere (punteggio 5) '
        'a esame finale e tutte le schermate di medie e voti', (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      _collect();
      addTearDown(_release);
      final s = (await tester.runAsync(_empty))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final a = (await tester.runAsync(
        () => s.courses.insert(
          const Course(name: 'Fisica', year: 1, semester: '1', cfu: 6),
        ),
      ))!;
      final b = (await tester.runAsync(
        () => s.courses.insert(
          const Course(name: 'Chimica', year: 1, semester: '1', cfu: 9),
        ),
      ))!;
      final mid = (await tester.runAsync(
        () => s.exams.save(
          Exam(
            courseId: a,
            kind: ExamKind.midterm,
            status: ExamStatus.passed,
            grade: 5,
          ),
        ),
      ))!;
      await tester.runAsync(
        () => s.exams.save(
          Exam(
            courseId: b,
            status: ExamStatus.passed,
            grade: 28,
            date: DateTime(2027, 1, 20),
          ),
        ),
      );
      await _pump(tester, s, ExamDetailScreen(examId: mid));
      _noCrash(tester, 'dettaglio della prova in itinere');
      await tester.tap(find.byType(ExamKindChip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Esame finale').last);
      await _settle(tester, 10);
      _noCrash(tester, 'dopo «Cambia tipo»');
      final converted = (await tester.runAsync(() => s.exams.byId(mid)))!;
      // comportamento attuale (da decidere): il punteggio diventa il voto
      expect(converted.kind, ExamKind.finalExam);
      expect(converted.status, ExamStatus.passed);
      expect(converted.grade, 5);

      final all = (await tester.runAsync(s.exams.all))!;
      final r = weightedAverage(all, {
        for (final c in (await tester.runAsync(s.courses.all))!) c.id!: c,
      });
      expect(r.count, 2);
      expect(r.arithmeticAverage, closeTo(16.5, 1e-9));

      for (final screen in <Widget>[
        ExamDetailScreen(examId: mid),
        ExamFormPage(exam: converted),
        const ExamsScreen(),
        const YearGradesScreen(year: 1),
        const PreviousYearsScreen(),
        const CoursesScreen(),
        CourseDetailScreen(courseId: a),
        const DashboardScreen(),
      ]) {
        await _pump(tester, s, const SizedBox());
        await _pump(tester, s, screen);
        _noCrash(tester, '$screen');
      }
      // schede di Esami: Sostenuti, Medie
      await _pump(tester, s, const SizedBox());
      await _pump(tester, s, const ExamsScreen());
      for (final tab in ['Sostenuti', 'Medie', 'Da sostenere']) {
        final f = find.text(tab);
        if (f.evaluate().isEmpty) continue;
        await tester.ensureVisible(f.first);
        await tester.tap(f.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _settle(tester);
        _noCrash(tester, 'Esami / $tab');
      }
    });

    for (final g in [-3, 0, 17, 31, 99999]) {
      testWidgets('menù «Voto» e modulo con un voto salvato di $g', (
        tester,
      ) async {
        _collect();
        addTearDown(_release);
        final s = (await tester.runAsync(_empty))!;
        addTearDown(() => tester.runAsync(s.database.close));
        final c = (await tester.runAsync(
          () => s.courses.insert(const Course(name: 'Fisica', cfu: 6)),
        ))!;
        final id = (await tester.runAsync(
          () => s.exams.save(
            Exam(courseId: c, status: ExamStatus.passed, grade: g),
          ),
        ))!;
        final exam = (await tester.runAsync(() => s.exams.byId(id)))!;
        await _pump(
          tester,
          s,
          Scaffold(
            body: GradeDialog(
              midterm: false,
              status: ExamStatus.passed,
              grade: g,
            ),
          ),
        );
        _noCrash(tester, 'GradeDialog finale con $g');
        await _pump(
          tester,
          s,
          Scaffold(
            body: GradeDialog(
              midterm: true,
              status: ExamStatus.passed,
              grade: g,
            ),
          ),
        );
        _noCrash(tester, 'GradeDialog prova con $g');
        await _pump(tester, s, ExamFormPage(exam: exam));
        _noCrash(tester, 'ExamFormPage con $g');
        await _pump(tester, s, YearGradesScreen(year: 1));
        _noCrash(tester, 'YearGradesScreen con $g');
      });
    }
  });

  group('5. «Annulla» dell\'archiviazione di un insegnamento a scelta', () {
    for (final status in [
      CourseStatus.toTake,
      CourseStatus.active,
      CourseStatus.toComplete,
    ]) {
      testWidgets('elimino l\'ultima prova in itinere di un insegnamento '
          '${status.key} e premo «Annulla»: torna com\'era', (tester) async {
        tester.view.physicalSize = const Size(900, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        _collect();
        addTearDown(_release);
        final s = (await tester.runAsync(_empty))!;
        addTearDown(() => tester.runAsync(s.database.close));
        final c = (await tester.runAsync(
          () => s.courses.insert(
            Course(name: 'Robotica', mandatory: false, status: status),
          ),
        ))!;
        final id = (await tester.runAsync(
          () => s.exams.save(Exam(courseId: c, kind: ExamKind.midterm)),
        ))!;
        final exam = (await tester.runAsync(() => s.exams.byId(id)))!;
        late BuildContext ctx;
        await _pump(
          tester,
          s,
          Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return TextButton(
                  onPressed: () => deleteExamWithConfirm(ctx, exam),
                  child: const Text('Elimina prova'),
                );
              },
            ),
          ),
        );
        await tester.tap(find.text('Elimina prova'));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('exam-delete-confirm')));
        await _settle(tester, 10);
        _noCrash(tester, 'eliminazione');
        // archiviato (comportamento invariato)
        final dropped = (await tester.runAsync(() => s.courses.byId(c)))!;
        expect(dropped.status, CourseStatus.archived);
        // l'avviso entra con un'animazione
        await tester.pump(const Duration(milliseconds: 600));
        final undo = find.widgetWithText(SnackBarAction, 'Annulla');
        expect(undo, findsOneWidget);
        await tester.tap(undo);
        await _settle(tester, 10);
        _noCrash(tester, 'Annulla');
        final back = (await tester.runAsync(() => s.courses.byId(c)))!;
        expect(back.status, status);
        expect(await tester.runAsync(() => s.exams.byCourse(c)), hasLength(1));
      });
    }
  });

  group('6. excelDate con numeri seriali enormi, negativi o non finiti', () {
    test('nessuna eccezione, nessuna data impossibile', () {
      for (final v in <double>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
        1e300,
        -1e300,
        1e18,
        -1e18,
        -1,
        -0.5,
        2958466,
        9223372036854775807.0,
      ]) {
        for (final time in [false, true]) {
          late String text;
          expect(() => text = excelDate(v, time: time), returnsNormally,
              reason: '$v');
          // non una data con l'anno oltre il 9999 o negativo
          expect(text, isNot(matches(RegExp(r'^\d\d/\d\d/(\d{5,}|-)'))),
              reason: '$v');
        }
      }
    });

    test('date vere: primo e ultimo giorno rappresentabili in Excel', () {
      expect(excelDate(45200), '01/10/2023');
      expect(excelDate(0), '30/12/1899');
      expect(excelDate(2958465), '31/12/9999');
      expect(excelDate(45200.75, time: true), '01/10/2023 18:00');
      expect(excelDate(0.5, time: true), '12:00');
    });
  });
}
