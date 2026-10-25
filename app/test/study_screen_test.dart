import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/features/study/study_timer.dart';
import 'package:university_notes/models/attachment.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/study.dart';

Future<AppServices> _seed() async {
  final s = AppServices(await AppDatabase.openInMemory());
  final c = await s.courses.insert(
    const Course(name: 'Analisi I', universityId: 'polito'),
  );
  final m = await s.study.insertModule(
    StudyModule(courseId: c, name: 'Limiti'),
  );
  final t = await s.study.insertTopic(
    Topic(moduleId: m, name: 'Limiti notevoli', status: TopicStatus.partial),
  );
  final now = DateTime.now();
  await s.study.insertSession(
    StudySession(
      courseId: c,
      topicId: t,
      start: now.subtract(const Duration(hours: 2)),
      end: now.subtract(const Duration(hours: 1)),
      durationMinutes: 60,
      activityType: ActivityType.exercises,
    ),
  );
  return s;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

Future<void> _run(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await initializeDateFormatting('it_IT');
  final services = (await tester.runAsync(_seed))!;
  addTearDown(() => tester.runAsync(services.database.close));
  await tester.pumpWidget(
    Provider.value(
      value: services,
      child: const MaterialApp(home: StudyScreen()),
    ),
  );
  await _settle(tester);
  expect(find.text('Limiti notevoli'), findsOneWidget);
  expect(find.text('Limiti'), findsOneWidget);
  // Stato "Parzialmente completato" = 70%.
  expect(find.text('70%'), findsWidgets);

  await tester.tap(find.text('Sessioni Studio'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _settle(tester);
  expect(find.text('Cronometro'), findsOneWidget);
  expect(find.text('Timer'), findsOneWidget);
  await tester.scrollUntilVisible(
    find.text('1 h').last,
    300,
    scrollable: find.byType(Scrollable).last,
  );
  expect(find.text('1 h'), findsWidgets);

  // con le schede che scorrono (scritte larghe) l'ultima può stare fuori
  await tester.ensureVisible(find.text('Statistiche'));
  await tester.tap(find.text('Statistiche'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _settle(tester);
  expect(find.text('Per materia'), findsOneWidget);
}

void main() {
  studyFilterTests();
  studyTopicsTests();
  testWidgets('StudyScreen su smartphone', (tester) async {
    await _run(tester, const Size(420, 900));
  });

  testWidgets('StudyScreen su desktop', (tester) async {
    await _run(tester, const Size(1400, 900));
  });
}

void studyFilterTests() {
  testWidgets(
    'Studio: niente sigle degli atenei, allegati e azioni della materia',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await initializeDateFormatting('it_IT');
      final services = (await tester.runAsync(() async {
        final s = await _seed();
        for (final u in [
          ('polito', 'Politecnico di Torino', 'PoliTo', 0xFF1565C0),
          ('unito', 'Università di Torino', 'UniTO', 0xFFB71C1C),
        ]) {
          await s.database.db.insert('universities', {
            'id': u.$1,
            'name': u.$2,
            'short_name': u.$3,
            'color': u.$4,
          });
        }
        await s.courses.insert(
          const Course(name: 'Psicologia generale', universityId: 'unito'),
        );
        final topic = (await s.study.allTopics()).single;
        await s.study.insertAttachment(
          Attachment(
            topicId: topic.id,
            title: 'Riassunti – Lezione 1',
            path: '/non/esiste.md',
            createdAt: DateTime(2026, 10, 5),
          ),
        );
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
      // insegnamenti solo con il nome: niente scelta dell'ateneo
      expect(find.text('Tutte'), findsNothing);
      expect(find.text('UniTO'), findsNothing);
      expect(find.text('PoliTo'), findsNothing);
      expect(find.text('Riassunti – Lezione 1'), findsOneWidget);
      expect(find.text('Revisiona con AI'), findsOneWidget);
      expect(find.text('Sessione focus'), findsOneWidget);
      expect(find.text('Registrazioni'), findsOneWidget);
      expect(find.text('Nessun libro'), findsOneWidget);
      expect(find.text('Limiti notevoli'), findsOneWidget);
    },
  );
}

void studyTopicsTests() {
  testWidgets('Argomenti: pallino, file con tipo, nota, menu, sessione focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await initializeDateFormatting('it_IT');
    final services = (await tester.runAsync(() async {
      final s = await _seed();
      final topic = (await s.study.allTopics()).single;
      await s.study.insertAttachment(
        Attachment(
          topicId: topic.id,
          title: 'Esercitazione 3',
          path: '/non/esiste.pdf',
          createdAt: DateTime(2026, 10, 5),
          kinds: const {AttachmentKind.exercises},
        ),
      );
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

    // niente card «Corso»: il nome dell'insegnamento si tocca per cambiarlo
    expect(find.text('Corso'), findsNothing);
    expect(find.byKey(const Key('course-name')), findsOneWidget);
    // argomento: pallino dello stato, file con l'icona del tipo, «Aggiungi
    // file» sotto
    expect(
      find.bySemanticsLabel('Stato: Parzialmente completato'),
      findsWidgets,
    );
    expect(find.text('Esercitazione 3'), findsOneWidget);
    expect(find.byTooltip('Esercizi'), findsOneWidget);
    expect(find.text('Aggiungi file'), findsOneWidget);

    // tocco sull'argomento: la nota
    await tester.tap(find.text('Limiti notevoli'));
    await tester.pumpAndSettle();
    expect(find.text('Nota dell\'argomento'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('note-field')), 'Rivedere');
    await tester.tap(find.text('Salva'));
    await tester.pumpAndSettle();
    await _settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Rivedere'), findsOneWidget);

    // menu del modulo: le quattro voci, niente «Sposta su/giù»
    await tester.tap(find.byTooltip('Altre azioni').first);
    await tester.pumpAndSettle();
    for (final t in ['Sessione focus sul modulo', 'Elimina modulo', 'Nota']) {
      expect(find.text(t), findsOneWidget);
    }
    // la voce del menu e il pulsante della card
    expect(find.text('Revisiona con AI'), findsNWidgets(2));
    expect(find.text('Sposta su'), findsNothing);
    expect(find.text('Allega file'), findsNothing);
    await tester.tap(find.text('Sessione focus sul modulo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);
    // Sessioni Studio con insegnamento e modulo già scelti e il timer
    expect(find.text('Che cosa studi'), findsOneWidget);
    expect(find.byKey(const Key('focus-start')), findsOneWidget);
    expect(StudyTimer.instance.courseId, isNotNull);
    expect(StudyTimer.instance.moduleId, isNotNull);
    expect(find.text('Esercitazione 3'), findsOneWidget);
  });
}
