import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/academic/course_status_sync.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/dashboard/dashboard_data.dart';
import 'package:university_notes/features/dashboard/dashboard_screen.dart';
import 'package:university_notes/features/dashboard/progress_groups.dart';
import 'package:university_notes/features/dashboard/widgets/course_progress_card.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/study.dart';
import 'package:university_notes/repositories/study_repository.dart';

ProgressGroup _group(String label, List<Course> courses) => ProgressGroup(
  label: label,
  courses: courses,
  items: [
    for (final c in courses)
      CourseProgressInfo(course: c, progress: 0, topics: 1, completed: 0),
  ],
);

Course _c(
  int id,
  String? semester, {
  CourseStatus status = CourseStatus.active,
}) => Course(id: id, name: 'Corso $id', semester: semester, status: status);

/// Due insegnamenti con argomenti: «Analisi» nel 1° semestre, «Fisica» nel
/// 2°. Restituisce i servizi e l'id dell'argomento di Fisica.
Future<(AppServices, int)> _seed() async {
  final s = AppServices(await AppDatabase.openInMemory());
  final analisi = await s.courses.insert(
    Course(name: 'Analisi', semester: '1'),
  );
  final fisica = await s.courses.insert(Course(name: 'Fisica', semester: '2'));
  final m1 = await s.study.insertModule(
    StudyModule(courseId: analisi, name: 'Limiti'),
  );
  final m2 = await s.study.insertModule(
    StudyModule(courseId: fisica, name: 'Meccanica'),
  );
  await s.study.insertTopic(Topic(moduleId: m1, name: 'Successioni'));
  final t = await s.study.insertTopic(Topic(moduleId: m2, name: 'Cinematica'));
  return (s, t);
}

Future<void> _pump(WidgetTester tester, AppServices s) async {
  tester.view.physicalSize = const Size(1400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      Provider<AppServices>.value(
        value: s,
        child: const MaterialApp(
          locale: Locale('it', 'IT'),
          supportedLocales: [Locale('it', 'IT')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: DashboardScreen(),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  for (var i = 0; i < 6; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  await tester.pump();
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });
  setUp(CourseProgressCard.resetSelection);

  group('initialProgressGroup', () {
    final ottobre = DateTime(2026, 10, 21);
    final aprile = DateTime(2027, 4, 10);
    final groups = [
      _group('1° semestre', [_c(1, '1')]),
      _group('2° semestre', [_c(2, '2', status: CourseStatus.upcoming)]),
      _group('Annuale', [_c(3, 'annuale')]),
    ];

    test('senza cambi: il semestre in corso secondo la data', () {
      expect(initialProgressGroup(groups, now: ottobre), '1° semestre');
      expect(initialProgressGroup(groups, now: aprile), '2° semestre');
      expect(initialProgressGroup(const [], now: ottobre), isNull);
    });

    test('ultimo argomento cambiato da meno di 30 giorni', () {
      final last = (courseId: 3, at: ottobre.subtract(const Duration(days: 3)));
      expect(initialProgressGroup(groups, last: last, now: ottobre), 'Annuale');
      // dopo 30 giorni si torna al semestre in corso
      final old = (courseId: 3, at: ottobre.subtract(const Duration(days: 31)));
      expect(
        initialProgressGroup(groups, last: old, now: ottobre),
        '1° semestre',
      );
    });

    test('suddivisione non più in corso: il semestre in corso', () {
      // il 2° semestre non è ancora iniziato
      final last = (courseId: 2, at: ottobre.subtract(const Duration(days: 1)));
      expect(
        initialProgressGroup(groups, last: last, now: ottobre),
        '1° semestre',
      );
      // insegnamento non mostrato (altro anno): regola della data
      final other = (courseId: 99, at: ottobre);
      expect(
        initialProgressGroup(groups, last: other, now: ottobre),
        '1° semestre',
      );
    });

    test('semestre in corso senza argomenti: una suddivisione in corso', () {
      final noFirst = [
        _group('2° semestre', [_c(2, '2', status: CourseStatus.upcoming)]),
        _group('Annuale', [_c(3, 'annuale')]),
      ];
      expect(initialProgressGroup(noFirst, now: ottobre), 'Annuale');
      final none = [
        _group('2° semestre', [_c(2, '2', status: CourseStatus.upcoming)]),
      ];
      expect(initialProgressGroup(none, now: ottobre), '2° semestre');
    });
  });

  test('nomi delle suddivisioni: solo semestre, mai l\'anno', () async {
    final s = AppServices(await AppDatabase.openInMemory());
    // corsi di anni diversi (e uno senza anno, che compare in ogni anno):
    // prima i nomi erano «1° anno · 1° semestre», «Anno non indicato · …»
    final specs = [
      ('Analisi', 1, '1'),
      ('Fisica', 1, '2'),
      ('Algebra', 2, '1'),
      ('Chimica', null, '1'),
      ('Laboratorio', 2, 'annuale'),
    ];
    for (final (name, year, sem) in specs) {
      final id = await s.courses.insert(
        Course(name: name, year: year, semester: sem),
      );
      final m = await s.study.insertModule(
        StudyModule(courseId: id, name: 'Modulo'),
      );
      await s.study.insertTopic(Topic(moduleId: m, name: 'Argomento'));
    }
    final data = await DashboardData.load(s);
    expect(data.progressGroups.map((g) => g.label), [
      '1° semestre',
      '2° semestre',
      'Annuale',
    ]);
    // ogni anno nello stesso gruppo del suo semestre
    expect(
      data.progressGroups.first.courses.map((c) => c.name).toSet(),
      {'Analisi', 'Algebra', 'Chimica'},
    );
    await s.database.close();
  });

  test('scelta salvata con i nomi di prima (con l\'anno): si legge ancora', () {
    expect(progressGroupName('2° anno · 1° semestre'), '1° semestre');
    expect(progressGroupName('1° anno · Annuale'), 'Annuale');
    expect(progressGroupName('Anno non indicato · 2° semestre'), '2° semestre');
    expect(progressGroupName('1° semestre'), '1° semestre');
    expect(progressGroupName('OFA'), 'OFA');
    // un semestre con nome libero non si altera
    expect(progressGroupName('Modulo estivo'), 'Modulo estivo');
  });

  test('cambiare lo stato di un argomento lo annota per la Home', () async {
    final (s, topicId) = await _seed();
    expect(await s.study.lastTopicChange(), isNull);
    final topic = (await s.study.allTopics()).firstWhere(
      (t) => t.id == topicId,
    );
    // stesso stato (es. nome cambiato): niente annotazione
    await s.study.updateTopic(topic.copyWith(name: 'Cinematica 1D'));
    expect(await s.study.lastTopicChange(), isNull);
    // qualunque cambio di stato, non solo «Completato»
    await s.study.updateTopic(topic.copyWith(status: TopicStatus.inProgress));
    final last = await s.study.lastTopicChange();
    final fisica = (await s.courses.all()).firstWhere(
      (c) => c.name == 'Fisica',
    );
    expect(last?.courseId, fisica.id);
    expect(DateTime.now().difference(last!.at).inMinutes, lessThan(1));
    expect(await s.settings.get(StudyRepository.lastTopicChangeKey), isNotNull);
    await s.database.close();
  });

  testWidgets('Home: una suddivisione alla volta, con il selettore', (
    tester,
  ) async {
    final (s, _) = (await tester.runAsync(_seed))!;
    addTearDown(() => tester.runAsync(s.database.close));
    await _pump(tester, s);
    // senza cambi: il semestre in corso secondo la data
    final first = currentSemester(DateTime.now()) == '1';
    final (shown, hidden) = first
        ? ('Analisi', 'Fisica')
        : ('Fisica', 'Analisi');
    expect(find.text(shown), findsOneWidget);
    expect(find.text(hidden), findsNothing);
    expect(find.text(first ? '1° semestre' : '2° semestre'), findsOneWidget);
    // si cambia suddivisione dal menu
    await tester.tap(find.byKey(const Key('progress-group')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(
        CheckedPopupMenuItem<String>,
        first ? '2° semestre' : '1° semestre',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(hidden), findsOneWidget);
    expect(find.text(shown), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home: si apre sull\'ultimo argomento cambiato', (tester) async {
    final (s, topicId) = (await tester.runAsync(_seed))!;
    addTearDown(() => tester.runAsync(s.database.close));
    // argomento di Fisica (2° semestre) cambiato adesso; Fisica è «In
    // corso» (nessun percorso: nessun anno)
    await tester.runAsync(() async {
      final t = (await s.study.allTopics()).firstWhere((t) => t.id == topicId);
      await s.study.updateTopic(t.copyWith(status: TopicStatus.toReview));
    });
    await _pump(tester, s);
    expect(find.text('Fisica'), findsOneWidget);
    expect(find.text('Analisi'), findsNothing);
    expect(
      find.text('0/1 argomenti completati · 1 da ripassare'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
