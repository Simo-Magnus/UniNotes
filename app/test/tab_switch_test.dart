// Passaggio tra le sezioni principali (barra in basso, colonna di
// navigazione): sezioni persistenti (core/router/section_stack.dart) con la
// dissolvenza «fade through».
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/router/app_shell.dart';
import 'package:university_notes/core/router/section_stack.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/courses/courses_screen.dart';
import 'package:university_notes/features/dashboard/dashboard_screen.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/features/reader/files_screen.dart';
import 'package:university_notes/features/settings/settings_screen.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/widgets/common.dart';
import 'package:university_notes/widgets/section_active.dart';
import 'package:desktop_drop/desktop_drop.dart';

int _indexOf(String label) => kDestinations.indexWhere((d) => d.label == label);

Future<AppServices> _start(
  WidgetTester t, {
  Size size = const Size(400, 860),
  bool reduce = false,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final s = AppServices((await t.runAsync(AppDatabase.openInMemory))!);
  await t.pumpWidget(
    Provider<AppServices>.value(
      value: s,
      child: MaterialApp(
        locale: const Locale('it', 'IT'),
        supportedLocales: const [Locale('it', 'IT')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
          child: child!,
        ),
        home: const AppShell(),
      ),
    ),
  );
  await _settle(t);
  return s;
}

/// Caricamenti dal database (veri) e passaggio finito.
Future<void> _settle(WidgetTester t, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _finish(WidgetTester t, AppServices s) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 2));
  await t.runAsync(() => s.database.close());
}

Future<void> _tapNav(WidgetTester t, String label) async {
  await t.tap(
    find.descendant(of: find.byType(GlassNavBar), matching: find.text(label)),
  );
}

SectionStackState _stack(WidgetTester t) =>
    t.state<SectionStackState>(find.byType(SectionStack));

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  setUp(() => AppShell.prefetchSections = false);
  tearDown(() {
    AppShell.prefetchSections = true;
    StudyScreen.tabRequest.value = null;
  });

  testWidgets('tornando in una sezione già aperta: niente cerchio e niente '
      'ricostruzione', (t) async {
    final s = await _start(t);
    // prima apertura con un caricamento breve: nessun lampo del cerchio
    await _tapNav(t, 'Esami');
    await t.pump(const Duration(milliseconds: 16));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _settle(t);
    expect(find.byType(ExamsScreen), findsOneWidget);
    final exams = t.state(find.byType(ExamsScreen));

    await _tapNav(t, 'Home');
    await _settle(t);
    expect(find.byType(ExamsScreen), findsNothing);
    expect(find.byType(ExamsScreen, skipOffstage: false), findsOneWidget);

    await _tapNav(t, 'Esami');
    // nessun fotogramma con il cerchio o con la sezione vuota
    for (var i = 0; i < 16; i++) {
      await t.pump(const Duration(milliseconds: 16));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(DelayedSpinner), findsNothing);
    }
    // stessa schermata di prima (stato conservato)
    expect(identical(t.state(find.byType(ExamsScreen)), exams), isTrue);
    expect(t.takeException(), isNull);
    await _finish(t, s);
  });

  testWidgets('scheda interna e scorrimento restano', (t) async {
    final s = await _start(t);
    await _tapNav(t, 'Studio');
    await _settle(t);
    TabController tabs() => DefaultTabController.of(
      t.element(find.byType(TabBar, skipOffstage: false).first),
    );
    // le schede scorrono a 400 px: «Statistiche» è fuori dallo schermo
    tabs().index = 2;
    await _settle(t);
    expect(tabs().index, 2);

    // Impostazioni (lunga): scorre, si cambia sezione e si torna
    s.openRoute.call('sezione:Impostazioni');
    await _settle(t);
    final list = find.descendant(
      of: find.byType(SettingsScreen),
      matching: find.byType(Scrollable),
    );
    await t.drag(list.first, const Offset(0, -500));
    await _settle(t);
    double offset() => t
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(SettingsScreen, skipOffstage: false),
                matching: find.byType(Scrollable, skipOffstage: false),
              )
              .first,
        )
        .position
        .pixels;
    final before = offset();
    expect(before, greaterThan(100));

    await _tapNav(t, 'Studio');
    await _settle(t);
    expect(tabs().index, 2);
    s.openRoute.call('sezione:Impostazioni');
    await _settle(t);
    expect(offset(), before);

    // tocco sulla voce già attiva («Altro» → Impostazioni): torna in cima
    await _tapNav(t, 'Impostazioni');
    await _settle(t);
    await t.tap(find.widgetWithText(ListTile, 'Impostazioni'));
    await _settle(t, 8);
    expect(offset(), 0);
    expect(t.takeException(), isNull);
    await _finish(t, s);
  });

  testWidgets('dati aggiornati dopo revision.bump() con la sezione nascosta', (
    t,
  ) async {
    final s = await _start(t);
    s.openRoute.call('sezione:Insegnamenti');
    await _settle(t);
    expect(find.byType(CoursesScreen), findsOneWidget);
    await _tapNav(t, 'Home');
    await _settle(t);

    await t.runAsync(() => s.courses.insert(const Course(name: 'Analisi I')));
    s.revision.bump();
    await _settle(t);
    Finder inCourses(bool offstage) => find.descendant(
      of: find.byType(CoursesScreen, skipOffstage: !offstage),
      matching: find.text('Analisi I', skipOffstage: !offstage),
    );
    // nascosta: nessun lavoro finché non torna visibile
    expect(inCourses(true), findsNothing);

    s.openRoute.call('sezione:Insegnamenti');
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _settle(t);
    expect(inCourses(false), findsWidgets);
    expect(t.takeException(), isNull);
    await _finish(t, s);
  });

  testWidgets('passaggio animato (dissolvenza), istantaneo con «Riduci '
      'animazioni»', (t) async {
    var s = await _start(t);
    await _tapNav(t, 'Esami');
    await t.pump();
    await t.pump(const Duration(milliseconds: 40));
    expect(_stack(t).switching, isTrue);
    // la Home sta sparendo, Esami non si vede ancora
    double opacityOf(Type screen) => t
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(screen),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    expect(opacityOf(DashboardScreen), inExclusiveRange(0, 1));
    expect(opacityOf(ExamsScreen), 0);
    await t.pump(const Duration(milliseconds: 120));
    // ora entra Esami (la Home è sparita)
    expect(opacityOf(DashboardScreen), 0);
    expect(opacityOf(ExamsScreen), inExclusiveRange(0, 1));
    await t.pump(kSectionSwitchDuration);
    expect(_stack(t).switching, isFalse);
    expect(find.byType(DashboardScreen), findsNothing);
    expect(opacityOf(ExamsScreen), 1);
    await _finish(t, s);

    s = await _start(t, reduce: true);
    await _tapNav(t, 'Esami');
    await t.pump();
    expect(_stack(t).switching, isFalse);
    expect(find.byType(DashboardScreen), findsNothing);
    expect(find.byType(ExamsScreen), findsOneWidget);
    await _finish(t, s);
  });

  testWidgets('sezioni nascoste: niente animazioni, fuoco, tocchi né '
      'trascinamento dei file', (t) async {
    final s = await _start(t, size: const Size(1280, 800));
    Future<void> rail(String label) async {
      await t.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text(label),
        ),
      );
      await _settle(t);
    }

    await rail('Esami');
    await rail('File');
    await rail('Home');
    for (final type in [ExamsScreen, FilesScreen]) {
      final e = t.element(find.byType(type, skipOffstage: false));
      expect(TickerMode.valuesOf(e).enabled, isFalse, reason: '$type');
      expect(SectionActive.of(e), isFalse);
    }
    final home = t.element(find.byType(DashboardScreen));
    expect(TickerMode.valuesOf(home).enabled, isTrue);
    // la sezione File nascosta non prende i file trascinati sulla finestra
    for (final d in t.widgetList<DropTarget>(
      find.descendant(
        of: find.byType(FilesScreen, skipOffstage: false),
        matching: find.byType(DropTarget, skipOffstage: false),
      ),
    )) {
      expect(d.enable, isFalse);
    }
    // la colonna di navigazione resta la stessa pila passando alla barra in
    // basso (finestra ristretta): niente ricostruzione
    final exams = t.state(find.byType(ExamsScreen, skipOffstage: false));
    t.view.physicalSize = const Size(400, 860);
    await _settle(t);
    expect(
      identical(t.state(find.byType(ExamsScreen, skipOffstage: false)), exams),
      isTrue,
    );
    expect(t.takeException(), isNull);
    await _finish(t, s);
  });

  // Trovato dalla scimmia: pressione lunga su un filtro di Insegnamenti
  // (suggerimento aperto nell'Overlay), poi «Home»: il suggerimento restava
  // sopra la Home, fermo (animazioni spente nella sezione nascosta), e con i
  // caratteri cambiati il suo testo si disegnava con misure vecchie.
  testWidgets('un suggerimento aperto sparisce cambiando sezione', (t) async {
    final s = await _start(t, size: const Size(1024, 768));
    // con un insegnamento compaiono i filtri (con i suggerimenti)
    await t.runAsync(() => s.courses.insert(const Course(name: 'Analisi I')));
    s.openRoute.call('sezione:Insegnamenti');
    await _settle(t);
    final tips = t
        .widgetList<Tooltip>(
          find.descendant(
            of: find.byType(CoursesScreen),
            matching: find.byType(Tooltip),
          ),
        )
        .where((w) => (w.message ?? '').isNotEmpty)
        .toList();
    expect(tips, isNotEmpty);
    final msg = tips.first.message!;
    // testi [msg] che si disegnano davvero: il suggerimento sta nell'Overlay,
    // fuori dalla sezione (nell'albero degli elementi invece è dentro, quindi
    // i Finder lo saltano come «offstage» con la sezione nascosta)
    int painted() {
      var n = 0;
      for (final e in find.text(msg, skipOffstage: false).evaluate()) {
        RenderObject? r = e.renderObject;
        var hidden = false;
        while (r != null) {
          if (r is RenderOffstage && r.offstage) hidden = true;
          r = r.parent;
        }
        if (!hidden) n++;
      }
      return n;
    }

    final before = painted();
    await t.longPress(find.byWidget(tips.first));
    await t.pump(const Duration(milliseconds: 300));
    expect(painted(), greaterThan(before));

    s.openRoute.call('sezione:Home');
    await _settle(t);
    expect(painted(), 0);
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await _settle(t);
    expect(t.takeException(), isNull);
    await _finish(t, s);
  });

  testWidgets('notifica Focus: Studio → Sessioni Studio anche con Studio già '
      'costruita', (t) async {
    final s = await _start(t);
    await _tapNav(t, 'Studio');
    await _settle(t);
    TabController tabs() => DefaultTabController.of(
      t.element(find.byType(TabBar, skipOffstage: false).first),
    );
    expect(tabs().index, 0);
    await _tapNav(t, 'Home');
    await _settle(t);

    s.openRoute.call(AppRoutes.focus);
    await _settle(t);
    expect(find.byType(StudyScreen), findsOneWidget);
    expect(tabs().index, StudyScreen.focusTab);
    expect(StudyScreen.tabRequest.value, isNull);
    expect(t.takeException(), isNull);
    await _finish(t, s);
  });

  testWidgets('anno o corso cambiati: le sezioni nascoste si ricreano', (
    t,
  ) async {
    final s = await _start(t);
    await _tapNav(t, 'Esami');
    await _settle(t);
    await _tapNav(t, 'Studio');
    await _settle(t);
    await _tapNav(t, 'Home');
    await _settle(t);
    expect(_stack(t).builtSections, containsAll([0, 2, 3]));
    final exams = t.state(find.byType(ExamsScreen, skipOffstage: false));

    s.selectedYear.value = 2;
    await _settle(t);
    expect(_stack(t).builtSections, {0});
    expect(find.byType(DashboardScreen), findsOneWidget);

    await _tapNav(t, 'Esami');
    await _settle(t);
    expect(identical(t.state(find.byType(ExamsScreen)), exams), isFalse);
    expect(t.takeException(), isNull);
    await _finish(t, s);
  });

  testWidgets('dopo l\'avvio si preparano nascoste le sezioni della barra', (
    t,
  ) async {
    AppShell.prefetchSections = true;
    final s = await _start(t);
    expect(_stack(t).builtSections, {0});
    for (var i = 0; i < 12; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 500));
    }
    expect(_stack(t).builtSections, {
      0,
      _indexOf('Registra'),
      _indexOf('Studio'),
      _indexOf('Esami'),
    });
    // nascoste: si vede solo la Home
    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.byType(ExamsScreen), findsNothing);
    // la prima apertura è già pronta: niente cerchio
    await _tapNav(t, 'Esami');
    for (var i = 0; i < 16; i++) {
      await t.pump(const Duration(milliseconds: 16));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }
    expect(t.takeException(), isNull);
    await _finish(t, s);
  });
}
