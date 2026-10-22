import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/core/theme/app_tokens.dart';
import 'package:university_notes/features/study/course_catalog.dart';
import 'package:university_notes/features/study/focus/focus_context.dart';
import 'package:university_notes/features/study/focus/focus_plan.dart';
import 'package:university_notes/features/study/focus/focus_screen.dart';
import 'package:university_notes/features/study/focus/focus_service.dart';
import 'package:university_notes/features/study/module_card.dart';
import 'package:university_notes/features/study/sessions_tab.dart';
import 'package:university_notes/features/study/stats_tab.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/features/study/study_stats.dart';
import 'package:university_notes/features/study/study_widgets.dart';
import 'package:university_notes/features/study/topics_tab.dart';
import 'package:university_notes/models/attachment.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/study.dart';

/// Studio, richieste del 22/10: scelta dell'insegnamento in arancione, un
/// solo «Aggiungi modulo», intervallo delle sessioni, icone delle attività,
/// schermata Focus con modulo e file, Statistiche senza percentuali e con
/// la materia degli argomenti.

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
}

Future<AppServices> _services() async =>
    AppServices(await AppDatabase.openInMemory());

StudySession _session(
  int? course,
  DateTime start,
  int minutes, {
  int? topic,
  ActivityType activity = ActivityType.theory,
  bool focus = false,
}) => StudySession(
  courseId: course,
  topicId: topic,
  start: start,
  end: start.add(Duration(minutes: minutes)),
  durationMinutes: minutes,
  activityType: activity,
  focus: focus,
);

Widget _app(AppServices s, Widget home, {ThemeData? theme}) =>
    Provider<AppServices>.value(
      value: s,
      child: MaterialApp(theme: theme, home: home),
    );

void main() {
  setUpAll(() => initializeDateFormatting('it_IT'));

  group('scelta dell\'insegnamento', () {
    final courses = [
      const Course(id: 1, name: 'Analisi I', semester: '1'),
      const Course(id: 2, name: 'Fisica I', semester: '1'),
      const Course(id: 3, name: 'Geometria', semester: 'annuale'),
    ];

    for (final (name, theme, tokens) in [
      ('scuro', AppTheme.dark(), AppTokens.dark),
      ('chiaro', AppTheme.light(), AppTokens.light),
      (
        'scuro alto contrasto',
        AppTheme.dark(highContrast: true),
        AppTokens.dark.highContrast(Brightness.dark),
      ),
      (
        'chiaro alto contrasto',
        AppTheme.light(highContrast: true),
        AppTokens.light.highContrast(Brightness.light),
      ),
    ]) {
      testWidgets('tema $name: scelto in arancione, non nell\'azzurro dei '
          'gruppi, con contrasto sufficiente', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: CoursePickerList(
                courses: courses,
                selected: 2,
                onSelect: (_) {},
                onReordered: (_) {},
              ),
            ),
          ),
        );
        final context = tester.element(find.byType(CoursePickerList));
        final accent = CoursePickTile.accentOf(context);
        final scheme = Theme.of(context).colorScheme;
        final t = context.tokens;
        // il colore della scelta non è quello dei titoli dei gruppi
        expect(accent, isNot(scheme.primary));
        expect(accent, t.orangeInk);
        expect(t.orangeInk, tokens.orangeInk);
        final groupTitle = tester.widget<Text>(find.text('1° semestre'));
        expect(groupTitle.style?.color, scheme.primary);

        // una sola riga scelta: barretta e spunta arancioni
        final check = tester.widget<Icon>(find.byIcon(Icons.check_rounded));
        expect(check.color, accent);
        expect(find.byIcon(Icons.check_rounded), findsOneWidget);
        final bars = tester
            .widgetList<AnimatedContainer>(
              find.byKey(const Key('pick-course-bar')),
            )
            .map((b) => (b.decoration as BoxDecoration?)?.color)
            .toList();
        expect(bars.where((c) => c == accent), hasLength(1));

        // contrasto sul fondo del foglio tinto: spunta e barretta come
        // testo (4,5:1), nome dell'insegnamento 4,5:1
        final sheet =
            theme.bottomSheetTheme.modalBackgroundColor ?? scheme.surface;
        final tinted = Color.alphaBlend(CoursePickTile.tintOf(context), sheet);
        expect(contrastRatio(accent, tinted), greaterThanOrEqualTo(4.5));
        expect(contrastRatio(accent, sheet), greaterThanOrEqualTo(4.5));
        expect(contrastRatio(t.textPrimary, tinted), greaterThanOrEqualTo(4.5));
      });
    }

    testWidgets('un tocco sceglie l\'insegnamento', (tester) async {
      int? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CoursePickerList(
              courses: courses,
              selected: 1,
              onSelect: (id) => picked = id,
              onReordered: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('Geometria'));
      expect(picked, 3);
      // la riga scelta è annunciata come selezionata
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        tester.getSemantics(find.byType(CoursePickTile).first),
        isSemantics(isSelected: true),
      );
      handle.dispose();
    });
  });

  testWidgets('«Aggiungi modulo» in cima e sotto l\'ultimo modulo (con '
      'almeno un modulo), entrambi aprono la creazione del modulo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late int courseId;
    final s = (await tester.runAsync(() async {
      final s = await _services();
      courseId = await s.courses.insert(const Course(name: 'Analisi I'));
      await s.courses.insert(const Course(name: 'Fisica I'));
      for (final n in ['Limiti', 'Derivate']) {
        final m = await s.study.insertModule(
          StudyModule(courseId: courseId, name: n),
        );
        await s.study.insertTopic(Topic(moduleId: m, name: 'Argomento $n'));
      }
      return s;
    }))!;
    addTearDown(() => tester.runAsync(s.database.close));
    await tester.pumpWidget(_app(s, const StudyScreen()));
    await _settle(tester);
    expect(find.byType(ModuleCard), findsNWidgets(2));
    final top = find.byKey(const Key('add-module-top'));
    final bottom = find.byKey(const Key('add-module-bottom'));
    expect(find.text('Aggiungi modulo'), findsNWidgets(2));
    expect(top, findsOneWidget);
    expect(bottom, findsOneWidget);
    // in cima: nella card dell'insegnamento, sopra il primo modulo
    expect(
      tester.getBottomLeft(top).dy,
      lessThan(tester.getTopLeft(find.byType(ModuleCard).first).dy),
    );
    // in fondo: sotto l'ultimo modulo, a tutta larghezza, 44 px
    final rect = tester.getRect(bottom);
    expect(
      rect.top,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(ModuleCard).last).dy,
      ),
    );
    expect(rect.height, greaterThanOrEqualTo(44));
    expect(rect.width, greaterThan(380));

    // entrambi aprono «Nuovo modulo» e creano il modulo
    Future<void> add(Finder button, String name) async {
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Nuovo modulo'), findsOneWidget);
      await tester.enterText(find.byType(TextField), name);
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      await _settle(tester);
    }

    await add(bottom, 'Integrali');
    await add(top, 'Serie');
    final names = [
      for (final m in (await tester.runAsync(() => s.study.modules(courseId)))!)
        m.name,
    ];
    expect(names, ['Limiti', 'Derivate', 'Integrali', 'Serie']);
    expect(find.byType(ModuleCard), findsNWidgets(4));
    expect(bottom, findsOneWidget);
  });

  testWidgets('senza moduli solo «Aggiungi modulo» in cima (niente '
      'doppione)', (tester) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = (await tester.runAsync(() async {
      final s = await _services();
      await s.courses.insert(const Course(name: 'Analisi I'));
      return s;
    }))!;
    addTearDown(() => tester.runAsync(s.database.close));
    await tester.pumpWidget(_app(s, const StudyScreen()));
    await _settle(tester);
    expect(find.byKey(const Key('add-module-top')), findsOneWidget);
    expect(find.byKey(const Key('add-module-bottom')), findsNothing);
    expect(find.text('Aggiungi modulo'), findsOneWidget);
  });

  group('storico delle sessioni', () {
    test('intervalli: oggi compreso, da mezzanotte', () {
      final now = DateTime(2026, 10, 22, 15, 30);
      expect(SessionRange.today.from(now), DateTime(2026, 10, 22));
      expect(SessionRange.week.from(now), DateTime(2026, 10, 16));
      expect(SessionRange.days15.from(now), DateTime(2026, 10, 8));
      expect(SessionRange.days30.from(now), DateTime(2026, 9, 23));
      expect(SessionRange.days60.from(now), DateTime(2026, 8, 24));
      expect(SessionRange.months6.from(now), DateTime(2026, 4, 23));
      expect(SessionRange.year.from(now), DateTime(2025, 10, 23));
      expect(SessionRange.values.map((r) => r.label), [
        'Oggi',
        'Ultimi 7 giorni',
        'Ultimi 15 giorni',
        'Ultimi 30 giorni',
        'Ultimi 60 giorni',
        'Ultimi 6 mesi',
        'Ultimo anno',
      ]);
    });

    testWidgets('«Sessioni» con la casella dell\'intervallo (predefinito 7 '
        'giorni), «Aggiungi» allineato e icone delle attività', (tester) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(() => SessionHistory.range = SessionRange.week);
      SessionHistory.range = SessionRange.week;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 0, 5);
      final s = (await tester.runAsync(() async {
        final s = await _services();
        await s.courses.insert(const Course(id: 1, name: 'Analisi I'));
        for (final x in [
          _session(1, today, 30, activity: ActivityType.exercises, focus: true),
          _session(1, today.subtract(const Duration(days: 3)), 40),
          _session(
            1,
            today.subtract(const Duration(days: 10)),
            50,
            activity: ActivityType.reading,
          ),
          _session(1, today.subtract(const Duration(days: 100)), 60),
        ]) {
          await s.study.insertSession(x);
        }
        return s;
      }))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final catalog = CourseCatalog([
        const Course(id: 1, name: 'Analisi I'),
      ], const []);
      await tester.pumpWidget(
        _app(
          s,
          Scaffold(
            body: ListView(children: [SessionHistory(catalog: catalog)]),
          ),
        ),
      );
      await _settle(tester);

      expect(find.text('Sessioni'), findsOneWidget);
      expect(find.textContaining('ultimi 60 giorni'), findsNothing);
      expect(find.text('Ultimi 7 giorni'), findsOneWidget);
      expect(find.text('2 sessioni · 1 h 10 min'), findsOneWidget);

      // titolo, casella e «Aggiungi» sulla stessa riga, centrati
      final title = tester.getCenter(find.byKey(const Key('sessions-title')));
      final add = tester.getRect(find.byKey(const Key('session-add')));
      final range = tester.getRect(find.byKey(const Key('session-range')));
      expect((add.center.dy - title.dy).abs(), lessThan(1));
      expect((range.center.dy - title.dy).abs(), lessThan(1));
      expect(add.height, greaterThanOrEqualTo(44));
      expect(range.height, greaterThanOrEqualTo(44));

      // icona dell'attività per ogni sessione; Focus con il bollino
      expect(find.byIcon(Icons.edit_note_outlined), findsOneWidget);
      expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
      expect(find.byKey(const Key('session-focus-badge')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Sessione Focus, Esercizi')),
        findsOneWidget,
      );

      Future<void> choose(String label) async {
        await tester.tap(find.byKey(const Key('session-range')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last, warnIfMissed: false);
        await tester.pumpAndSettle();
        await _settle(tester);
      }

      await choose('Oggi');
      expect(find.text('1 sessione · 30 min'), findsOneWidget);
      await choose('Ultimi 15 giorni');
      expect(find.text('3 sessioni · 2 h'), findsOneWidget);
      expect(find.byIcon(Icons.auto_stories_outlined), findsOneWidget);
      await choose('Ultimo anno');
      expect(find.text('4 sessioni · 3 h'), findsOneWidget);
      // la scelta resta per la prossima apertura (finché l'app è aperta)
      expect(SessionHistory.range, SessionRange.year);
    });

    test('ogni attività ha la sua icona, diversa dalle altre', () {
      final icons = {for (final a in ActivityType.values) a.icon};
      expect(icons, hasLength(ActivityType.values.length));
      expect(ActivityType.theory.icon, Icons.menu_book_outlined);
      expect(ActivityType.exercises.icon, Icons.edit_note_outlined);
      expect(ActivityType.review.icon, Icons.replay);
    });
  });

  group('sessione Focus: modulo e file', () {
    final modules = [
      const StudyModule(id: 10, courseId: 1, name: 'Limiti'),
      const StudyModule(id: 20, courseId: 1, name: 'Derivate'),
    ];
    final topics = [
      const Topic(id: 100, moduleId: 10, name: 'Limiti notevoli'),
      const Topic(id: 101, moduleId: 10, name: 'Asintoti'),
      const Topic(id: 200, moduleId: 20, name: 'Regole'),
    ];
    Attachment file(int id, {int? module, int? topic}) => Attachment(
      id: id,
      moduleId: module,
      topicId: topic,
      title: 'File $id',
      path: '/non/esiste/$id.pdf',
      createdAt: DateTime(2026, 10, 1),
    );
    final attachments = [
      file(1, module: 10),
      file(2, topic: 100),
      file(3, topic: 101),
      file(4, topic: 200),
    ];

    test('argomento: prima i suoi file, poi il modulo e gli altri '
        'argomenti del modulo', () {
      final s = focusFileSections(
        modules: modules,
        topics: topics,
        attachments: attachments,
        topicId: 100,
      );
      expect(s.map((x) => x.title), [
        'Limiti notevoli',
        'Materiale del modulo',
        'Asintoti',
      ]);
      expect(s.first.current, isTrue);
      expect(s.expand((x) => x.files).map((a) => a.id), [2, 1, 3]);
    });

    test('modulo: materiale del modulo e argomenti; insegnamento: un '
        'gruppo per modulo', () {
      final m = focusFileSections(
        modules: modules,
        topics: topics,
        attachments: attachments,
        moduleId: 10,
      );
      expect(m.map((x) => x.title), [
        'Materiale del modulo',
        'Limiti notevoli',
        'Asintoti',
      ]);
      final c = focusFileSections(
        modules: modules,
        topics: topics,
        attachments: attachments,
      );
      expect(c.map((x) => x.title), ['Limiti', 'Derivate']);
      expect(c.first.files.map((a) => a.id), [1, 2, 3]);
    });

    Future<(AppServices, FocusLink)> seed() async {
      final s = await _services();
      final c = await s.courses.insert(const Course(name: 'Analisi I'));
      final m = await s.study.insertModule(
        StudyModule(courseId: c, name: 'Limiti e continuità'),
      );
      final t = await s.study.insertTopic(
        Topic(moduleId: m, name: 'Limiti notevoli'),
      );
      await s.study.insertAttachment(
        Attachment(
          topicId: t,
          title: 'Esercizi sui limiti',
          path: '/non/esiste/limiti.pdf',
          createdAt: DateTime(2026, 10, 1),
        ),
      );
      await s.study.insertAttachment(
        Attachment(
          moduleId: m,
          title: 'Dispense del modulo',
          path: '/non/esiste/dispense.pdf',
          createdAt: DateTime(2026, 10, 1),
        ),
      );
      return (
        s,
        FocusLink(
          courseId: c,
          moduleId: m,
          topicId: t,
          activity: ActivityType.exercises,
          label: 'Analisi I · Limiti notevoli',
        ),
      );
    }

    for (final (name, size) in [
      ('smartphone', const Size(420, 2000)),
      ('desktop', const Size(1400, 1000)),
    ]) {
      testWidgets('schermata su $name: insegnamento, modulo, argomento, '
          'attività e file apribili', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final (s, link) = (await tester.runAsync(seed))!;
        addTearDown(() => tester.runAsync(s.database.close));
        await tester.runAsync(
          () => s.focus.start(const FocusSettings(minutes: 30), link),
        );
        addTearDown(() => tester.runAsync(s.focus.discard));
        await tester.pumpWidget(_app(s, const FocusScreen()));
        await _settle(tester);

        expect(find.text('Sessione Focus'), findsOneWidget);
        expect(find.text('Analisi I'), findsOneWidget);
        expect(find.text('Limiti e continuità'), findsOneWidget);
        expect(find.text('Limiti notevoli'), findsWidgets);
        expect(find.text('Esercizi'), findsOneWidget);
        expect(find.byIcon(Icons.edit_note_outlined), findsOneWidget);
        expect(find.text('File del modulo'), findsOneWidget);
        expect(find.text('Esercizi sui limiti'), findsOneWidget);
        expect(find.text('Dispense del modulo'), findsOneWidget);

        // il timer resta il protagonista: l'anello sopra (telefono) o a
        // sinistra (desktop) dei file
        final ring = tester.getRect(find.byType(FocusRing));
        final files = tester.getRect(find.byKey(const Key('focus-files')));
        if (size.width >= 900) {
          expect(files.left, greaterThan(ring.right));
        } else {
          expect(files.top, greaterThan(ring.bottom));
        }

        // aprire un file non ferma la sessione (qui il file non c'è più:
        // l'avviso, e la sessione continua)
        await tester.ensureVisible(find.text('Dispense del modulo'));
        await tester.tap(find.text('Dispense del modulo'));
        await _settle(tester);
        expect(find.textContaining('non c\'è più'), findsOneWidget);
        expect(s.focus.active, isTrue);
        expect(s.focus.timer.paused, isFalse);
        expect(s.focus.screenVisible, isTrue);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('dal riquadro si torna alla schermata già aperta (niente '
        'doppioni)', (tester) async {
      final s = (await tester.runAsync(_services))!;
      addTearDown(() => tester.runAsync(s.database.close));
      await tester.runAsync(
        () => s.focus.start(
          const FocusSettings(minutes: 30),
          const FocusLink(label: 'Ripasso'),
        ),
      );
      addTearDown(() => tester.runAsync(s.focus.discard));
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        Provider<AppServices>.value(
          value: s,
          child: MaterialApp(
            navigatorKey: nav,
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );
      openFocusScreen(nav.currentContext!);
      await tester.pumpAndSettle();
      expect(find.byType(FocusScreen), findsOneWidget);
      // un file aperto sopra la sessione
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Lettore')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lettore'), findsOneWidget);
      openFocusScreen(nav.currentContext!);
      await tester.pumpAndSettle();
      expect(find.text('Lettore'), findsNothing);
      expect(find.byType(FocusScreen), findsOneWidget);
    });
  });

  testWidgets('Statistiche: niente percentuali per materia e argomento, '
      'argomenti per materia e grafici sui nuovi periodi', (tester) async {
    tester.view.physicalSize = const Size(420, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final s = (await tester.runAsync(() async {
      final s = await _services();
      await s.courses.insert(const Course(id: 1, name: 'Analisi I'));
      await s.courses.insert(const Course(id: 2, name: 'Fisica I'));
      final m1 = await s.study.insertModule(
        const StudyModule(courseId: 1, name: 'Limiti'),
      );
      final m2 = await s.study.insertModule(
        const StudyModule(courseId: 2, name: 'Cinematica'),
      );
      final t1 = await s.study.insertTopic(
        Topic(moduleId: m1, name: 'Limiti notevoli'),
      );
      final t2 = await s.study.insertTopic(
        Topic(moduleId: m2, name: 'Moto rettilineo'),
      );
      await s.study.insertSession(
        _session(1, now.subtract(const Duration(hours: 3)), 60, topic: t1),
      );
      await s.study.insertSession(
        _session(2, now.subtract(const Duration(hours: 2)), 30, topic: t2),
      );
      return s;
    }))!;
    addTearDown(() => tester.runAsync(s.database.close));
    final catalog = CourseCatalog([
      const Course(id: 1, name: 'Analisi I'),
      const Course(id: 2, name: 'Fisica I'),
    ], const []);
    await tester.pumpWidget(
      _app(s, Scaffold(body: StatsTab(catalog: catalog))),
    );
    await _settle(tester);

    for (final title in [
      'Giornaliero (ultimi 7 giorni)',
      'Mensile (ultime 4 settimane)',
      'Semestrale (ultimi 6 mesi)',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.textContaining('14 giorni'), findsNothing);
    expect(find.textContaining('Settimanale'), findsNothing);

    final pct = find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').endsWith('%'),
    );
    final topicCard = find.byKey(const Key('stats-by-topic'));
    final courseCard = find.byKey(const Key('stats-by-course'));
    expect(find.descendant(of: topicCard, matching: pct), findsNothing);
    expect(find.descendant(of: courseCard, matching: pct), findsNothing);
    // «Per attività» resta com'era (percentuale compresa)
    expect(
      find.descendant(
        of: find.byKey(const Key('stats-by-activity')),
        matching: pct,
      ),
      findsWidgets,
    );

    // argomenti: «Tutte le materie», poi una materia sola
    expect(
      find.descendant(of: topicCard, matching: find.text('Tutte le materie')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: topicCard, matching: find.text('Limiti notevoli')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: topicCard, matching: find.text('Moto rettilineo')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('stats-topic-course')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fisica I').last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: topicCard, matching: find.text('Limiti notevoli')),
      findsNothing,
    );
    expect(
      find.descendant(of: topicCard, matching: find.text('Moto rettilineo')),
      findsOneWidget,
    );
  });

  test('grafici: 7 giorni, 4 settimane, 6 mesi', () {
    final today = DateTime(2026, 10, 22);
    final sessions = [
      _session(1, DateTime(2026, 10, 22, 9), 30),
      _session(1, DateTime(2026, 10, 15, 9), 20), // 8 giorni fa
      _session(1, DateTime(2026, 9, 21, 9), 10), // 4 settimane fa (lunedì)
      _session(1, DateTime(2026, 5, 2, 9), 15),
    ];
    final d = dailyTotals(sessions, today: today, days: 7);
    expect(d, hasLength(7));
    expect(d.first.start, DateTime(2026, 10, 16));
    expect(d.map((x) => x.minutes).reduce((a, b) => a + b), 30);
    final w = weeklyTotals(sessions, today: today, weeks: 4);
    expect(w.map((x) => x.start), [
      DateTime(2026, 9, 28),
      DateTime(2026, 10, 5),
      DateTime(2026, 10, 12),
      DateTime(2026, 10, 19),
    ]);
    expect(w.map((x) => x.minutes), [0, 0, 20, 30]);
    final m = monthlyTotals(sessions, today: today, months: 6);
    expect(m.first.start, DateTime(2026, 5));
    expect(m.map((x) => x.minutes), [15, 0, 0, 0, 10, 50]);
  });
}
