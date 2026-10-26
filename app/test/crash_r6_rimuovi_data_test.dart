import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/agenda.dart';
import 'package:university_notes/core/reminders/apple_calendar_backend.dart';
import 'package:university_notes/core/reminders/device_calendar_backend.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/reminders/outlook_calendar_backend.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/reminders/system_calendar.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/calendar_export.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/exams/exam_detail.dart';
import 'package:university_notes/features/exams/exam_form.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';

import 'support/fake_reminders.dart';

/// «Rimuovi data» e «Rimuovi orario» (26/10/2026): la data tolta toglie
/// anche l'orario, l'evento del calendario e i promemoria; l'orario tolto
/// rende la prova (e l'evento) di tutto il giorno, uguale a quello che l'app
/// crea per una prova senza orario. Nel modulo e nel dettaglio, con
/// «Annulla» nel dettaglio.
void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  group('modello', () {
    const base = Exam(
      id: 4,
      courseId: 1,
      kind: ExamKind.midterm,
      title: 'Esonero 1',
      time: '09:30',
      location: 'Aula 2',
      status: ExamStatus.booked,
    );
    final timed = base.copyWith(date: DateTime(2099, 2, 10));

    test('senza data: via anche l\'orario, il resto resta (anche lo stato '
        '«Prenotato» e il tipo)', () {
      final e = timed.withoutDate();
      expect(e.date, isNull);
      expect(e.time, isNull);
      expect(e.dateTime, isNull);
      expect(e.status, ExamStatus.booked);
      expect(e.kind, ExamKind.midterm);
      expect(e.title, 'Esonero 1');
      expect(e.location, 'Aula 2');
      expect(e.id, 4);
    });

    test('senza orario: stessa data, giornata intera', () {
      final e = timed.withoutTime();
      expect(e.date, DateTime(2099, 2, 10));
      expect(e.time, isNull);
      expect(e.dateTime, DateTime(2099, 2, 10));
      expect(e.status, ExamStatus.booked);
      expect(e.kind, ExamKind.midterm);
      // copyWith senza clearTime non tocca l'orario
      expect(timed.copyWith(location: 'Aula 3').time, '09:30');
    });

    test('una prova sostenuta tiene voto e stato senza data', () {
      final e = Exam(
        courseId: 1,
        date: DateTime(2026, 1, 20),
        time: '10:00',
        status: ExamStatus.passed,
        grade: 28,
      ).withoutDate();
      expect(e.date, isNull);
      expect(e.status, ExamStatus.passed);
      expect(e.grade, 28);
    });
  });

  group('calendario: stesso evento di una prova creata senza orario', () {
    final timed = examItem(7, DateTime(2099, 2, 10), time: '09:30');
    final allDay = examItem(7, DateTime(2099, 2, 10));
    final minutes = calendarReminderMinutes(
      allDay,
      kDefaultExamOffsets,
      kDefaultExamHours,
    );

    test('promemoria della variante senza orario', () {
      expect(
        calendarReminderMinutes(timed, kDefaultExamOffsets, kDefaultExamHours),
        [1440, 60],
      );
      expect(minutes, [900]);
    });

    test('Android: aggiornamento con allDay, mezzanotte UTC, nessun fuso '
        'dell\'ora', () {
      final update = AndroidCalendarBackend.eventArgs(
        '3',
        allDay,
        minutes,
        eventId: '55',
      );
      final create = AndroidCalendarBackend.eventArgs('3', allDay, minutes);
      expect(update['allDay'], isTrue);
      expect(update['eventId'], '55');
      expect({...update}..remove('eventId'), create);
      expect(
        update['startMs'],
        DateTime.utc(2099, 2, 10).millisecondsSinceEpoch,
      );
      expect(update['endMs'], DateTime.utc(2099, 2, 11).millisecondsSinceEpoch);
    });

    test('iPhone, iPad e Mac: EventKit con isAllDay e mezzanotte locale', () {
      final update = AppleCalendarBackend.eventArgs(
        'c',
        allDay,
        minutes,
        eventId: 'E1',
      );
      final create = AppleCalendarBackend.eventArgs('c', allDay, minutes);
      expect(update['allDay'], isTrue);
      expect({...update}..remove('eventId'), create);
      expect(update['startMs'], DateTime(2099, 2, 10).millisecondsSinceEpoch);
    });

    test('Outlook: stesso corpo (PATCH) con isAllDay e un promemoria', () {
      final json = OutlookCalendarBackend.eventJson(allDay, minutes);
      expect(json['isAllDay'], isTrue);
      expect(json['start'], {
        'dateTime': '2099-02-10T00:00:00',
        'timeZone': 'UTC',
      });
      expect(json['end'], {
        'dateTime': '2099-02-11T00:00:00',
        'timeZone': 'UTC',
      });
      expect(json['reminderMinutesBeforeStart'], 900);
      expect(
        OutlookCalendarBackend.eventJson(timed, [1440, 60])['isAllDay'],
        isFalse,
      );
    });

    test('.ics: data tolta → stesso UID annullato, senza promemoria', () {
      final exam = Exam(
        id: 7,
        courseId: 1,
        date: DateTime(2099, 2, 10),
        time: '09:30',
      );
      final ics = buildIcs([(exam: exam, course: 'Analisi I')], cancel: true);
      expect(ics, contains('METHOD:CANCEL'));
      expect(ics, contains('STATUS:CANCELLED'));
      expect(ics, contains('UID:university-notes-exam-7@universitynotes'));
      expect(ics, isNot(contains('BEGIN:VALARM')));
      // orario tolto: l'esportazione aggiorna l'evento a giornata intera
      final day = buildIcs([(exam: exam.withoutTime(), course: 'Analisi I')]);
      expect(day, contains('DTSTART;VALUE=DATE:20990210'));
      expect(day, isNot(contains('METHOD:CANCEL')));
    });
  });

  group('servizio dei promemoria (calendario e notifiche finti)', () {
    late AppServices s;
    late FakeCalendarBackend backend;
    late FakeNotificationPlatform notifications;
    late int examId;
    final now = DateTime(2099, 2, 1, 10);

    setUp(() async {
      final db = await AppDatabase.openInMemory();
      for (final t in ['courses', 'exams', 'modules', 'topics', 'events']) {
        await db.db.delete(t);
      }
      backend = FakeCalendarBackend();
      notifications = FakeNotificationPlatform();
      s = AppServices(
        db,
        reminders: (s) => RemindersService(
          s,
          platform: notifications,
          calendarBackend: backend,
          widgets: FakeHomeWidgets(),
          platformName: 'android',
          isRecording: () => false,
          isForeground: () => false,
        ),
      );
      await s.settings.set(NotificationKeys.consent, '1');
      final c = await s.courses.insert(const Course(name: 'Analisi I'));
      examId = await s.exams.insert(
        Exam(
          courseId: c,
          date: DateTime(2099, 2, 10),
          time: '09:30',
          status: ExamStatus.booked,
        ),
      );
    });
    tearDown(() => s.database.close());

    Future<Exam> exam() async => (await s.exams.byId(examId))!;

    List<PlannedNotification> examNotifications() =>
        ofType(notifications.scheduled.values, NotificationType.exam);

    test('rimuovi orario: lo stesso evento diventa di tutto il giorno, con i '
        'promemoria senza orario', () async {
      await s.settings.set(CalendarKeys.enabled, '1');
      await s.reminders.refresh(now: now);
      expect(backend.events, hasLength(1));
      final id = backend.events.keys.single;
      expect(backend.events[id]!.item.allDay, isFalse);
      expect(backend.events[id]!.reminders, [1440, 60]);

      await s.exams.update((await exam()).withoutTime());
      await s.reminders.refresh(now: now);
      expect(backend.events.keys, [id], reason: 'aggiornato, non ricreato');
      final ev = backend.events[id]!.item;
      expect(ev.allDay, isTrue);
      expect(ev.date, DateTime(2099, 2, 10));
      expect(backend.events[id]!.reminders, [900]);
      // calendario funzionante: nessuna notifica doppia dell'app
      expect(examNotifications(), isEmpty);
    });

    test('rimuovi data: evento tolto, nessun orfano; «Annulla» lo riscrive '
        'una volta sola', () async {
      await s.settings.set(CalendarKeys.enabled, '1');
      await s.reminders.refresh(now: now);
      expect(backend.events, hasLength(1));
      final before = await exam();

      await s.exams.update(before.withoutDate());
      await s.reminders.refresh(now: now);
      expect(backend.events, isEmpty);
      expect((await s.reminders.calendar.status()).written, isEmpty);

      await restoreExamWhen(s, before);
      await s.reminders.refresh(now: now);
      expect(backend.events, hasLength(1));
      final ev = backend.events.values.single;
      expect(ev.item.time, '09:30');
      expect(ev.key, examAgendaKey(examId));
      expect((await exam()).status, ExamStatus.booked);
    });

    test('calendario interno: le notifiche passano alla regola senza orario e '
        'spariscono con la data', () async {
      await s.reminders.refresh(now: now);
      expect(examNotifications().map((n) => n.at).toList()..sort(), [
        DateTime(2099, 2, 9, 9, 30),
        DateTime(2099, 2, 10, 8, 30),
      ]);

      await s.exams.update((await exam()).withoutTime());
      await s.reminders.refresh(now: now);
      expect(examNotifications().map((n) => n.at), [DateTime(2099, 2, 9, 9)]);

      final cancelledBefore = notifications.cancelled.length;
      await s.exams.update((await exam()).withoutDate());
      await s.reminders.refresh(now: now);
      expect(examNotifications(), isEmpty);
      expect(notifications.cancelled.length, greaterThan(cancelledBefore));
      // nemmeno «Com'è andata?» per una prova senza data
      expect(
        ofType(notifications.scheduled.values, NotificationType.outcome),
        isEmpty,
      );
    });

    test('un altro dispositivo scrive il calendario: qui non si tocca, lo '
        'toglie lui alla sua sincronizzazione', () async {
      await s.settings.set(CalendarKeys.enabled, '1');
      await s.reminders.refresh(now: now);
      expect(backend.events, hasLength(1));
      // il posto passa al telefono (segno recente di un'altra installazione)
      const key = 'device:studente@gmail.com';
      await s.settings.set(
        CalendarKeys.writers,
        jsonEncode({
          key: {
            'install': 'telefono-1',
            'device': 'telefono telefono-1',
            'at': now.toUtc().toIso8601String(),
          },
        }),
      );
      await s.exams.update((await exam()).withoutDate());
      await s.reminders.refresh(now: now);
      expect(backend.events, hasLength(1), reason: 'qui si legge soltanto');
      expect((await s.reminders.calendar.status()).writtenBy, isNotNull);

      // il telefono, con i dati sincronizzati, allinea il calendario
      final phone = SystemCalendarSync(
        s.settings,
        backend,
        device: CalendarDevice(
          installId: () async => 'telefono-1',
          name: 'telefono',
        ),
      );
      final agenda = (await s.reminders.loadAgenda(now)).agenda;
      await phone.sync(agenda, kDefaultExamOffsets, now: now);
      expect(backend.events, isEmpty);
    });
  });

  group('interfaccia', () {
    Future<AppServices> empty() async {
      final db = await AppDatabase.openInMemory();
      for (final t in ['courses', 'exams', 'modules', 'topics', 'events']) {
        await db.db.delete(t);
      }
      return AppServices(db);
    }

    Future<void> settle(WidgetTester tester, [int n = 6]) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump();
      }
    }

    Future<void> pump(
      WidgetTester tester,
      AppServices s,
      Widget home, {
      double scale = 1,
    }) async {
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
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: home,
          ),
        ),
      );
      await settle(tester);
    }

    Future<(AppServices, int)> withExam(
      WidgetTester tester, {
      DateTime? date,
      String? time,
      ExamKind kind = ExamKind.finalExam,
      ExamStatus status = ExamStatus.planned,
    }) async {
      final s = (await tester.runAsync(empty))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final c = (await tester.runAsync(
        () => s.courses.insert(const Course(name: 'Fisica', cfu: 6)),
      ))!;
      final id = (await tester.runAsync(
        () => s.exams.save(
          Exam(courseId: c, kind: kind, date: date, time: time, status: status),
        ),
      ))!;
      return (s, id);
    }

    void size(WidgetTester tester, double w, double h) {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('dettaglio senza data: nessuna «x»', (tester) async {
      size(tester, 900, 1400);
      final (s, id) = await withExam(tester);
      await pump(tester, s, ExamDetailScreen(examId: id));
      expect(find.byKey(const Key('detail-remove-when')), findsNothing);
    });

    testWidgets('dettaglio con data e orario: «Rimuovi orario» e «Annulla»', (
      tester,
    ) async {
      size(tester, 900, 1400);
      final (s, id) = await withExam(
        tester,
        date: DateTime(2099, 2, 10),
        time: '09:30',
        status: ExamStatus.booked,
      );
      await pump(tester, s, ExamDetailScreen(examId: id));
      expect(find.byTooltip('Rimuovi data o orario'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail-remove-when')));
      await tester.pumpAndSettle();
      // due sole scelte nel foglio
      expect(find.byKey(const Key('when-remove-time')), findsOneWidget);
      expect(find.byKey(const Key('when-remove-date')), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('when-remove-time')));
      await settle(tester);
      var e = (await tester.runAsync(() => s.exams.byId(id)))!;
      expect(e.date, DateTime(2099, 2, 10));
      expect(e.time, isNull);
      expect(e.status, ExamStatus.booked);
      expect(
        find.text('Orario tolto: la prova è di tutto il giorno'),
        findsOneWidget,
      );
      // senza orario la «x» toglie direttamente la data
      expect(find.byTooltip('Rimuovi data'), findsOneWidget);

      // l'avviso finisce di entrare prima del tocco
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Annulla'));
      await settle(tester);
      e = (await tester.runAsync<Exam?>(() => s.exams.byId(id)))!;
      expect(e.time, '09:30');
      expect(find.byTooltip('Rimuovi data o orario'), findsOneWidget);
    });

    testWidgets('dettaglio: «Rimuovi data» toglie data e orario, «Annulla» li '
        'rimette; il tipo resta', (tester) async {
      size(tester, 900, 1400);
      final (s, id) = await withExam(
        tester,
        date: DateTime(2099, 2, 10),
        time: '09:30',
        kind: ExamKind.midterm,
      );
      await pump(tester, s, ExamDetailScreen(examId: id));
      await tester.tap(find.byKey(const Key('detail-remove-when')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('when-remove-date')));
      await settle(tester);
      var e = (await tester.runAsync(() => s.exams.byId(id)))!;
      expect(e.date, isNull);
      expect(e.time, isNull);
      expect(e.kind, ExamKind.midterm);
      expect(e.status, ExamStatus.planned);
      expect(find.text('Data da aggiungere'), findsOneWidget);
      expect(find.byKey(const Key('detail-remove-when')), findsNothing);

      // l'avviso finisce di entrare prima del tocco
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Annulla'));
      await settle(tester);
      e = (await tester.runAsync<Exam?>(() => s.exams.byId(id)))!;
      expect(e.date, DateTime(2099, 2, 10));
      expect(e.time, '09:30');
      expect(e.kind, ExamKind.midterm);
    });

    testWidgets('dettaglio con la sola data: la «x» la toglie subito', (
      tester,
    ) async {
      size(tester, 900, 1400);
      final (s, id) = await withExam(tester, date: DateTime(2099, 2, 10));
      await pump(tester, s, ExamDetailScreen(examId: id));
      await tester.tap(find.byTooltip('Rimuovi data'));
      await settle(tester);
      expect(find.byType(ListTile), findsNothing);
      final e = (await tester.runAsync(() => s.exams.byId(id)))!;
      expect(e.date, isNull);
      expect(find.text('Data tolta'), findsOneWidget);
    });

    testWidgets('modulo: le «x» compaiono solo con data e orario; la data '
        'tolta toglie anche l\'orario; il tipo non si cambia', (tester) async {
      size(tester, 900, 1600);
      final (s, id) = await withExam(
        tester,
        date: DateTime(2099, 2, 10),
        time: '09:30',
        kind: ExamKind.midterm,
      );
      final exam = (await tester.runAsync(() => s.exams.byId(id)))!;
      await pump(tester, s, ExamFormPage(exam: exam));
      expect(find.byTooltip('Rimuovi data'), findsOneWidget);
      expect(find.byTooltip('Rimuovi orario'), findsOneWidget);

      await tester.tap(find.byKey(const Key('exam-remove-time')));
      await tester.pump();
      expect(find.byKey(const Key('exam-remove-time')), findsNothing);
      expect(find.byKey(const Key('exam-remove-date')), findsOneWidget);

      await tester.tap(find.byKey(const Key('exam-remove-date')));
      await tester.pump();
      expect(find.byKey(const Key('exam-remove-date')), findsNothing);
      expect(find.text('Da definire'), findsNWidgets(2));

      final b = tester.widget<SegmentedButton<ExamKind>>(
        find.byType(SegmentedButton<ExamKind>),
      );
      expect(
        {for (final g in b.segments) g.value: g.enabled},
        {ExamKind.finalExam: false, ExamKind.midterm: true},
      );

      await tester.tap(find.text('Salva'));
      await settle(tester, 10);
      final e = (await tester.runAsync(() => s.exams.byId(id)))!;
      expect(e.date, isNull);
      expect(e.time, isNull);
      expect(e.kind, ExamKind.midterm);
    });

    testWidgets('modulo: tolta solo l\'ora, la data resta', (tester) async {
      size(tester, 900, 1600);
      final (s, id) = await withExam(
        tester,
        date: DateTime(2099, 2, 10),
        time: '09:30',
      );
      final exam = (await tester.runAsync(() => s.exams.byId(id)))!;
      await pump(tester, s, ExamFormPage(exam: exam));
      await tester.tap(find.byKey(const Key('exam-remove-time')));
      await tester.pump();
      await tester.tap(find.text('Salva'));
      await settle(tester, 10);
      final e = (await tester.runAsync(() => s.exams.byId(id)))!;
      expect(e.date, DateTime(2099, 2, 10));
      expect(e.time, isNull);
    });

    testWidgets('modulo nuovo senza data: nessuna «x»', (tester) async {
      size(tester, 900, 1600);
      final (s, _) = await withExam(tester);
      await pump(tester, s, const ExamFormPage());
      expect(find.byKey(const Key('exam-remove-date')), findsNothing);
      expect(find.byKey(const Key('exam-remove-time')), findsNothing);
    });

    testWidgets('320 dp con caratteri ×2: dettaglio, foglio e modulo senza '
        'overflow', (tester) async {
      size(tester, 320, 700);
      final (s, id) = await withExam(
        tester,
        date: DateTime(2099, 2, 10),
        time: '09:30',
        status: ExamStatus.booked,
      );
      await pump(tester, s, ExamDetailScreen(examId: id), scale: 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('detail-remove-when')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('when-remove-date')), findsOneWidget);
      await tester.tap(find.byKey(const Key('when-remove-time')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      // l'avviso con «Annulla» va chiuso prima di cambiare pagina
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();

      final exam = (await tester.runAsync(() => s.exams.byId(id)))!;
      await pump(
        tester,
        s,
        ExamFormPage(exam: exam.copyWith(time: '09:30')),
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('exam-remove-date')), findsOneWidget);
      expect(find.byKey(const Key('exam-remove-time')), findsOneWidget);
    });
  });
}
