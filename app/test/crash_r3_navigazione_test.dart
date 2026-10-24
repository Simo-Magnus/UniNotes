import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/system_calendar.dart';
import 'package:university_notes/core/router/safe_pop.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/day_watcher.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/academic/year_grades_screen.dart';
import 'package:university_notes/features/cloud/google_drive_client.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/courses/course_form.dart';
import 'package:university_notes/features/courses/course_list.dart';
import 'package:university_notes/features/dashboard/dashboard_data.dart';
import 'package:university_notes/features/exams/exam_form.dart';
import 'package:university_notes/features/settings/erase_all.dart';
import 'package:university_notes/features/settings/logic/data_eraser.dart';
import 'package:university_notes/features/study/course_catalog.dart';
import 'package:university_notes/features/study/focus/focus_screen.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_reminders.dart';
import 'support/plan_services.dart';

/// Terzo giro della caccia ai crash, categoria «navigazione e stato
/// dell'app nel tempo»: Indietro (o una pagina aperta da una notifica)
/// durante un salvataggio, pagine aperte due volte, letture bloccate da una
/// scrittura non riuscita, orologi avanti fra dispositivi, giorno che cambia
/// con l'app aperta.

/// Le letture (SQLite, file) avvengono fuori dal tempo finto: si alternano
/// attese reali e ridisegni finché i caricamenti a catena sono finiti.
Future<void> _settle(WidgetTester tester, [int rounds = 60]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Attese reali lunghe con il tempo finto quasi fermo: il salvataggio
/// finisce mentre la pagina sta ancora uscendo (animazione di 300 ms).
Future<void> _finishDuringExit(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Widget _app(AppServices? s, Widget home) {
  final app = MaterialApp(
    theme: AppTheme.dark(),
    locale: const Locale('it', 'IT'),
    supportedLocales: const [Locale('it', 'IT')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
  return s == null ? app : Provider<AppServices>.value(value: s, child: app);
}

/// Prima pagina: apre «Pagina sotto», da cui si apre il modulo. Una
/// chiusura di troppo toglierebbe «Pagina sotto» (e si tornerebbe qui).
class _Root extends StatelessWidget {
  const _Root(this.open);
  final Future<void> Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () =>
            Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => _Below(open))),
        child: const Text('Radice'),
      ),
    ),
  );
}

class _Below extends StatelessWidget {
  const _Below(this.open);
  final Future<void> Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => open(context),
        child: const Text('Pagina sotto'),
      ),
    ),
  );
}

/// Eliminazione che finisce quando lo decide il test.
class _GatedEraser extends DataEraser {
  _GatedEraser(super.s, this.done);
  final Future<EraseReport> done;

  @override
  Future<EraseReport> run(
    Set<EraseItem> items, {
    void Function(String step)? onStep,
  }) => done;
}

/// Radice → «Pagina sotto» → pagina aperta da [open].
Future<void> _openStack(
  WidgetTester tester,
  AppServices? s,
  Future<void> Function(BuildContext context) open,
) async {
  await tester.pumpWidget(_app(s, _Root(open)));
  await tester.tap(find.text('Radice'));
  await _settle(tester, 10);
  await tester.tap(find.text('Pagina sotto'));
  await _settle(tester, 20);
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  group('Indietro durante il salvataggio', () {
    testWidgets('nuovo insegnamento: la pagina sotto resta', (tester) async {
      final s = (await tester.runAsync(planServices))!;
      addTearDown(() => tester.runAsync(s.database.close));
      await _openStack(tester, s, (c) => openCourseForm(c));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome dell\'insegnamento *'),
        'Laboratorio di prova',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Salva'));
      // Indietro (tasto di Android, Esc) con il salvataggio in corso
      await tester.binding.handlePopRoute();
      await _finishDuringExit(tester);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Pagina sotto'), findsOneWidget);
      final all = (await tester.runAsync(s.courses.all))!;
      expect(all.where((c) => c.name == 'Laboratorio di prova'), hasLength(1));
    });

    testWidgets('voti dell\'anno: la pagina sotto resta', (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(planServices))!;
      addTearDown(() => tester.runAsync(s.database.close));
      await _openStack(
        tester,
        s,
        (c) => Navigator.of(c).push(
          MaterialPageRoute<void>(
            builder: (_) => const YearGradesScreen(year: 1, markYear: false),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('grades-save')));
      await tester.binding.handlePopRoute();
      await _finishDuringExit(tester);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Pagina sotto'), findsOneWidget);
    });

    testWidgets('modulo della prova: la pagina sotto resta', (tester) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(planServices))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final exam = (await tester.runAsync(() async {
        final courses = await s.courses.all();
        final id = await s.exams.save(
          Exam(courseId: courses.first.id!, kind: ExamKind.midterm),
        );
        return s.exams.byId(id);
      }))!;
      await _openStack(tester, s, (c) => openExamForm(c, exam: exam));
      final save = find.widgetWithText(FilledButton, 'Salva');
      await tester.ensureVisible(save);
      await tester.pump();
      await tester.tap(save);
      await tester.binding.handlePopRoute();
      await _finishDuringExit(tester);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Pagina sotto'), findsOneWidget);
    });
  });

  testWidgets(
    'pagina aperta sopra durante il salvataggio (notifica): resta lei, il '
    'modulo si toglie',
    (tester) async {
      final s = (await tester.runAsync(planServices))!;
      addTearDown(() => tester.runAsync(s.database.close));
      await _openStack(tester, s, (c) => openCourseForm(c));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome dell\'insegnamento *'),
        'Laboratorio di prova',
      );
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      await tester.tap(find.widgetWithText(TextButton, 'Salva'));
      // come il tocco su una notifica: dettaglio aperto sopra a tutto
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Dettaglio prova')),
          ),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Dettaglio prova'), findsOneWidget);
      expect(find.byType(CourseFormPage), findsNothing);
      nav.pop();
      await _settle(tester, 14);
      expect(find.text('Pagina sotto'), findsOneWidget);
    },
  );

  group('popIfCurrent', () {
    Future<BuildContext> pushPage(WidgetTester tester) async {
      late BuildContext page;
      await _openStack(
        tester,
        null,
        (c) => Navigator.of(c).push(
          MaterialPageRoute<void>(
            builder: (ctx) {
              page = ctx;
              return const Scaffold(body: Text('Modulo'));
            },
          ),
        ),
      );
      return page;
    }

    testWidgets('in cima: chiude la pagina', (tester) async {
      final page = await pushPage(tester);
      expect(popIfCurrent(page), isTrue);
      await _settle(tester, 14);
      expect(find.text('Modulo'), findsNothing);
      expect(find.text('Pagina sotto'), findsOneWidget);
    });

    testWidgets('già in chiusura (Indietro): non chiude quella sotto', (
      tester,
    ) async {
      final page = await pushPage(tester);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 16));
      expect(page.mounted, isTrue); // animazione d'uscita
      expect(popIfCurrent(page), isFalse);
      await _settle(tester, 14);
      expect(find.text('Pagina sotto'), findsOneWidget);
    });

    testWidgets('pagina aperta sopra: toglie solo la propria', (tester) async {
      final page = await pushPage(tester);
      unawaited(
        Navigator.of(page).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Sopra')),
          ),
        ),
      );
      await _settle(tester, 14);
      expect(popIfCurrent(page), isTrue);
      await _settle(tester, 14);
      expect(find.text('Sopra'), findsOneWidget);
      Navigator.of(tester.element(find.text('Sopra'))).pop();
      await _settle(tester, 14);
      expect(find.text('Modulo'), findsNothing);
      expect(find.text('Pagina sotto'), findsOneWidget);
    });
  });

  testWidgets('Focus: due richieste nello stesso fotogramma (tocco sul '
      'riquadro e notifica) aprono una sola schermata', (tester) async {
    final s = (await tester.runAsync(planServices))!;
    addTearDown(() => tester.runAsync(s.database.close));
    await tester.pumpWidget(
      _app(
        s,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                unawaited(openFocusScreen(context));
                unawaited(openFocusScreen(context));
              },
              child: const Text('Focus'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Focus'));
    await _settle(tester, 10);
    expect(tester.takeException(), isNull);
    expect(find.byType(FocusScreen, skipOffstage: false), findsOneWidget);
  });

  group('scrittura degli stati degli insegnamenti non riuscita', () {
    test(
      'le schermate leggono lo stesso (Home, Insegnamenti, Studio…)',
      () async {
        final s = await planServices();
        addTearDown(s.database.close);
        final db = s.database.db;
        // stati da aggiornare (nessun esame superato) e scrittura bloccata,
        // come con il disco pieno o il database in sola lettura
        await db.execute("UPDATE courses SET status = 'completed'");
        await db.execute(
          'CREATE TRIGGER r3_no_write BEFORE UPDATE ON courses '
          "BEGIN SELECT RAISE(ABORT, 'disco pieno'); END",
        );
        final catalog = await CourseCatalog.load(s);
        expect(catalog.courses, isNotEmpty);
        final list = await CoursesData.load(s);
        expect(list.courses, isNotEmpty);
        await DashboardData.load(s);
      },
    );
  });

  group('calendario: orologio avanti su un altro dispositivo', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late FakeCalendarBackend backend;
    final now = DateTime(2027, 1, 5, 10);

    setUp(() async {
      db = await AppDatabase.openInMemory();
      settings = SettingsRepository(db);
      backend = FakeCalendarBackend();
    });
    tearDown(() => db.close());

    SystemCalendarSync syncFor(String install) => SystemCalendarSync(
      settings,
      backend,
      device: CalendarDevice(installId: () async => install, name: 'telefono'),
    );

    test('il segno nel futuro invecchia da adesso: dopo 3 settimane si '
        'subentra', () async {
      final items = [examItem(1, DateTime(2027, 2, 10))];
      final phone = syncFor('aa1111');
      await phone.setEnabled(true);
      // il telefono ha l'orologio avanti di un anno
      await phone.sync(items, const [
        1,
      ], now: now.add(const Duration(days: 365)));
      final tablet = syncFor('bb2222');
      var st = await tablet.sync(items, const [1], now: now);
      // per ora scrive ancora il telefono
      expect(st.writtenBy, 'telefono aa1111');
      // il telefono non si sente più: dopo tre settimane scrive il tablet
      st = await tablet.sync(items, const [
        1,
      ], now: now.add(kCalendarWriterStale + const Duration(days: 1)));
      expect(st.writtenBy, isNull);
      final raw = jsonDecode((await settings.get(CalendarKeys.writers))!);
      expect('$raw', contains('bb2222'));
    });

    test('il proprio segno nel futuro (orologio rimesso a posto) si '
        'rinnova', () async {
      final items = [examItem(1, DateTime(2027, 2, 10))];
      final phone = syncFor('aa1111');
      await phone.setEnabled(true);
      await phone.sync(items, const [
        1,
      ], now: now.add(const Duration(days: 365)));
      await phone.sync(items, const [1], now: now);
      final w = (await phone.writers()).values.single;
      expect(w.install, 'aa1111');
      expect(w.at.isAfter(now.add(const Duration(days: 1))), isFalse);
    });
  });

  group('token rifiutato prima della scadenza segnata (401)', () {
    // token «valido» per l'app ma rifiutato dal servizio: si dimentica e la
    // richiesta si ripete con uno nuovo
    late List<String> sent;
    late String current;
    var forgotten = 0;
    Future<GraphResponse> transport(
      String method,
      Uri url, {
      Map<String, String> headers = const {},
      List<int>? body,
    }) async {
      sent.add(headers['Authorization'] ?? '');
      return headers['Authorization'] == 'Bearer nuovo'
          ? GraphResponse(200, Uint8List.fromList(utf8.encode('{}')))
          : GraphResponse(401, Uint8List.fromList(utf8.encode('{}')));
    }

    setUp(() {
      sent = [];
      current = 'vecchio';
      forgotten = 0;
    });

    void forget() {
      forgotten++;
      current = 'nuovo';
    }

    test('OneDrive (Graph)', () async {
      final g = GraphClient(
        () async => current,
        transport: transport,
        onUnauthorized: forget,
      );
      final r = await g.request('GET', 'me/drive');
      expect(r.status, 200);
      expect(sent, ['Bearer vecchio', 'Bearer nuovo']);
      expect(forgotten, 1);
    });

    test('Google Drive', () async {
      final d = GoogleDriveClient(
        () async => current,
        transport: transport,
        onUnauthorized: forget,
      );
      final r = await d.request('GET', d.url('files'));
      expect(r.status, 200);
      expect(sent, ['Bearer vecchio', 'Bearer nuovo']);
    });

    test('rifiutato anche il nuovo: errore, una sola ripetizione', () async {
      final g = GraphClient(
        () async => 'sempre-vecchio',
        transport: transport,
        onUnauthorized: () => forgotten++,
      );
      await expectLater(g.request('GET', 'me/drive'), throwsA(anything));
      expect(sent, hasLength(2));
    });
  });

  testWidgets(
    'eliminazione dei dati: pagina aperta sopra durante l\'attesa, il '
    'riquadro si chiude lo stesso',
    (tester) async {
      final s = (await tester.runAsync(planServices))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final gate = Completer<EraseReport>();
      late Future<EraseReport> run;
      await _openStack(tester, s, (c) async {
        run = runEraseWithProgress(c, _GatedEraser(s, gate.future), const {});
      });
      expect(find.text('Elimino i dati…'), findsOneWidget);
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Dettaglio prova')),
          ),
        ),
      );
      await _settle(tester, 14);
      gate.complete(EraseReport());
      await _settle(tester, 14);
      await run;
      expect(tester.takeException(), isNull);
      expect(find.text('Dettaglio prova'), findsOneWidget);
      nav.pop();
      await _settle(tester, 14);
      expect(find.text('Elimino i dati…'), findsNothing);
      expect(find.text('Pagina sotto'), findsOneWidget);
    },
  );

  group('giorno che cambia con l\'app aperta', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('a mezzanotte le schermate si aggiornano', () {
      fakeAsync((async) {
        final start = DateTime(2027, 3, 1, 23, 50);
        var days = 0;
        final w = DayWatcher(
          () => days++,
          clock: () => start.add(async.elapsed),
        )..start();
        async.elapse(const Duration(minutes: 5));
        expect(days, 0);
        async.elapse(const Duration(minutes: 6));
        expect(days, 1);
        // il giorno dopo ancora una volta sola
        async.elapse(const Duration(hours: 24));
        expect(days, 2);
        w.dispose();
      });
    });

    test('ripresa dopo giorni (timer fermi in background)', () {
      var t = DateTime(2027, 3, 1, 9);
      var days = 0;
      final w = DayWatcher(() => days++, clock: () => t)..start();
      expect(w.check(), isFalse);
      t = DateTime(2027, 3, 4, 8);
      expect(w.check(), isTrue);
      expect(days, 1);
      expect(w.check(), isFalse);
      w.dispose();
    });
  });
}
