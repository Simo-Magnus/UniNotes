import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/courses/course_detail_screen.dart';
import 'package:university_notes/features/courses/course_form.dart';
import 'package:university_notes/features/courses/courses_screen.dart';
import 'package:university_notes/features/exams/exam_detail.dart';
import 'package:university_notes/features/exams/exam_form.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/models/university.dart';

Future<AppServices> _seed({bool empty = false}) async {
  final db = await AppDatabase.openInMemory();
  // Il DB in memoria è un'istanza condivisa finché non viene chiuso.
  await db.db.delete('courses');
  await db.db.delete('universities');
  await db.db.delete('degrees');
  await db.db.delete('books');
  final s = AppServices(db);
  if (empty) return s;
  await db.db.insert(
    'universities',
    const University(
      id: 'polito',
      name: 'Politecnico di Torino',
      shortName: 'PoliTo',
      color: 0xFF1565C0,
    ).toMap(),
  );
  await db.db.insert(
    'degrees',
    const Degree(
      id: 'polito:ing-informatica',
      universityId: 'polito',
      name: 'Ingegneria Informatica',
      referenceAverages: 'Media tipica 25/30',
      minEntryScore: 'TIL ≥ 1',
      maxGraduationScore: '110/110 e lode',
      source: 'https://www.polito.it',
      updatedAt: '2026-10-01',
    ).toMap(),
  );
  final cid = await s.courses.save(
    const Course(
      name: 'Analisi matematica I',
      code: '01RKCPL',
      universityId: 'polito',
      degreeId: 'polito:ing-informatica',
      teacher: 'Prof. Rossi',
      year: 1,
      semester: '1',
      cfu: 10,
      difficulty: 3.5,
      examMode: 'scritto+orale',
      examStructure: 'Scritto di 2 ore e orale facoltativo.',
      materialsFound: false,
      materialsNote: 'slide del prof. Bianchi (2024/25)',
    ),
  );
  await s.exams.save(
    Exam(
      courseId: cid,
      kind: ExamKind.midterm,
      title: 'Prima prova',
      date: DateTime(2026, 11, 12),
      time: '14:00',
      status: ExamStatus.passed,
      grade: 27,
      topics: 'Limiti e derivate',
      studyMaterials: const ['Lezioni 1-8', r'D:\Analisi\L01.pdf'],
    ),
  );
  await s.exams.save(
    Exam(courseId: cid, date: DateTime(2027, 1, 20), status: ExamStatus.booked),
  );
  await s.exams.save(
    Exam(
      courseId: cid,
      date: DateTime(2026, 7, 1),
      status: ExamStatus.passed,
      grade: 30,
      laude: true,
    ),
  );
  await s.books.insert(
    Book(
      courseId: cid,
      title: 'Analisi 1',
      required: true,
      filePath: r'D:\Libri\a.pdf',
      language: 'italiano',
    ),
  );
  await s.books.insertMaterial(
    StudyMaterial(
      courseId: cid,
      title: 'L1.pdf',
      localPath: r'D:\M\L1.pdf',
      kind: MaterialKind.lecture,
      academicYear: '2024/25',
    ),
  );
  return s;
}

Future<void> _pump(
  WidgetTester tester,
  AppServices s,
  Widget child, {
  Size size = const Size(400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Provider<AppServices>.value(
      value: s,
      child: MaterialApp(home: child),
    ),
  );
  // Lascia completare le query SQLite (I/O reale).
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('Esami: tab, prove in itinere e medie (stretto)', (tester) async {
    final s = (await tester.runAsync(_seed))!;
    await _pump(tester, s, const ExamsScreen(), size: const Size(400, 3000));
    expect(find.text('Da sostenere'), findsWidgets);
    expect(find.text('Prenotato'), findsWidgets);

    await tester.tap(find.text('Sostenuti'));
    await tester.pumpAndSettle();
    expect(find.text('Prima prova'), findsOneWidget);
    expect(find.textContaining('Media prove in itinere'), findsOneWidget);
    // «Esami» / «Itinere/esoneri» senza «Tutti», accanto il filtro a icona
    // degli esiti
    expect(find.text('Itinere/esoneri'), findsOneWidget);
    expect(find.text('Tutti'), findsNothing);
    await tester.tap(find.byKey(const Key('outcome-filter')));
    await tester.pumpAndSettle();
    expect(find.text('Superati'), findsWidgets);
    expect(find.text('Non superati'), findsWidgets);
    expect(find.text('In attesa'), findsWidgets);
    // solo «Non superati»: la prova in itinere superata sparisce
    await tester.tap(find.byKey(const ValueKey('outcome-failed')).first);
    await tester.pumpAndSettle();
    expect(find.text('Prima prova'), findsNothing);
    // tolto di nuovo: si vede tutto
    await tester.tap(find.byKey(const ValueKey('outcome-failed')).first);
    await tester.pumpAndSettle();
    expect(find.text('Prima prova'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Medie'));
    await tester.pumpAndSettle();
    expect(find.text('Media ponderata (CFU)'), findsWidgets);
    // niente più dati di riferimento esterni né formula della base di laurea
    expect(find.textContaining('Fonte: https://www.polito.it'), findsNothing);
    expect(find.textContaining('Base di laurea ='), findsNothing);
    await tester.runAsync(() => s.database.close());
  });

  testWidgets("Esami: stato dall'icona, dettaglio modificabile sul posto", (
    tester,
  ) async {
    final s = (await tester.runAsync(_seed))!;
    await _pump(tester, s, const ExamsScreen(), size: const Size(400, 1600));
    // niente card delle sessioni d'esame
    expect(find.text("Sessioni d'esame"), findsNothing);
    expect(find.text('Calendario delle sessioni'), findsNothing);
    final booked = (await tester.runAsync(s.exams.all))!.singleWhere(
      (e) => e.status == ExamStatus.booked,
    );
    await tester.tap(find.byKey(ValueKey('exam-status-${booked.id}')));
    await tester.pumpAndSettle();
    // due sole scelte
    expect(find.byKey(const ValueKey('status-taken')), findsOneWidget);
    expect(find.byKey(const ValueKey('status-planned')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('status-taken')));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    final after = (await tester.runAsync(() => s.exams.byId(booked.id!)))!;
    expect(after.status, ExamStatus.taken);

    // dettaglio: niente «Modifica», argomenti modificabili toccandoli
    final midterm = (await tester.runAsync(s.exams.all))!.singleWhere(
      (e) => e.kind == ExamKind.midterm,
    );
    await _pump(
      tester,
      s,
      Scaffold(body: ExamDetailView(examId: midterm.id!)),
      size: const Size(420, 1600),
    );
    expect(find.text('Modifica'), findsNothing);
    await tester.tap(find.byKey(const Key('detail-topics')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('detail-topics-field')),
      'Integrali',
    );
    await tester.tap(find.byTooltip('Fatto'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    final edited = (await tester.runAsync(() => s.exams.byId(midterm.id!)))!;
    expect(edited.topics, 'Integrali');
    await tester.runAsync(() => s.database.close());
  });

  testWidgets('Esami: layout largo con dettaglio', (tester) async {
    final s = (await tester.runAsync(_seed))!;
    await _pump(tester, s, const ExamsScreen(), size: const Size(1400, 900));
    expect(find.textContaining('Seleziona un esame'), findsOneWidget);
    await tester.tap(find.text('Analisi matematica I').first);
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.text('Materiali da studiare'), findsOneWidget);

    await tester.tap(find.text('Nuova prova'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prova in itinere o Esonero').last);
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.text('Nuova prova in itinere o esonero'), findsOneWidget);
    expect(find.text('Corso *'), findsOneWidget);
    await tester.pumpAndSettle();
    // Salvataggio senza corso: errore di validazione (il «Salva» è in fondo).
    await tester.scrollUntilVisible(
      find.text('Salva'),
      400,
      scrollable: find
          .descendant(
            of: find.byType(ExamFormPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salva').first);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Scegli il corso'),
      -400,
      scrollable: find
          .descendant(
            of: find.byType(ExamFormPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Scegli il corso'), findsOneWidget);
    await tester.runAsync(() => s.database.close());
  });

  testWidgets('Esami e corsi: database vuoto', (tester) async {
    final s = (await tester.runAsync(() => _seed(empty: true)))!;
    await _pump(tester, s, const ExamsScreen());
    expect(find.textContaining('Nessun corso presente'), findsOneWidget);
    await _pump(tester, s, const CoursesScreen());
    expect(
      find.textContaining('Nessun insegnamento in questo anno'),
      findsOneWidget,
    );
    await tester.runAsync(() => s.database.close());
  });

  testWidgets('Corsi: lista e dettaglio', (tester) async {
    final s = (await tester.runAsync(_seed))!;
    await _pump(tester, s, const CoursesScreen(), size: const Size(1400, 1000));
    // si apre con il solo filtro «In corso»: l'insegnamento superato non c'è
    expect(find.text('Analisi matematica I'), findsNothing);
    // nessun filtro scelto = tutti gli insegnamenti
    await tester.tap(find.widgetWithText(FilterChip, 'In corso'));
    await tester.pumpAndSettle();
    expect(find.text('Politecnico di Torino'), findsOneWidget);
    expect(find.text('Analisi matematica I'), findsOneWidget);

    final id = (await tester.runAsync(s.courses.all))!.single.id!;
    await _pump(
      tester,
      s,
      CourseDetailScreen(courseId: id),
      size: const Size(420, 2400),
    );
    expect(find.text('Informazioni'), findsOneWidget);
    expect(find.textContaining('Materiale alternativo'), findsOneWidget);
    expect(find.text('Obbligatorio'), findsOneWidget);
    // niente sigla dell'ateneo accanto al nome
    expect(find.text('PoliTo'), findsNothing);

    // modulo: università e corso di laurea solo da leggere, niente stima
    // delle ore di studio né «Perché e per chi»
    final course = (await tester.runAsync(s.courses.all))!.single;
    await _pump(
      tester,
      s,
      CourseFormPage(course: course),
      size: const Size(420, 3000),
    );
    // «Esame e carico di studio» è già aperto (modalità d'esame indicata)
    expect(find.byKey(const Key('course-university')), findsOneWidget);
    expect(find.text('Politecnico di Torino'), findsOneWidget);
    expect(find.byKey(const Key('course-degree')), findsOneWidget);
    expect(find.text('Orale (facoltativo)'), findsOneWidget);
    expect(find.text('Perché e per chi'), findsNothing);
    expect(find.text('Ore di studio a casa'), findsNothing);
    expect(find.textContaining('27/30'), findsNothing);
    await tester.runAsync(() => s.database.close());
  });
}
