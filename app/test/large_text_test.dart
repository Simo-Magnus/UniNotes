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
import 'package:university_notes/core/router/app_shell.dart';
import 'package:university_notes/features/books/books_screen.dart';
import 'package:university_notes/features/courses/courses_screen.dart';
import 'package:university_notes/features/dashboard/dashboard_screen.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/features/settings/settings_screen.dart';
import 'package:university_notes/features/study/focus/focus_plan.dart';
import 'package:university_notes/features/study/focus/focus_screen.dart';
import 'package:university_notes/features/study/focus/focus_service.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/models/study.dart';

/// Caratteri grandi (impostazione del sistema × scelta nell'app): le
/// schermate principali non devono rompersi (testo tagliato o fuori
/// misura). Ogni «RenderFlex overflowed» fa fallire il test.
Future<AppServices> _seed() async {
  final s = AppServices(await AppDatabase.openInMemory());
  await s.database.db.insert('universities', {
    'id': 'polito',
    'name': 'Politecnico di Torino',
    'short_name': 'PoliTo',
    'color': 0xFF1565C0,
  });
  final c = await s.courses.insert(
    const Course(
      name: 'Analisi matematica I con esercitazioni',
      universityId: 'polito',
      cfu: 10,
      description: r'Limiti, derivate e integrali: $\int_a^b f(x)\,dx$.',
    ),
  );
  final m = await s.study.insertModule(
    StudyModule(courseId: c, name: 'Limiti e continuità'),
  );
  await s.study.insertTopic(
    Topic(
      moduleId: m,
      name: 'Limiti notevoli',
      status: TopicStatus.partial,
      notes: r'Ricorda $\lim_{x\to 0} \frac{\sin x}{x} = 1$',
    ),
  );
  final now = DateTime.now();
  await s.study.insertSession(
    StudySession(
      courseId: c,
      start: now.subtract(const Duration(hours: 2)),
      end: now.subtract(const Duration(hours: 1)),
      durationMinutes: 60,
      activityType: ActivityType.exercises,
      focus: true,
      plannedMinutes: 60,
    ),
  );
  await s.exams.insert(
    Exam(
      courseId: c,
      date: now.add(const Duration(days: 3)),
      time: '14:00',
      title: 'Prima prova in itinere',
    ),
  );
  return s;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
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

void _check(WidgetTester tester, {String? reason}) {
  final e = tester.takeException();
  if (e is FlutterError) debugPrint('ERRORE ($reason): ${e.toStringDeep()}');
  expect(e, isNull, reason: reason);
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  for (final scale in [1.5, 2.0]) {
    testWidgets('caratteri grandi ×$scale: Studio, Focus, Impostazioni, Home', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final s = (await tester.runAsync(_seed))!;
      addTearDown(() => tester.runAsync(s.database.close));

      // Studio: tutte le schede
      await _pump(tester, s, const StudyScreen());
      _check(tester);
      for (final tab in ['Sessioni Studio', 'Statistiche']) {
        await tester.ensureVisible(find.text(tab));
        await tester.tap(find.text(tab));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _settle(tester);
        _check(tester, reason: tab);
      }

      // Impostazioni, Home, Esami, Insegnamenti, Libri e la barra in basso
      for (final screen in [
        const SettingsScreen(),
        const DashboardScreen(),
        const ExamsScreen(),
        const CoursesScreen(),
        const BooksScreen(),
        Scaffold(
          body: const SizedBox(),
          bottomNavigationBar: GlassNavBar(
            selectedIndex: 0,
            onSelected: (_) {},
            items: [
              for (final d in kDestinations.take(4))
                (icon: d.icon, selectedIcon: d.selectedIcon, label: d.label),
              (
                icon: Icons.more_horiz,
                selectedIcon: Icons.more_horiz,
                label: 'Insegnamenti',
              ),
            ],
          ),
        ),
      ]) {
        await _pump(tester, s, const SizedBox());
        await _pump(tester, s, screen);
        _check(tester, reason: '$screen');
      }

      // sessione Focus in corso a tutto schermo
      await tester.runAsync(
        () => s.focus.start(
          const FocusSettings(minutes: 90),
          const FocusLink(label: 'Analisi matematica I con esercitazioni'),
        ),
      );
      await _pump(tester, s, const FocusScreen());
      _check(tester);
      expect(find.text('Salta pausa'), findsNothing);
      await tester.runAsync(() => s.focus.discard());
      await tester.pump();
    });
  }
}
