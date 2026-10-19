import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/notes/recorder/overlay_logic.dart';
import 'package:university_notes/features/notes/recorder/recording_overlay.dart';
import 'package:university_notes/features/study/focus/focus_goal.dart';
import 'package:university_notes/features/study/focus/focus_plan.dart';
import 'package:university_notes/features/study/focus/focus_quiet_section.dart';
import 'package:university_notes/features/study/focus/focus_screen.dart';
import 'package:university_notes/features/study/focus/focus_service.dart';
import 'package:university_notes/features/study/focus/focus_system.dart';
import 'package:university_notes/features/study/focus/focus_timer.dart';
import 'package:university_notes/models/study.dart';

const _min = Duration(minutes: 1);

List<String> _plan(int total, {int every = 30, int rest = 5, bool on = true}) =>
    buildFocusPlan(
      FocusSettings(
        minutes: total,
        breaks: on,
        breakEvery: every,
        breakMinutes: rest,
      ),
    ).map((s) => s.toString()).toList();

StudySession _session(DateTime start, int minutes, {bool focus = false}) =>
    StudySession(start: start, durationMinutes: minutes, focus: focus);

void main() {
  group('piano della sessione', () {
    test('pause automatiche come in Windows', () {
      expect(_plan(60), ['focus 30m', 'pausa 5m', 'focus 25m']);
      expect(_plan(45), ['focus 30m', 'pausa 5m', 'focus 10m']);
      expect(_plan(30), ['focus 30m']);
      // l'ultimo tratto di lavoro non è mai più corto di 5 minuti
      expect(_plan(38), ['focus 38m']);
      expect(_plan(120, every: 25, rest: 5), [
        'focus 25m',
        'pausa 5m',
        'focus 25m',
        'pausa 5m',
        'focus 25m',
        'pausa 5m',
        'focus 30m',
      ]);
      expect(_plan(90, on: false), ['focus 90m']);
    });

    test('durata totale, concentrazione e pause', () {
      final p = buildFocusPlan(const FocusSettings(minutes: 100));
      expect(planLength(p), const Duration(minutes: 100));
      expect(planFocusMinutes(p), 90);
      expect(planBreaks(p), 2);
      expect(describePlan(p), '2 pause da 5 min');
      expect(
        describePlan(buildFocusPlan(const FocusSettings(minutes: 20))),
        'Nessuna pausa',
      );
    });

    test('posizione nel tempo', () {
      final p = buildFocusPlan(const FocusSettings(minutes: 60));
      final a = positionAt(p, const Duration(minutes: 10));
      expect(a.phase, FocusPhase.focus);
      expect(a.index, 0);
      expect(a.segmentRemaining, const Duration(minutes: 20));
      expect(a.totalRemaining, const Duration(minutes: 50));
      expect(a.breaksLeft, 1);

      final b = positionAt(p, const Duration(minutes: 32));
      expect(b.phase, FocusPhase.rest);
      expect(b.segmentRemaining, const Duration(minutes: 3));
      expect(b.focusDone, const Duration(minutes: 30));
      expect(b.breaksLeft, 0);

      final c = positionAt(p, const Duration(minutes: 61));
      expect(c.finished, isTrue);
      expect(c.focusDone, const Duration(minutes: 55));
    });

    test('confini dei tratti per gli avvisi', () {
      final p = buildFocusPlan(const FocusSettings(minutes: 60));
      expect(boundariesAfter(p, const Duration(minutes: 31)), [
        (1, const Duration(minutes: 35)),
        (2, const Duration(minutes: 60)),
      ]);
    });

    test('impostazioni salvate: valori fuori misura → predefiniti', () {
      const s = FocusSettings(minutes: 90, breakEvery: 45, breakMinutes: 10);
      expect(FocusSettings.fromJson(s.toJson()), s);
      expect(
        FocusSettings.fromJson({'minuti': 999, 'ogni': 2, 'pausa': 0}),
        const FocusSettings(),
      );
      expect(FocusSettings.fromJson('rotto'), const FocusSettings());
    });

    test('tempo restante', () {
      expect(formatCountdown(const Duration(minutes: 25)), '25:00');
      expect(
        formatCountdown(const Duration(seconds: 61, milliseconds: 1)),
        '01:02',
      );
      expect(
        formatCountdown(const Duration(hours: 1, minutes: 5, seconds: 9)),
        '1:05:09',
      );
      expect(formatCountdown(-_min), '00:00');
      expect(formatFocusLength(90), '1 h 30 min');
      expect(formatFocusLength(120), '2 h');
    });
  });

  group('timer Focus', () {
    late DateTime now;
    late FocusTimer timer;
    late List<FocusEventKind> events;

    setUp(() {
      now = DateTime(2026, 10, 12, 9);
      timer = FocusTimer(clock: () => now, tick: false);
      events = [];
      timer.events.listen(events.add);
    });

    tearDown(() => timer.dispose());

    test('pause automatiche, salta pausa, pausa manuale e fine', () async {
      timer.start(const FocusSettings(minutes: 60));
      expect(timer.endsAt, DateTime(2026, 10, 12, 10));
      now = now.add(const Duration(minutes: 31));
      timer.check();
      await Future<void>.delayed(Duration.zero);
      expect(events, [FocusEventKind.started, FocusEventKind.breakStarted]);
      expect(timer.position.phase, FocusPhase.rest);

      // salta pausa: si riparte subito, la sessione finisce 4 minuti prima
      expect(timer.skipBreak(), isTrue);
      expect(timer.position.phase, FocusPhase.focus);
      expect(timer.position.index, 2);
      expect(timer.endsAt, DateTime(2026, 10, 12, 9, 56));
      expect(timer.skipBreak(), isFalse);

      // pausa manuale: il tempo si ferma
      now = now.add(const Duration(minutes: 5));
      timer.pause();
      final left = timer.position.totalRemaining;
      now = now.add(const Duration(minutes: 30));
      expect(timer.position.totalRemaining, left);
      expect(timer.paused, isTrue);
      timer.resume();

      now = now.add(const Duration(minutes: 30));
      timer.check();
      await Future<void>.delayed(Duration.zero);
      expect(events.last, FocusEventKind.finished);
      expect(timer.finished, isTrue);

      final r = timer.stop()!;
      expect(r.completed, isTrue);
      expect(r.focusMinutes, 55);
      expect(r.plannedMinutes, 60);
      expect(r.start, DateTime(2026, 10, 12, 9));
      expect(timer.active, isFalse);
    });

    test('fermata prima della fine: conta solo la concentrazione', () {
      timer.start(const FocusSettings(minutes: 60));
      now = now.add(const Duration(minutes: 33)); // 30 focus + 3 di pausa
      final r = timer.stop()!;
      expect(r.completed, isFalse);
      expect(r.focusMinutes, 30);
      expect(r.end, DateTime(2026, 10, 12, 9, 33));
    });

    test('ripresa dopo la chiusura dell\'app', () {
      timer.start(const FocusSettings(minutes: 45));
      now = now.add(const Duration(minutes: 10));
      final saved = timer.toJson();
      timer.discard();

      final again = FocusTimer(clock: () => now, tick: false);
      // l'app è rimasta chiusa 5 minuti: il tempo è andato avanti
      now = now.add(const Duration(minutes: 5));
      expect(again.restore(saved), isTrue);
      expect(again.position.focusDone, const Duration(minutes: 15));
      expect(again.running, isTrue);

      // sessione finita ad app chiusa: la fine è quella prevista
      now = now.add(const Duration(hours: 2));
      final r = again.stop()!;
      expect(r.completed, isTrue);
      expect(r.end, DateTime(2026, 10, 12, 9, 45));
      expect(r.focusMinutes, 40);
      again.dispose();
      expect(FocusTimer(tick: false).restore({'x': 1}), isFalse);
    });
  });

  group('obiettivo giornaliero e serie', () {
    final today = DateTime(2026, 10, 12, 18);
    DateTime day(int d) => DateTime(2026, 10, d, 9);

    test('minuti per giorno e serie fino a oggi o a ieri', () {
      final sessions = [
        _session(day(9), 70),
        _session(day(10), 30),
        _session(day(10), 40, focus: true),
        _session(day(11), 60),
        _session(day(12), 20),
      ];
      final perDay = minutesPerDay(sessions);
      expect(perDay[DateTime(2026, 10, 10)], 70);
      // oggi 20 minuti su 60: la serie arriva a ieri (3 giorni)
      expect(goalStreak(perDay, today: today, goal: 60), 3);
      // con un obiettivo da 20 minuti conta anche oggi
      expect(goalStreak(perDay, today: today, goal: 20), 4);
      // un giorno sotto l'obiettivo interrompe la serie
      expect(goalStreak(perDay, today: today, goal: 65), 0);
      expect(bestStreak(perDay, goal: 60), 3);
      expect(goalStreak(const {}, today: today, goal: 60), 0);
    });

    test('serie più lunga anche a cavallo del mese', () {
      final perDay = minutesPerDay([
        _session(DateTime(2026, 9, 29), 60),
        _session(DateTime(2026, 9, 30), 60),
        _session(DateTime(2026, 10, 1), 60),
        _session(DateTime(2026, 10, 5), 60),
      ]);
      expect(bestStreak(perDay, goal: 60), 3);
    });

    test('avanzamento, testo e obiettivo salvato', () {
      expect(goalProgress(30, 60), 0.5);
      expect(goalProgress(90, 60), 1);
      expect(goalCaption(45, 60), 'Ancora 15 min');
      expect(goalCaption(60, 60), 'Obiettivo raggiunto');
      expect(parseDailyGoal('90'), 90);
      expect(parseDailyGoal('3'), kDefaultDailyGoal);
      expect(parseDailyGoal(null), kDefaultDailyGoal);
      expect(streakLabel(1), '1 giorno');
      expect(streakLabel(4), '4 giorni');
    });

    test('statistiche Focus della settimana', () {
      // mercoledì 14 ottobre: la settimana inizia lunedì 12
      final stats = FocusStats.of(
        [
          _session(day(14), 25, focus: true),
          _session(day(14), 50),
          _session(day(13), 55, focus: true),
          _session(day(11), 60, focus: true), // settimana precedente
        ],
        goal: 60,
        today: DateTime(2026, 10, 14, 18),
      );
      expect(stats.today, 75);
      expect(stats.progress, 1);
      expect(stats.focusToday, 25);
      expect(stats.focusWeek, 80);
      expect(stats.focusSessionsWeek, 2);
    });
  });

  group('Non disturbare dell\'app', () {
    final now = DateTime(2026, 10, 12, 9);
    final quiet = DateTime(2026, 10, 12, 11);

    PlannedNotification n(NotificationType t, DateTime at) =>
        PlannedNotification(
          id: notificationId(t, '$at'),
          type: t,
          at: at,
          title: 't',
          body: 'b',
          payload: 'p',
        );

    test('gli avvisi non urgenti aspettano la fine della sessione', () {
      final link = quietAware(n(NotificationType.link, now), quiet);
      expect(link.at, quiet.add(_min));
      final review = quietAware(
        n(NotificationType.review, DateTime(2026, 10, 12, 10)),
        quiet,
      );
      expect(review.at, quiet.add(_min));
      // urgenti: al loro posto
      final exam = n(NotificationType.exam, DateTime(2026, 10, 12, 10));
      expect(quietAware(exam, quiet).at, exam.at);
      // dopo la fine o senza sessione: invariati
      final later = n(NotificationType.outcome, DateTime(2026, 10, 12, 18));
      expect(quietAware(later, quiet).at, later.at);
      expect(quietAware(link, null).at, link.at);
    });

    test('pianificazione con una sessione in corso', () {
      final plan = planNotifications(
        now: now,
        prefs: const NotificationPrefs(consent: true),
        agenda: const [],
        outcomes: [
          OutcomeCandidate(
            examId: 3,
            subject: 'Analisi',
            midterm: false,
            // «Com'è andata?» alle 18 del giorno dopo la prova
            date: DateTime(2026, 10, 11),
          ),
        ],
        quietUntil: DateTime(2026, 10, 12, 19),
      );
      expect(plan.single.type, NotificationType.outcome);
      expect(plan.single.at, DateTime(2026, 10, 12, 19, 1));
    });

    test('tipi urgenti', () {
      expect(NotificationType.exam.urgent, isTrue);
      expect(NotificationType.focusAlert.urgent, isTrue);
      expect(NotificationType.outcome.urgent, isFalse);
      expect(NotificationType.donation.urgent, isFalse);
    });

    test('scelta del Non disturbare del telefono', () {
      expect(DndChoice.fromKey('sempre'), DndChoice.always);
      expect(DndChoice.fromKey('mai'), DndChoice.never);
      expect(DndChoice.fromKey(null), DndChoice.ask);
      // non ancora scelto: attivo su Android e Windows, spento su iOS/macOS
      // (lì serve prima creare il comando)
      for (final k in [
        FocusSystemKind.androidDnd,
        FocusSystemKind.windowsFocus,
      ]) {
        expect(systemQuietOn(k, DndChoice.ask), isTrue);
        expect(systemQuietOn(k, DndChoice.never), isFalse);
      }
      expect(systemQuietOn(FocusSystemKind.appleFocus, DndChoice.ask), isFalse);
      expect(
        systemQuietOn(FocusSystemKind.appleFocus, DndChoice.always),
        isTrue,
      );
      expect(systemQuietOn(FocusSystemKind.none, DndChoice.always), isFalse);
      // comando di iOS/macOS: spazi come %20, ora di fine come testo, esito
      // di ritorno a UniNotes (x-callback-url)
      expect(
        appleShortcutUri(DateTime(2026, 10, 14, 18, 5)).toString(),
        'shortcuts://x-callback-url/run-shortcut?name=UniNotes%20Focus'
        '&input=text&text=2026-10-14%2018%3A05'
        '&x-success=uninotes%3A%2F%2Ffocus%2Fok'
        '&x-cancel=uninotes%3A%2F%2Ffocus%2Fannullato'
        '&x-error=uninotes%3A%2F%2Ffocus%2Ferrore',
      );
      expect(showFocusPill(active: true, screenVisible: false), isTrue);
      expect(showFocusPill(active: true, screenVisible: true), isFalse);
      expect(showFocusPill(active: false, screenVisible: false), isFalse);
    });
  });

  group('servizio Focus', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('la sessione finita si salva come sessione di studio Focus', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      var now = DateTime(2026, 10, 12, 9);
      final f = FocusService(
        s,
        timer: FocusTimer(clock: () => now, tick: false),
      );
      await f.start(
        const FocusSettings(minutes: 45),
        const FocusLink(
          courseId: null,
          activity: ActivityType.exercises,
          label: 'Analisi I · Limiti',
        ),
      );
      expect(f.active, isTrue);
      expect(f.quietUntil, DateTime(2026, 10, 12, 9, 45));
      expect(await s.settings.get(FocusKeys.running), isNotNull);

      now = now.add(const Duration(minutes: 50));
      f.timer.check();
      // l'evento «finita» arriva in un microtask e salva la sessione
      for (var i = 0; i < 200 && f.completed.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(f.completed.value?.completed, isTrue);
      final saved = await s.study.sessions();
      expect(saved.single.focus, isTrue);
      expect(saved.single.durationMinutes, 40);
      expect(saved.single.plannedMinutes, 45);
      expect(saved.single.activityType, ActivityType.exercises);
      expect(await s.settings.get(FocusKeys.running), isNull);
      expect(f.quietUntil, isNull);

      // impostazioni ricordate per la prossima volta
      final g = FocusService(s, timer: FocusTimer(tick: false));
      await g.load();
      expect(g.settings.minutes, 45);
      expect(g.link.label, 'Analisi I · Limiti');
    });

    test('scartata: nessuna sessione salvata', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      var now = DateTime(2026, 10, 12, 9);
      final f = FocusService(
        s,
        timer: FocusTimer(clock: () => now, tick: false),
      );
      await f.start(const FocusSettings(minutes: 30), const FocusLink());
      now = now.add(const Duration(minutes: 10));
      await f.discard();
      expect(await s.study.sessions(), isEmpty);
      expect(f.active, isFalse);
    });
  });

  testWidgets('riquadro della sessione Focus sopra le schermate', (
    tester,
  ) async {
    await initializeDateFormatting('it_IT');
    final s = (await tester.runAsync(
      () async => AppServices(await AppDatabase.openInMemory()),
    ))!;
    addTearDown(() => tester.runAsync(s.database.close));
    await tester.pumpWidget(
      Provider<AppServices>.value(
        value: s,
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          builder: (context, child) =>
              RecordingOverlayHost(child: child ?? const SizedBox()),
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    expect(find.text('Matematica · Derivate'), findsNothing);
    await tester.runAsync(
      () => s.focus.start(
        const FocusSettings(minutes: 30),
        const FocusLink(label: 'Matematica · Derivate'),
      ),
    );
    await tester.pump();
    expect(find.text('Matematica · Derivate'), findsOneWidget);
    expect(find.textContaining('Concentrazione'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Metti in pausa la sessione'));
    await tester.pump();
    expect(s.focus.timer.paused, isTrue);
    expect(find.textContaining('In pausa'), findsOneWidget);

    await tester.runAsync(() => s.focus.discard());
    await tester.pump();
    expect(find.text('Matematica · Derivate'), findsNothing);
  });
  testWidgets('impostazioni «Focus e Non disturbare» e fine con due scelte', (
    tester,
  ) async {
    await initializeDateFormatting('it_IT');
    final s = (await tester.runAsync(
      () async => AppServices(await AppDatabase.openInMemory()),
    ))!;
    addTearDown(() => tester.runAsync(s.database.close));
    Future<void> pump(Widget w) async {
      await tester.pumpWidget(
        Provider<AppServices>.value(
          value: s,
          child: MaterialApp(home: Scaffold(body: ListView(children: [w]))),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    // Android: attivo finché non lo si spegne; senza permesso «Concedi»
    await pump(const FocusQuietSection(kind: FocusSystemKind.androidDnd));
    expect(find.text('Silenzia il telefono durante Focus'), findsOneWidget);
    expect(find.byKey(const Key('focus-dnd-access')), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(s.focus.dnd, DndChoice.never);
    expect(await tester.runAsync(() => s.settings.get(FocusKeys.dnd)), 'mai');
    expect(find.byKey(const Key('focus-dnd-access')), findsNothing);

    // iOS/macOS: il comando da creare
    await pump(
      const FocusQuietSection(key: Key('apple'), kind: FocusSystemKind.appleFocus),
    );
    expect(find.textContaining(kAppleFocusShortcut), findsWidgets);

    // «Terminare la sessione?»: due soli pulsanti
    await pump(
      Builder(
        builder: (c) => TextButton(
          onPressed: () => askFinishFocus(c),
          child: const Text('Termina'),
        ),
      ),
    );
    await tester.tap(find.text('Termina'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.byType(TextButton)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(FilledButton)),
      findsOneWidget,
    );
  });
}
