import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/academic/year_grades_screen.dart';
import 'package:university_notes/features/courses/course_detail_screen.dart';
import 'package:university_notes/features/courses/course_form.dart';
import 'package:university_notes/features/courses/course_ui.dart';
import 'package:university_notes/features/courses/courses_screen.dart';
import 'package:university_notes/features/dashboard/dashboard_screen.dart';
import 'package:university_notes/features/exams/exam_detail.dart';
import 'package:university_notes/features/exams/exam_form.dart';
import 'package:university_notes/features/exams/previous_years_screen.dart';
import 'package:university_notes/features/onboarding/onboarding_flow.dart';
import 'package:university_notes/features/settings/settings_screen.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/features/study/course_groups.dart';
import 'package:university_notes/features/study/focus/focus_plan.dart';
import 'package:university_notes/features/study/focus/focus_screen.dart';
import 'package:university_notes/features/study/focus/focus_service.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/features/study/study_timer.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/models/study.dart';
import 'package:university_notes/widgets/date_pick.dart';
import 'package:university_notes/widgets/math_text.dart';

/// Caccia ai crash delle schermate: dati limite (vuoti, enormi, fuori
/// scala), caratteri grandi, finestre strette, doppi tocchi. Ogni eccezione
/// (anche le asserzioni di layout) fa fallire il test.
Future<AppServices> _empty() async {
  final db = await AppDatabase.openInMemory();
  for (final t in [
    'courses',
    'universities',
    'degrees',
    'books',
    'exams',
    'modules',
    'topics',
    'study_sessions',
    'attachments',
    'materials',
    'profile',
    'plan_years',
  ]) {
    await db.db.delete(t);
  }
  return AppServices(db);
}

const _long =
    'Insegnamento dal nome lunghissimo con parole come '
    'Elettrotecnicaapplicataallemacchineelettricheeaisistemidipotenza e '
    'ancora altre parole per riempire tutte le righe disponibili';

/// Dati strani: CFU infiniti e negativi, voto fuori scala, anni saltati,
/// date estreme, nomi lunghissimi, difficoltà fuori 0–5.
Future<AppServices> _weird() async {
  final s = await _empty();
  final a = await s.courses.insert(
    const Course(name: _long, year: 1, semester: '1', cfu: double.infinity),
  );
  final b = await s.courses.insert(
    const Course(name: 'Fisica', year: 3, cfu: -6, difficulty: 7),
  );
  final c = await s.courses.insert(const Course(name: 'Senza nulla'));
  // stesso semestre scritto in un altro modo (dati importati)
  final d = await s.courses.insert(
    const Course(name: 'Chimica', year: 1, semester: '1° semestre'),
  );
  final md = await s.study.insertModule(StudyModule(courseId: d, name: 'M'));
  await s.study.insertTopic(Topic(moduleId: md, name: 'T'));
  await s.exams.save(
    Exam(
      courseId: a,
      date: DateTime(1900, 1, 1),
      time: '99:99',
      status: ExamStatus.passed,
      grade: 5,
      cfu: double.infinity,
      title: _long,
    ),
  );
  await s.exams.save(
    Exam(
      courseId: b,
      date: DateTime(2300, 12, 31),
      status: ExamStatus.passed,
      laude: true,
    ),
  );
  await s.exams.save(
    Exam(
      courseId: c,
      kind: ExamKind.midterm,
      status: ExamStatus.passed,
      grade: 100,
    ),
  );
  final m = await s.study.insertModule(StudyModule(courseId: a, name: _long));
  await s.study.insertTopic(Topic(moduleId: m, name: _long));
  final now = DateTime.now();
  // una sola sessione, di un giorno solo; una che «finisce prima di
  // cominciare» (cambio d'ora)
  await s.study.insertSession(
    StudySession(
      courseId: a,
      start: now.subtract(const Duration(minutes: 30)),
      end: now.subtract(const Duration(minutes: 40)),
      durationMinutes: 0,
      activityType: ActivityType.theory,
    ),
  );
  await s.study.insertSession(
    StudySession(
      courseId: a,
      start: now.subtract(const Duration(days: 400)),
      end: now.subtract(const Duration(days: 400)),
      durationMinutes: 100000,
      activityType: ActivityType.exercises,
    ),
  );
  return s;
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

/// Solo le eccezioni vere: la striscia gialla e nera di un overflow resta
/// un difetto di aspetto (lo controlla large_text_test sulle schermate
/// principali), qui si cercano i crash. Gli overflow si scartano, il resto
/// passa al gestore del test (che lo stampa per intero).
void Function(FlutterErrorDetails)? _previous;

void _collect() {
  final previous = _previous = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.toString().contains('overflowed by')) return;
    previous?.call(d);
  };
}

void _release() {
  FlutterError.onError = _previous;
}

void _noCrash(WidgetTester tester, String reason) {
  final e = tester.takeException();
  if (e != null) {
    fail('$reason: ${e is FlutterError ? e.toStringDeep() : e}');
  }
}

void _size(WidgetTester tester, double width, double scale) {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  group('numeri e date fuori scala', () {
    test('formatNumber e parseCfu con infiniti e NaN', () {
      expect(formatNumber(double.infinity), '—');
      expect(formatNumber(double.negativeInfinity), '—');
      expect(formatNumber(double.nan), '—');
      expect(formatCfu(double.infinity), 'CFU n.d.');
      expect(parseCfu('Infinity'), isNull);
      expect(parseCfu('1e999'), isNull);
      expect(parseCfu('NaN'), isNull);
      expect(parseCfu('-3'), isNull);
      expect(parseCfu('61'), isNull);
      expect(parseCfu(' 7,5 '), 7.5);
      expect(parseCfu('0'), 0);
    });

    test('intervallo del selettore di date con data salvata fuori', () {
      final now = DateTime(2026, 10, 22, 15, 30);
      var r = safeDateRange(DateTime(1900), DateTime(2016), DateTime(2031));
      expect(r.first, DateTime(1900));
      expect(r.last, DateTime(2031));
      r = safeDateRange(DateTime(2300, 12, 31), DateTime(2016), DateTime(2031));
      expect(r.last, DateTime(2300, 12, 31));
      // 1° gennaio dell'ultimo anno alle 15:30: l'ora non conta
      r = safeDateRange(now, DateTime(2016), DateTime(2026, 10, 22));
      expect(r.initial, DateTime(2026, 10, 22));
      expect(r.last, DateTime(2026, 10, 22));
    });
  });

  for (final (width, scale) in [(320.0, 2.0), (320.0, 3.0), (900.0, 2.5)]) {
    testWidgets('dati strani, ${width.toInt()} px, caratteri ×$scale', (
      tester,
    ) async {
      _size(tester, width, scale);
      _collect();
      addTearDown(_release);
      final s = (await tester.runAsync(_weird))!;
      addTearDown(() => tester.runAsync(s.database.close));
      for (final screen in <Widget>[
        const DashboardScreen(),
        const CoursesScreen(),
        const ExamsScreen(),
        const StudyScreen(),
        const YearGradesScreen(year: 1),
        const YearGradesScreen(year: 2),
        const YearGradesScreen(year: 3),
        const ExamFormPage(),
      ]) {
        await _pump(tester, s, const SizedBox());
        await _pump(tester, s, screen);
        _noCrash(tester, '$screen');
      }
      // tutte le schede di Esami e Studio
      for (final (screen, tabs) in [
        (const ExamsScreen(), ['Sostenuti', 'Medie', 'Da sostenere']),
        (const StudyScreen(), ['Sessioni Studio', 'Statistiche']),
      ]) {
        await _pump(tester, s, const SizedBox());
        await _pump(tester, s, screen);
        for (final tab in tabs) {
          final f = find.text(tab);
          if (f.evaluate().isEmpty) continue;
          await tester.ensureVisible(f.first);
          await tester.tap(f.first);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await _settle(tester);
          _noCrash(tester, '$screen / $tab');
        }
      }
      // modulo dell'insegnamento con difficoltà 7 (fuori dallo Slider)
      final fisica = (await tester.runAsync(s.courses.all))!.firstWhere(
        (c) => c.name == 'Fisica',
      );
      await _pump(tester, s, CourseFormPage(course: fisica));
      _noCrash(tester, 'CourseFormPage difficoltà 7');
    });
  }

  for (final (width, scale) in [(320.0, 3.0), (1200.0, 1.0)]) {
    testWidgets('dettagli, impostazioni e onboarding con dati strani, '
        '${width.toInt()} px ×$scale', (tester) async {
      _size(tester, width, scale);
      _collect();
      addTearDown(_release);
      final s = (await tester.runAsync(_weird))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final courses = (await tester.runAsync(s.courses.all))!;
      final exams = (await tester.runAsync(s.exams.all))!;
      for (final screen in <Widget>[
        for (final c in courses) CourseDetailScreen(courseId: c.id!),
        for (final e in exams) ExamDetailScreen(examId: e.id!),
        for (final e in exams) ExamFormPage(exam: e),
        for (final c in courses) CourseFormPage(course: c),
        const ExamDetailScreen(examId: 99999),
        const CourseDetailScreen(courseId: 99999),
        const PreviousYearsScreen(),
        const SettingsScreen(),
        const OnboardingFlow(),
        const OnboardingFlow(canCancel: true),
        const FocusScreen(),
      ]) {
        await _pump(tester, s, const SizedBox());
        await _pump(tester, s, screen);
        _noCrash(tester, '$screen');
      }
    });
  }

  testWidgets('finestra ridimensionata a metà animazione', (tester) async {
    _size(tester, 1400, 1);
    _collect();
    addTearDown(_release);
    final s = (await tester.runAsync(_weird))!;
    addTearDown(() => tester.runAsync(s.database.close));
    final course = (await tester.runAsync(s.courses.all))!.first;
    const sizes = [
      Size(1400, 900),
      Size(320, 600),
      Size(900, 1000),
      Size(700, 320),
      Size(1100, 700),
      Size(320, 480),
    ];
    for (final screen in <Widget>[
      const DashboardScreen(),
      const ExamsScreen(),
      const CoursesScreen(),
      const StudyScreen(),
      const SettingsScreen(),
      CourseDetailScreen(courseId: course.id!),
    ]) {
      tester.view.physicalSize = sizes.first;
      await _pump(tester, s, const SizedBox());
      await _pump(tester, s, screen);
      // un tocco sul primo elemento toccabile (apre dettagli o schede),
      // poi la finestra cambia mentre l'animazione è in corso
      final tiles = find.byType(InkWell);
      if (tiles.evaluate().length > 3) {
        await tester.tap(tiles.at(3), warnIfMissed: false);
      }
      for (final size in sizes) {
        tester.view.physicalSize = size;
        await tester.pump(const Duration(milliseconds: 60));
        await tester.pump(const Duration(milliseconds: 60));
        _noCrash(tester, '$screen a $size');
      }
      await _settle(tester);
      _noCrash(tester, '$screen dopo i cambi');
      // eventuali pagine aperte dal tocco
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.popUntil((r) => r.isFirst);
      // niente pumpAndSettle: alcune schermate hanno animazioni continue
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      _noCrash(tester, '$screen chiusura');
    }
  });

  testWidgets('date salvate nel 1900 e nel 2300: il selettore si apre', (
    tester,
  ) async {
    _size(tester, 400, 1);
    _collect();
    addTearDown(_release);
    final s = (await tester.runAsync(_weird))!;
    addTearDown(() => tester.runAsync(s.database.close));
    final exams = (await tester.runAsync(s.exams.all))!;
    for (final e in exams.where((e) => e.date != null)) {
      await _pump(tester, s, const SizedBox());
      await _pump(tester, s, ExamDetailScreen(examId: e.id!));
      final when = find.text('Data e ora');
      await tester.scrollUntilVisible(
        when,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(when.first);
      await tester.pumpAndSettle();
      _noCrash(tester, 'dettaglio ${e.date}');
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Annulla').last);
      await tester.pumpAndSettle();
      // modulo completo
      await _pump(tester, s, const SizedBox());
      await _pump(tester, s, ExamFormPage(exam: e));
      final date = find.text('Data');
      await tester.scrollUntilVisible(
        date,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(date.first);
      await tester.pumpAndSettle();
      _noCrash(tester, 'modulo ${e.date}');
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Annulla').last);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('database vuoto, 320 px, caratteri ×3', (tester) async {
    _size(tester, 320, 3);
    _collect();
    addTearDown(_release);
    final s = (await tester.runAsync(_empty))!;
    addTearDown(() => tester.runAsync(s.database.close));
    for (final screen in <Widget>[
      const DashboardScreen(),
      const CoursesScreen(),
      const ExamsScreen(),
      const StudyScreen(),
      const YearGradesScreen(year: 1),
      const ExamFormPage(),
      const CourseFormPage(),
    ]) {
      await _pump(tester, s, const SizedBox());
      await _pump(tester, s, screen);
      _noCrash(tester, '$screen');
    }
  });

  testWidgets('voti dell\'anno: voto fuori scala resta com\'è salvando', (
    tester,
  ) async {
    _size(tester, 400, 1);
    _collect();
    addTearDown(_release);
    final s = (await tester.runAsync(_weird))!;
    addTearDown(() => tester.runAsync(s.database.close));
    await _pump(tester, s, const YearGradesScreen(year: 1, markYear: false));
    _noCrash(tester, 'YearGradesScreen');
    await tester.tap(find.byKey(const Key('grades-save')));
    await _settle(tester);
    _noCrash(tester, 'salva');
    final exams = (await tester.runAsync(s.exams.all))!;
    final e = exams.firstWhere((e) => e.grade == 5);
    expect(e.status, ExamStatus.passed);
  });

  testWidgets('nuovo esame: «Esame a scelta», Annulla, poi Salva', (
    tester,
  ) async {
    _size(tester, 400, 1);
    _collect();
    addTearDown(_release);
    final s = (await tester.runAsync(_weird))!;
    addTearDown(() => tester.runAsync(s.database.close));
    await _pump(tester, s, const ExamFormPage());
    await tester.tap(find.text('Corso *'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Esame a scelta (fuori piano)…').last);
    await tester.pumpAndSettle();
    expect(find.text('Esame a scelta'), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    // il menù torna vuoto: Salva chiede il corso invece di rompersi
    expect(find.text('Esame a scelta (fuori piano)…'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Salva'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Salva'));
    await _settle(tester);
    _noCrash(tester, 'salva dopo Annulla');
  });

  testWidgets('nuovo esame: fuori piano, poi «Prova in itinere»', (
    tester,
  ) async {
    _size(tester, 400, 1);
    _collect();
    addTearDown(_release);
    final s = (await tester.runAsync(_weird))!;
    addTearDown(() => tester.runAsync(s.database.close));
    await _pump(tester, s, const ExamFormPage());
    await tester.tap(find.text('Corso *'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Esame a scelta (fuori piano)…').last);
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), 'Scacchi');
    await tester.enterText(fields.at(1), 'Infinity');
    await tester.tap(find.text('Aggiungi'));
    await tester.pumpAndSettle();
    // CFU infiniti rifiutati nel dialogo
    expect(find.text('Valore CFU non valido'), findsOneWidget);
    await tester.enterText(fields.at(1), '6');
    await tester.tap(find.text('Aggiungi'));
    await tester.pumpAndSettle();
    expect(find.text('Fuori piano: Scacchi'), findsOneWidget);
    await tester.tap(find.text('Itinere o esonero'));
    await tester.pumpAndSettle();
    _noCrash(tester, 'cambio tipo con la voce fuori piano');
  });

  testWidgets('Focus aperto sopra una card che ascolta la sessione', (
    tester,
  ) async {
    _size(tester, 400, 1);
    _collect();
    addTearDown(_release);
    final s = (await tester.runAsync(_weird))!;
    addTearDown(() => tester.runAsync(s.database.close));
    await tester.runAsync(
      () => s.focus.start(
        const FocusSettings(minutes: 25),
        const FocusLink(label: 'Analisi'),
      ),
    );
    await _pump(
      tester,
      s,
      Builder(
        builder: (context) => Scaffold(
          body: ListenableBuilder(
            listenable: s.focus,
            builder: (_, _) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const FocusScreen()),
                ),
                child: Text('apri ${s.focus.screenVisible}'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.textContaining('apri'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    _noCrash(tester, 'apertura FocusScreen');
    Navigator.of(tester.element(find.byType(FocusScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    _noCrash(tester, 'chiusura FocusScreen');
    await tester.runAsync(() => s.focus.discard());
    await tester.pump();
  });

  testWidgets('Focus di 4 ore con pause ogni 20 minuti a 320 px', (
    tester,
  ) async {
    _size(tester, 320, 1);
    final s = (await tester.runAsync(_empty))!;
    addTearDown(() => tester.runAsync(s.database.close));
    await tester.runAsync(
      () => s.focus.start(
        const FocusSettings(minutes: 240, breakEvery: 20, breakMinutes: 3),
        const FocusLink(label: 'Analisi'),
      ),
    );
    await _pump(tester, s, const FocusScreen());
    // qui anche la striscia gialla e nera conta: i tratti devono stare
    // nella riga
    final e = tester.takeException();
    expect(e, isNull, reason: '$e');
    await tester.runAsync(() => s.focus.discard());
    await tester.pump();
  });

  testWidgets('formule rotte o enormi non rompono la pagina', (tester) async {
    _size(tester, 320, 2);
    _collect();
    addTearDown(_release);
    final s = (await tester.runAsync(_empty))!;
    addTearDown(() => tester.runAsync(s.database.close));
    final nested = '${'{' * 400}x${'}' * 400}';
    final frac = '${r'\frac{1}{' * 120}2${'}' * 120}';
    final cases = [
      r'$\frac$',
      r'$\frac{1}$',
      r'$\begin{matrix} a & b$',
      r'$\sqrt[\frac{}{}]{}$',
      r'$\left( x$',
      r'$\unknowncommand{x}$',
      r'$$ $$',
      r'$\\\\\\$',
      '\$$nested\$',
      '\$$frac\$',
      '\$${'x^' * 300}2\$',
      '\$${List.filled(2000, 'a+').join()}b\$',
      r'$\color{zzz}{x}$',
      r'$\rule{99999em}{99999em}$',
      r'$\hspace{-99999em}x$',
      r'$\kern{1e308em}$',
    ];
    await _pump(
      tester,
      s,
      Scaffold(
        body: ListView(
          children: [
            for (final c in cases) MathText(c, maxLines: 3),
            for (final c in cases) MathText(c),
          ],
        ),
      ),
    );
    _noCrash(tester, 'formule');
  });

  test('semestri diversi con la stessa etichetta: un gruppo solo', () {
    const a = Course(id: 1, name: 'A', semester: '1');
    const b = Course(id: 2, name: 'B', semester: '1° semestre');
    const c = Course(id: 3, name: 'C', semester: '1');
    const d = Course(id: 4, name: 'D', semester: 'OFA');
    const e = Course(id: 5, name: 'OFA di matematica');
    final groups = groupStudyCourses([a, b, c, d, e]);
    final labels = [for (final g in groups) g.label];
    expect(labels.toSet().length, labels.length);
    final first = groups.firstWhere((g) => g.label == '1° semestre');
    expect([for (final x in first.courses) x.id], [1, 2, 3]);
    final ofa = groups.firstWhere((g) => g.label == 'OFA');
    expect([for (final x in ofa.courses) x.id], [4, 5]);
  });

  testWidgets('cronometro: la sessione non salvata torna nel cronometro', (
    tester,
  ) async {
    final timer = StudyTimer.instance;
    timer.reset();
    final start = DateTime(2026, 10, 22, 9);
    timer.putBack(
      StudySession(
        start: start,
        durationMinutes: 42,
        activityType: ActivityType.theory,
        notes: 'appunti',
      ),
    );
    expect(timer.elapsed, const Duration(minutes: 42));
    expect(timer.isRunning, isFalse);
    expect(timer.notes, 'appunti');
    final again = timer.stop();
    expect(again?.durationMinutes, 42);
    expect(again?.start, start);
  });
}
