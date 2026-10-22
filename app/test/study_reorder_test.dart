import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/study/attachments.dart';
import 'package:university_notes/features/study/course_groups.dart';
import 'package:university_notes/features/study/focus/focus_screen.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/features/study/topics_tab.dart';
import 'package:university_notes/models/attachment.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/study.dart';

/// Studio: insegnamenti per semestre/annuale/OFA e riordino, ordine dei
/// moduli, rimozioni in blocco, scorrimento automatico trascinando un
/// argomento, tipo del file allegato, timer della sessione Focus.

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

Future<AppServices> _pump(
  WidgetTester tester,
  Future<void> Function(AppServices s) seed, {
  Size size = const Size(420, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await initializeDateFormatting('it_IT');
  final services = (await tester.runAsync(() async {
    final s = AppServices(await AppDatabase.openInMemory());
    await seed(s);
    return s;
  }))!;
  addTearDown(() => tester.runAsync(services.database.close));
  await tester.pumpWidget(
    Provider.value(
      value: services,
      child: const MaterialApp(home: StudyScreen()),
    ),
  );
  await _settle(tester);
  return services;
}

/// Tieni premuto [finder] e spostalo di [by] (a passi), poi rilascia.
Future<void> _longDrag(
  WidgetTester tester,
  Finder finder,
  Offset by, {
  int steps = 8,
}) async {
  final g = await tester.startGesture(tester.getCenter(finder));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  for (var i = 0; i < steps; i++) {
    await g.moveBy(by / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  group('gruppi e ordine degli insegnamenti', () {
    test('semestri, annuali e OFA in fondo', () {
      const courses = [
        Course(id: 1, name: 'Fisica', semester: '2'),
        Course(id: 2, name: 'OFA di matematica', semester: '1'),
        Course(id: 3, name: 'Analisi', semester: '1'),
        Course(id: 4, name: 'Chimica', semester: 'annuale'),
        Course(id: 5, name: 'Recupero obblighi formativi'),
        Course(id: 6, name: 'Geometria', semester: '1'),
      ];
      final g = groupStudyCourses(courses);
      expect(g.map((x) => x.label), [
        '1° semestre',
        '2° semestre',
        'Annuale',
        'OFA',
      ]);
      // nel gruppo resta l'ordine di partenza
      expect(g.first.courses.map((c) => c.id), [3, 6]);
      expect(g.last.courses.map((c) => c.id), [2, 5]);
    });

    test('anni diversi: l\'anno davanti al semestre', () {
      final g = groupStudyCourses(const [
        Course(id: 1, name: 'A', year: 2, semester: '1'),
        Course(id: 2, name: 'B', year: 1, semester: '2'),
      ]);
      expect(g.map((x) => x.label), [
        '1° anno · 2° semestre',
        '2° anno · 1° semestre',
      ]);
    });

    test('ordine salvato; i nuovi dopo, nell\'ordine di partenza', () {
      const courses = [
        Course(id: 1, name: 'A'),
        Course(id: 2, name: 'B'),
        Course(id: 3, name: 'C'),
        Course(id: 4, name: 'D'),
      ];
      expect(applyCourseOrder(courses, [3, 1]).map((c) => c.id), [3, 1, 2, 4]);
      expect(applyCourseOrder(courses, const []), same(courses));
    });

    test('tipi del file in parole', () {
      expect(describeAttachmentKinds({AttachmentKind.theory}), 'Teoria');
      expect(
        describeAttachmentKinds({
          AttachmentKind.exercises,
          AttachmentKind.theory,
        }),
        'Teoria ed Esercizi',
      );
      expect(
        describeAttachmentKinds(AttachmentKind.values.toSet()),
        'Teoria, Ripasso ed Esercizi',
      );
    });
  });

  testWidgets('desktop: niente elenco laterale; elenco per semestre e '
      'riordino degli insegnamenti', (tester) async {
    final s = await _pump(tester, (s) async {
      for (final c in const [
        Course(name: 'Analisi I', semester: '1'),
        Course(name: 'Geometria', semester: '1'),
        Course(name: 'Fisica I', semester: '2'),
        Course(name: 'Laboratorio', semester: 'annuale'),
        Course(name: 'OFA di matematica'),
      ]) {
        await s.courses.insert(c);
      }
    }, size: const Size(1400, 900));
    // niente elenco a sinistra con nomi e stato degli insegnamenti
    expect(find.text('Geometria'), findsNothing);
    expect(find.text('Non ancora iniziato'), findsNothing);
    expect(find.text('In corso'), findsNothing);

    await tester.tap(find.byKey(const Key('course-name')));
    await tester.pumpAndSettle();
    for (final h in ['1° semestre', '2° semestre', 'Annuale', 'OFA']) {
      expect(find.text(h), findsOneWidget);
    }
    // solo il nome, niente stato
    expect(find.text('In corso'), findsNothing);
    expect(find.text('Geometria'), findsOneWidget);

    // Geometria sopra Analisi I (stesso semestre)
    final analisi = find.ancestor(
      of: find.text('Analisi I').last,
      matching: find.byType(CoursePickTile),
    );
    final geometria = find.ancestor(
      of: find.text('Geometria'),
      matching: find.byType(CoursePickTile),
    );
    final dy = tester.getCenter(analisi).dy - tester.getCenter(geometria).dy;
    await _longDrag(tester, geometria, Offset(0, dy - 10));
    await _settle(tester);
    final order = (await tester.runAsync(() => loadStudyCourseOrder(s)))!;
    final names = {
      for (final c in (await tester.runAsync(s.courses.all))!) c.id: c.name,
    };
    final saved = [for (final id in order) names[id]];
    expect(saved.indexOf('Geometria'), lessThan(saved.indexOf('Analisi I')));
  });

  testWidgets('moduli: ordine al centro tenendo premuto il nome, rimuovi '
      'tutti i moduli, elimina tutti gli argomenti', (tester) async {
    late int courseId;
    final s = await _pump(tester, (s) async {
      courseId = await s.courses.insert(const Course(name: 'Analisi I'));
      for (var i = 0; i < 3; i++) {
        final m = await s.study.insertModule(
          StudyModule(courseId: courseId, name: 'Modulo $i', sort: i),
        );
        await s.study.insertTopic(
          Topic(moduleId: m, name: 'Argomento $i', sort: 0),
        );
      }
    });
    Future<List<String>> modules() async => [
      for (final m in (await tester.runAsync(() => s.study.modules(courseId)))!)
        m.name,
    ];

    // tieni premuto il nome del modulo: finestra con tutti i moduli
    await tester.longPress(find.text('Modulo 0'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('module-order-dialog')), findsOneWidget);
    expect(find.text('Ordine dei moduli'), findsOneWidget);
    final dialog = find.byKey(const Key('module-order-dialog'));
    final first = find.descendant(of: dialog, matching: find.text('Modulo 0'));
    final last = find.descendant(of: dialog, matching: find.text('Modulo 2'));
    final dy = tester.getCenter(last).dy - tester.getCenter(first).dy;
    await _longDrag(tester, first, Offset(0, dy + 10));
    await _settle(tester);
    expect(await modules(), ['Modulo 1', 'Modulo 2', 'Modulo 0']);
    await tester.tap(find.text('Fatto'));
    await tester.pumpAndSettle();
    await _settle(tester);

    // menu del modulo: «Elimina tutti gli argomenti» (il modulo resta)
    await tester.tap(find.byTooltip('Altre azioni').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina tutti gli argomenti'));
    await tester.pumpAndSettle();
    expect(find.text('Eliminare tutti gli argomenti?'), findsOneWidget);
    await tester.tap(find.text('Conferma'));
    await tester.pumpAndSettle();
    await _settle(tester);
    final topics = (await tester.runAsync(
      () => s.study.topicsOfCourse(courseId),
    ))!;
    expect(topics.map((t) => t.name), ['Argomento 2', 'Argomento 0']);
    expect((await modules()).length, 3);

    // menu dell'insegnamento: «Rimuovi tutti i moduli»
    await tester.tap(find.byKey(const Key('course-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Ordina i moduli'), findsOneWidget);
    await tester.tap(find.text('Rimuovi tutti i moduli'));
    await tester.pumpAndSettle();
    expect(find.text('Rimuovere tutti i moduli?'), findsOneWidget);
    await tester.tap(find.text('Conferma'));
    await tester.pumpAndSettle();
    await _settle(tester);
    expect(await modules(), isEmpty);
    expect(
      (await tester.runAsync(() => s.study.topicsOfCourse(courseId)))!,
      isEmpty,
    );
  });

  testWidgets(
    'argomento trascinato vicino al bordo: la pagina scorre da sola',
    (tester) async {
      late int moduleId;
      final s = await _pump(tester, (s) async {
        final c = await s.courses.insert(const Course(name: 'Analisi I'));
        moduleId = await s.study.insertModule(
          StudyModule(courseId: c, name: 'Limiti'),
        );
        for (var i = 0; i < 30; i++) {
          await s.study.insertTopic(
            Topic(moduleId: moduleId, name: 'Argomento $i', sort: i),
          );
        }
      }, size: const Size(420, 700));
      final scroll = tester.state<ScrollableState>(
        find
            .ancestor(
              of: find.text('Argomento 0'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // la card dell'insegnamento è alta: l'argomento in cima allo schermo
      final y0 = tester.getCenter(find.text('Argomento 0')).dy;
      scroll.position.jumpTo(y0 - 150);
      await tester.pump();
      final top = scroll.position.pixels;

      final g = await tester.startGesture(
        tester.getCenter(find.text('Argomento 0')),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      // fino in fondo allo schermo, poi fermo: la lista continua a scorrere
      final target = tester.view.physicalSize.height - 10;
      final start = tester.getCenter(find.text('Argomento 0')).dy;
      for (var i = 0; i < 10; i++) {
        await g.moveBy(Offset(0, (target - start) / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final before = scroll.position.pixels;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(scroll.position.pixels, greaterThan(before));
      expect(scroll.position.pixels, greaterThan(top + 100));
      await g.up();
      await tester.pumpAndSettle();
      await _settle(tester);
      final topics = (await tester.runAsync(() => s.study.topics(moduleId)))!;
      // l'argomento è sceso oltre quelli che all'inizio erano fuori schermo
      final at = topics.indexWhere((t) => t.name == 'Argomento 0');
      expect(at, greaterThan(8));
    },
  );

  testWidgets('tipo del file: Teoria, Ripasso, Esercizi e «Non chiedere più»', (
    tester,
  ) async {
    final s = await _pump(tester, (s) async {
      await s.courses.insert(const Course(name: 'Analisi I'));
    });
    Set<AttachmentKind>? result;
    var calls = 0;
    await tester.pumpWidget(
      Provider.value(
        value: s,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  calls++;
                  result = await chooseAttachmentKinds(
                    context,
                    count: 1,
                    name: 'Esercitazione 3',
                  );
                },
                child: const Text('allega'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('allega'));
    await _settle(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attachment-kind-dialog')), findsOneWidget);
    for (final k in ['Teoria', 'Ripasso', 'Esercizi', 'Non chiedere più']) {
      expect(find.text(k), findsOneWidget);
    }
    // due soli pulsanti
    expect(find.text('Annulla'), findsOneWidget);
    expect(find.text('Allega'), findsOneWidget);
    // all'inizio è segnata Teoria: la tolgo e segno Esercizi
    await tester.tap(find.byKey(const ValueKey('kind-teoria')));
    await tester.tap(find.byKey(const ValueKey('kind-esercizi')));
    await tester.tap(find.byKey(const Key('kind-dont-ask')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('kind-confirm')));
    await tester.pumpAndSettle();
    await _settle(tester);
    expect(calls, 1);
    expect(result, {AttachmentKind.exercises});
    expect(
      await tester.runAsync(() => s.settings.get(kAttachmentKindDontAskKey)),
      '1',
    );

    // la volta dopo niente domanda: l'ultimo tipo scelto
    result = null;
    await tester.tap(find.text('allega'));
    await _settle(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attachment-kind-dialog')), findsNothing);
    expect(result, {AttachmentKind.exercises});
  });

  testWidgets('timer Focus: cifre grandi anche con una riga lunga', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final size in [180.0, 320.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FocusRing(
                size: size,
                value: 0.3,
                label: 'Concentrazione',
                time: '25:00',
                caption:
                    'Analisi matematica I e geometria analitica con '
                    'elementi di algebra lineare',
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.text('25:00'));
      // le cifre riempiono la corda centrale dell'anello: la riga lunga
      // sotto non le rimpicciolisce (prima: un quinto del diametro)
      expect(rect.width, greaterThan(size * 0.6), reason: 'anello $size');
      // la riga sotto si accorcia e resta dentro l'anello
      final ring = tester.getRect(find.byType(FocusRing));
      final caption = tester.getRect(find.textContaining('Analisi'));
      expect(ring.contains(caption.topLeft), isTrue);
      expect(ring.contains(caption.bottomRight), isTrue);
    }
  });
}
