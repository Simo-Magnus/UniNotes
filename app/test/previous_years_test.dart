import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/academic/academic_year.dart';
import 'package:university_notes/core/academic/course_status_sync.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/dashboard/widgets/previous_years_card.dart';
import 'package:university_notes/features/exams/exam_form.dart';
import 'package:university_notes/features/exams/exam_stats.dart';
import 'package:university_notes/features/exams/previous_years.dart';
import 'package:university_notes/features/exams/previous_years_screen.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/repositories/settings_repository.dart';
import 'package:university_notes/utils/exclusion_filter.dart';

import 'support/catalog_fixtures.dart';
import 'support/fake_reminders.dart';

const _analisi = 'Analisi matematica I';
const _fisica = 'Fisica I';
const _algoritmi = 'Algoritmi e programmazione';
const _reti = 'Reti di calcolatori';

PathSelection _selection(int year) => PathSelection(
  ateneo: UniversitaCatalog.fromJson(kUniversitaFixture).byId('polito')!,
  tipo: TipoCorso.l,
  corso: IndiceCorsi.fromJson(kIndiceFixture).corsi.first,
  year: year,
);

/// Ingegneria Informatica (fixture: Analisi e Fisica al 1° anno, Algoritmi
/// al 2°, Reti al 3°) scelto nell'onboarding all'anno [year].
Future<AppServices> _services({
  int year = 3,
  FakeNotificationPlatform? platform,
}) async {
  final db = await AppDatabase.openInMemory();
  final s = AppServices(
    db,
    catalog: fakeCatalog(
      SettingsRepository(db),
      remote: {'corsi/polito.json': jsonEncode(corsiPolitoFixture())},
    ),
    reminders: platform == null
        ? null
        : (s) => RemindersService(
            s,
            platform: platform,
            calendarBackend: FakeCalendarBackend(),
            widgets: FakeHomeWidgets(),
            platformName: 'android',
            isRecording: () => false,
          ),
  );
  await PathSetupService(s).apply(_selection(year), now: DateTime(2026, 10, 4));
  await s.loadProfile();
  return s;
}

Future<Course> _course(AppServices s, String name) async =>
    (await s.courses.all()).firstWhere((c) => c.name == name);

Future<List<Exam>> _exams(AppServices s, String name, [ExamKind? kind]) async {
  final c = await _course(s, name);
  return [
    for (final e in await s.exams.byCourse(c.id!))
      if (kind == null || e.kind == kind) e,
  ];
}

Future<Exam> _final(AppServices s, String name) async =>
    (await _exams(s, name, ExamKind.finalExam)).single;

Future<PreviousCourse> _entry(AppServices s, String name) async {
  final d = (await loadPreviousYears(s))!;
  return d.years
      .expand((y) => y.courses)
      .firstWhere((c) => c.course.name == name);
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  group('anno di partenza', () {
    test('ricavato per i profili salvati prima: mai più alto', () {
      final p = StudentProfile(
        universityId: 'polito',
        universityName: 'PoliTo',
        degreeId: 'x',
        degreeName: 'X',
        degreeType: 'L',
        durationYears: 3,
        currentYear: 3,
        referenceAa: const AcademicYear(2026),
      );
      expect(deriveStartYear(p), 3);
      expect(deriveStartYear(p, createdAt: DateTime(2026, 10, 1)), 3);
      expect(deriveStartYear(p, createdAt: DateTime(2025, 10, 1)), 2);
      // creato ad agosto 2025: anno accademico 2024/25
      expect(deriveStartYear(p, createdAt: DateTime(2025, 8, 1)), 1);
      expect(deriveStartYear(p, createdAt: DateTime(2020, 1, 1)), 1);
      expect(p.trackedFrom, 1);
      expect(p.copyWith(startYear: () => 3).trackedFrom, 3);
      expect(previousYearsLabel(2), 'del 1° anno');
      expect(previousYearsLabel(3), 'del 1° e del 2° anno');
      expect(previousYearsLabel(4), 'dal 1° al 3° anno');
    });

    test('anno di partenza 1: nessun cambiamento', () async {
      final s = await _services(year: 1);
      addTearDown(s.database.close);
      expect(s.profile.value!.startYear, 1);
      final all = await s.exams.all();
      expect(all.where((e) => e.status.isToComplete), isEmpty);
      final d = (await loadPreviousYears(s))!;
      expect(d.applies, isFalse);
      expect(d.toComplete, 0);
    });

    test(
      'anno 3: esami del 1° e del 2° «Da completare», non arretrati',
      () async {
        final s = await _services();
        addTearDown(s.database.close);
        expect(s.profile.value!.startYear, 3);
        // importati dopo il profilo: finali e prove in itinere degli anni prima
        for (final name in [_analisi, _fisica, _algoritmi]) {
          for (final e in await _exams(s, name)) {
            expect(e.status, ExamStatus.toComplete, reason: name);
          }
        }
        expect((await _final(s, _reti)).status, ExamStatus.planned);
        final all = await s.exams.all();
        // non sono in «Da sostenere»…
        expect(toTakeExams(all).map((e) => e.courseId), [
          (await _course(s, _reti)).id,
        ]);
        // …né nel menù «Corso» delle prove nuove
        final scope = s.scope;
        final none = ExclusionFilter(const []);
        expect(
          offeredInExamForm(
            await _course(s, _algoritmi),
            scope: scope,
            exclusions: none,
            passed: false,
            toComplete: true,
          ),
          isFalse,
        );
        // …né nelle statistiche, nei promemoria o nella Home
        final courses = await s.courses.mapById();
        expect(acquiredCfu(all, courses), 0);
        expect(AverageSummary('Tutti', all, courses).failed, 0);
        for (final e in await s.exams.upcoming(limit: 60)) {
          expect(e.status.isPending, isTrue);
        }
        // l'insegnamento è «Da completare» anche in Insegnamenti
        await syncCourseStatuses(s, now: DateTime(2026, 11, 10));
        expect((await _course(s, _analisi)).status, CourseStatus.toComplete);
        final d = (await loadPreviousYears(s))!;
        expect(d.applies, isTrue);
        expect(d.years.map((y) => y.year), [1, 2]);
        expect(d.toComplete, 3);
        expect(d.yearsLabel, 'del 1° e del 2° anno');
      },
    );

    test('segnati «Da sostenere» diventano arretrati', () async {
      final s = await _services();
      addTearDown(s.database.close);
      await setPreviousToTake(s, await _entry(s, _algoritmi));
      final algo = await _final(s, _algoritmi);
      expect(algo.status, ExamStatus.planned);
      final all = await s.exams.all();
      expect(toTakeExams(all).map((e) => e.courseId), contains(algo.courseId));
      expect(
        offeredInExamForm(
          await _course(s, _algoritmi),
          scope: s.scope,
          exclusions: ExclusionFilter(const []),
          passed: false,
        ),
        isTrue,
      );
      // le prove in itinere di Analisi restano nascoste finché anche
      // Analisi non diventa da sostenere
      final midterm = (await _exams(s, _analisi, ExamKind.midterm)).single;
      expect(midterm.status, ExamStatus.toComplete);
      await setPreviousToTake(s, await _entry(s, _analisi));
      expect(
        (await _exams(s, _analisi, ExamKind.midterm)).single.status,
        ExamStatus.planned,
      );
      expect((await loadPreviousYears(s))!.toComplete, 1);
      // toccando di nuovo «Da sostenere» torna «Da completare»
      final e = await _entry(s, _algoritmi);
      expect(e.choice, PreviousChoice.toTake);
      expect(e.canReset, isTrue);
      await resetPreviousToComplete(s, e);
      expect((await _final(s, _algoritmi)).status, ExamStatus.toComplete);
    });

    test('«Sostenuto» con il voto e «Segna tutti come sostenuti»', () async {
      final s = await _services();
      addTearDown(s.database.close);
      final elective = await s.courses.insert(
        Course(
          name: 'Laboratorio a scelta',
          year: 1,
          mandatory: false,
          degreeId: s.profile.value!.degreeId,
        ),
      );
      await s.exams.insert(
        Exam(courseId: elective, status: ExamStatus.toComplete),
      );
      await setPreviousTaken(s, await _entry(s, _analisi), (
        status: ExamStatus.passed,
        grade: 28,
        laude: false,
      ));
      expect((await _final(s, _analisi)).grade, 28);
      var d = (await loadPreviousYears(s))!;
      // l'insegnamento a scelta non conta tra quelli da completare
      expect(d.years.first.toComplete, 1);
      expect(d.years.first.electives.single.toComplete, isTrue);
      expect(await markPreviousYearTaken(s, d.years.first), 1);
      final fisica = await _final(s, _fisica);
      expect(fisica.status, ExamStatus.passed);
      expect(fisica.grade, isNull);
      expect((await _final(s, _analisi)).grade, 28);
      expect(
        (await s.exams.byCourse(elective)).single.status,
        ExamStatus.toComplete,
      );
      d = (await loadPreviousYears(s))!;
      expect(d.years.first.toComplete, 0);
      expect(d.toComplete, 1);
      final all = await s.exams.all();
      expect(acquiredCfu(all, await s.courses.mapById()), 18);
    });

    test(
      'profilo di una versione precedente: anno ricavato una volta',
      () async {
        final s = await _services();
        addTearDown(s.database.close);
        final db = s.database.db;
        // come prima di questa versione: niente anno, esami da prenotare
        await db.update('profile', {
          'start_year': null,
          'created_at': '2025-10-10T10:00:00',
        });
        await db.update('exams', {
          'status': 'planned',
        }, where: "status = 'to_complete'");
        // Fisica toccata dallo studente (nota scritta): resta un arretrato
        await db.update(
          'exams',
          {'notes': 'chiedere al prof'},
          where: 'id = ?',
          whereArgs: [(await _final(s, _fisica)).id],
        );
        final p = await s.loadProfile();
        // al 3° anno nel 2026/27, profilo creato nel 2025/26: partenza al 2°
        expect(p!.startYear, 2);
        expect((await _final(s, _analisi)).status, ExamStatus.toComplete);
        expect(
          (await _exams(s, _analisi, ExamKind.midterm)).single.status,
          ExamStatus.toComplete,
        );
        expect((await _final(s, _fisica)).status, ExamStatus.planned);
        expect((await _final(s, _algoritmi)).status, ExamStatus.planned);
        // una volta sola: le scelte successive restano
        await setPreviousToTake(s, await _entry(s, _analisi));
        await s.loadProfile();
        expect((await _final(s, _analisi)).status, ExamStatus.planned);
      },
    );

    test('cambio di corso: le scelte già fatte restano', () async {
      final s = await _services(year: 2);
      addTearDown(s.database.close);
      await setPreviousTaken(s, await _entry(s, _analisi), (
        status: ExamStatus.passed,
        grade: 30,
        laude: true,
      ));
      await setPreviousToTake(s, await _entry(s, _fisica));
      // ora al 3° anno (stesso corso di laurea): solo il 2° si aggiunge
      await PathSetupService(s).apply(_selection(3));
      await s.loadProfile();
      expect(s.profile.value!.startYear, 3);
      expect((await _final(s, _analisi)).status, ExamStatus.passed);
      expect((await _final(s, _analisi)).laude, isTrue);
      expect((await _final(s, _fisica)).status, ExamStatus.planned);
      expect((await _final(s, _algoritmi)).status, ExamStatus.toComplete);
      // di nuovo al 1° anno: nulla da completare
      await PathSetupService(s).apply(_selection(1));
      await s.loadProfile();
      final all = await s.exams.all();
      expect(all.where((e) => e.status.isToComplete), isEmpty);
      expect((await _final(s, _algoritmi)).status, ExamStatus.planned);
    });

    test(
      'un esame finale aggiunto a mano assorbe quello da completare',
      () async {
        final s = await _services();
        addTearDown(s.database.close);
        final c = await _course(s, _algoritmi);
        await s.exams.insert(Exam(courseId: c.id!));
        expect(await s.exams.mergeDuplicateFinals(), 1);
        final f = await _final(s, _algoritmi);
        expect(f.status, ExamStatus.planned);
        expect(f.externalId, isNotNull);
      },
    );
  });

  group('notifiche', () {
    test('due promemoria: dopo 3 e dopo 14 giorni', () {
      final n = previousYearsReminders(
        since: DateTime(2026, 10, 21, 9),
        count: 3,
        startYear: 3,
      );
      expect(n.map((x) => x.at), [
        DateTime(2026, 10, 24, 18),
        DateTime(2026, 11, 4, 18),
      ]);
      expect(n.first.type, NotificationType.previousYears);
      expect(n.first.type.section, 'Esami');
      expect(n.first.payload, AppRoutes.previousYears);
      expect(n.first.title, 'Completa gli esami degli anni precedenti');
      expect(n.first.body, contains('3 esami del 1° e del 2° anno'));
      expect(n.first.actions, isEmpty);
      expect(
        previousYearsReminders(since: DateTime(2026), count: 0, startYear: 3),
        isEmpty,
      );
      expect(
        previousYearsReminders(since: DateTime(2026), count: 2, startYear: 1),
        isEmpty,
      );
      final plan = planNotifications(
        now: DateTime(2026, 10, 25),
        prefs: const NotificationPrefs(consent: true, donation: false),
        agenda: const [],
        previousYears: n,
      );
      // quella dopo 3 giorni è già passata: resta la seconda
      expect(plan.single.at, DateTime(2026, 11, 4, 18));
      expect(
        planNotifications(
          now: DateTime(2026, 10, 22),
          prefs: const NotificationPrefs(
            consent: true,
            donation: false,
            previousYears: false,
          ),
          agenda: const [],
          previousYears: n,
        ),
        isEmpty,
      );
    });

    test('pianificati finché resta qualcosa da completare', () async {
      final platform = FakeNotificationPlatform();
      final s = await _services(platform: platform);
      addTearDown(s.database.close);
      final r = s.reminders;
      await s.settings.set(NotificationKeys.consent, '1');
      await PreviousYearsPrompt.restart(
        s.settings,
        now: DateTime(2026, 10, 21, 9),
      );
      Future<List<PlannedNotification>> plan(DateTime t) async => r.reschedule(
        await r.loadAgenda(t),
        await r.calendar.status(),
        now: t,
      );
      var p = ofType(
        await plan(DateTime(2026, 10, 21, 10)),
        NotificationType.previousYears,
      );
      expect(p.map((n) => n.at), [
        DateTime(2026, 10, 24, 18),
        DateTime(2026, 11, 4, 18),
      ]);
      // interruttore spento: nessuna
      await s.settings.set(NotificationKeys.previousYears, '0');
      p = ofType(
        await plan(DateTime(2026, 10, 21, 10)),
        NotificationType.previousYears,
      );
      expect(p, isEmpty);
      await s.settings.set(NotificationKeys.previousYears, '1');
      // tutto completato: nessuna
      for (final y in (await loadPreviousYears(s))!.years) {
        await markPreviousYearTaken(s, y);
      }
      p = ofType(
        await plan(DateTime(2026, 10, 21, 10)),
        NotificationType.previousYears,
      );
      expect(p, isEmpty);
    });
  });

  group('schermate', () {
    Future<void> settle(WidgetTester tester, [int rounds = 8]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
    }

    Future<AppServices> pump(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(_services))!;
      addTearDown(() => tester.runAsync(s.database.close));
      await tester.pumpWidget(
        Provider.value(
          value: s,
          child: MaterialApp(
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
      await settle(tester);
      return s;
    }

    testWidgets('Anni precedenti: due scelte per riga, tutti sostenuti', (
      tester,
    ) async {
      final s = await pump(tester, const PreviousYearsScreen());
      final p = s.profile.value!;
      expect(find.text('Esami prima del 3° anno'), findsOneWidget);
      expect(find.text('3 da completare'), findsOneWidget);
      expect(find.text(p.yearChipLabel(1)), findsOneWidget);
      expect(find.text(p.yearChipLabel(2)), findsOneWidget);
      // solo il nome dell'insegnamento, niente anni successivi
      expect(find.text(_analisi), findsOneWidget);
      expect(find.text(_reti), findsNothing);
      expect(find.text('Da completare'), findsNWidgets(3));

      // «Da sostenere» per Algoritmi: arretrato
      final algo = (await tester.runAsync(() => _course(s, _algoritmi)))!;
      final row = find.byKey(ValueKey('previous-choice-${algo.id}'));
      await tester.tap(
        find.descendant(of: row, matching: find.text('Da sostenere')),
      );
      await settle(tester);
      expect(
        (await tester.runAsync(() => _final(s, _algoritmi)))!.status,
        ExamStatus.planned,
      );
      expect(find.text('Da sostenere (arretrato)'), findsOneWidget);
      expect(find.text('2 da completare'), findsOneWidget);

      // «Sostenuto» per Algoritmi: il voto (facoltativo)
      await tester.tap(
        find.descendant(of: row, matching: find.text('Sostenuto')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Com\'è andato?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('grade-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('27/30').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('grade-save')));
      await settle(tester);
      final f = (await tester.runAsync(() => _final(s, _algoritmi)))!;
      expect(f.status, ExamStatus.passed);
      expect(f.grade, 27);
      expect(find.text('Superato con 27'), findsOneWidget);

      // tutto il 1° anno: conferma con «Non chiedere più»
      await tester.tap(find.byKey(const Key('previous-all-1')));
      await settle(tester);
      expect(find.text('Segnare tutti come sostenuti?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('previous-all-dont-ask')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('previous-all-confirm')));
      await settle(tester);
      expect(
        (await tester.runAsync(() => _final(s, _fisica)))!.status,
        ExamStatus.passed,
      );
      expect(
        await tester.runAsync(
          () => s.settings.get(PreviousYearsPrompt.dontAskMarkAllKey),
        ),
        '1',
      );
      // niente più da completare: riepilogo modificabile
      expect(find.text('Anni precedenti completati'), findsOneWidget);
      expect(find.byKey(const Key('previous-all-1')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Home: «Completa» o «Più tardi» (torna dopo 7 giorni)', (
      tester,
    ) async {
      final s = await pump(
        tester,
        const Scaffold(body: Column(children: [PreviousYearsHomeCard()])),
      );
      expect(
        find.text('Completa gli esami degli anni precedenti'),
        findsOneWidget,
      );
      expect(find.textContaining('Ne restano 3 da completare'), findsOneWidget);
      // due pulsanti
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);
      await tester.tap(find.byKey(const Key('home-previous-later')));
      await settle(tester);
      expect(find.byKey(const Key('home-previous-years')), findsNothing);
      expect(
        await tester.runAsync(
          () => PreviousYearsPrompt.homeVisible(s.settings),
        ),
        isFalse,
      );
      expect(
        await tester.runAsync(
          () => PreviousYearsPrompt.homeVisible(
            s.settings,
            now: DateTime.now().add(const Duration(days: 8)),
          ),
        ),
        isTrue,
      );
      // «Completa» apre gli Anni precedenti
      await tester.runAsync(
        () => s.settings.set(PreviousYearsPrompt.laterKey, null),
      );
      s.revision.bump();
      await settle(tester);
      await tester.tap(find.byKey(const Key('home-previous-open')));
      await settle(tester);
      expect(find.byType(PreviousYearsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
