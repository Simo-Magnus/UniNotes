import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/academic/academic_year.dart';
import 'package:university_notes/core/academic/plan_scope.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/datapack_importer.dart';
import 'package:university_notes/features/courses/course_form.dart';
import 'package:university_notes/features/courses/course_rename.dart';
import 'package:university_notes/features/exams/exam_detail.dart';
import 'package:university_notes/features/exams/exam_form.dart';
import 'package:university_notes/features/exams/exam_stats.dart';
import 'package:university_notes/features/exams/exam_status.dart';
import 'package:university_notes/features/exams/exam_ui.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/features/settings/sections/questions_reset.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/utils/exclusion_filter.dart';

/// Servizi con un database vuoto e l'insegnamento «Fisica I» (dal database
/// dei corsi: ha un id esterno).
Future<(AppServices, int)> _services() async {
  final db = await AppDatabase.openInMemory();
  for (final t in ['exams', 'courses', 'app_settings']) {
    await db.db.delete(t);
  }
  final s = AppServices(db);
  final cid = await s.courses.save(
    const Course(
      externalId: 'polito:course:fis1',
      name: 'Fisica I',
      year: 1,
      semester: '1',
      cfu: 6,
    ),
  );
  return (s, cid);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  AppServices s,
  Widget child, {
  Size size = const Size(420, 1600),
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
  await _settle(tester);
}

StudentProfile _profile(int year) => StudentProfile(
  universityId: 'polito',
  universityName: 'Politecnico di Torino',
  degreeId: 'polito:l8',
  degreeName: 'Ingegneria Informatica',
  degreeType: 'L',
  durationYears: 3,
  currentYear: year,
  referenceAa: const AcademicYear(2026),
);

void main() {
  group('un esame, uno stato', () {
    testWidgets(
      'lo stato cambiato in «Da sostenere» o in «Sostenuti» è lo stesso nelle '
      'due pagine; «Non superato» resta da sostenere e si riprenota',
      (tester) async {
        final (s, cid) = (await tester.runAsync(_services))!;
        final id = (await tester.runAsync(
          () => s.exams.save(Exam(courseId: cid, date: DateTime(2026, 1, 20))),
        ))!;
        await _pump(tester, s, const ExamsScreen());

        Future<void> pick(String key, {bool outcome = false}) async {
          await tester.tap(find.byKey(ValueKey('exam-status-$id')).first);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey('status-$key')));
          await tester.pumpAndSettle();
          if (outcome) {
            await tester.tap(find.byKey(const Key('grade-save')));
          }
          await _settle(tester);
        }

        Future<ExamStatus> stored() async =>
            (await tester.runAsync(() => s.exams.byId(id)))!.status;

        // «Da sostenere»: Prenotato
        await pick('booked');
        expect(await stored(), ExamStatus.booked);
        expect(find.text('Prenotato'), findsWidgets);
        // Sostenuto (esito in attesa): passa in «Sostenuti»
        await pick('taken', outcome: true);
        expect(await stored(), ExamStatus.taken);
        expect(find.byKey(ValueKey('exam-status-$id')), findsNothing);
        await tester.tap(find.text('Sostenuti'));
        await _settle(tester);
        expect(find.text('Sostenuto'), findsOneWidget);
        // «Sostenuti»: «Esito» apre il menù del voto, dove c'è «Non superato»
        await pick('passed');
        await tester.tap(find.byKey(const Key('grade-dropdown')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('grade-$kOutcomeFailed')).last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('grade-save')));
        await _settle(tester);
        expect(await stored(), ExamStatus.failed);
        expect(find.text('Non superato'), findsWidgets);
        // in «Da sostenere» lo stesso esame, con lo stesso stato
        await tester.tap(find.text('Da sostenere'));
        await _settle(tester);
        expect(find.byKey(ValueKey('exam-status-$id')), findsOneWidget);
        expect(find.text('Non superato'), findsOneWidget);
        expect(find.text('Prenotato'), findsNothing);
        // si riprenota: torna «Prenotato», senza la data dell'appello passato
        await pick('booked');
        final again = (await tester.runAsync(() => s.exams.byId(id)))!;
        expect(again.status, ExamStatus.booked);
        expect(again.date, isNull);
        expect(find.text('Prenotato'), findsWidgets);
        await tester.tap(find.text('Sostenuti'));
        await _settle(tester);
        expect(find.byKey(ValueKey('exam-status-$id')), findsNothing);
        await tester.runAsync(() => s.database.close());
      },
    );

    test('esame del database e esame aggiunto a mano diventano uno', () async {
      final (s, cid) = await _services();
      // esame creato dal database dei corsi: da prenotare, con argomenti
      final catalog = await s.exams.save(
        Exam(
          courseId: cid,
          externalId: 'polito:exam:fis1',
          topics: 'Cinematica',
          studyMaterials: const ['Halliday'],
        ),
      );
      // lo stesso esame aggiunto a mano con «Nuova prova», già superato
      final own = await s.exams.save(
        Exam(
          courseId: cid,
          date: DateTime(2026, 7, 1),
          status: ExamStatus.passed,
          grade: 28,
        ),
      );
      final data = await loadExamsData(s);
      final finals = data.exams.where((e) => e.courseId == cid).toList();
      expect(finals, hasLength(1));
      final e = finals.single;
      // resta la riga del database dei corsi (id stabile: «Aggiorna database»
      // non ricrea il doppione e la sincronizzazione la riconosce) con
      // stato, voto e data dell'esame aggiunto a mano
      expect(e.id, catalog);
      expect(e.externalId, 'polito:exam:fis1');
      expect(e.status, ExamStatus.passed);
      expect(e.grade, 28);
      expect(e.date, DateTime(2026, 7, 1));
      expect(e.topics, 'Cinematica');
      expect(e.studyMaterials, ['Halliday']);
      expect(await s.exams.byId(own), isNull);
      // niente più in «Da sostenere»
      expect(toTakeExams(data.exams), isEmpty);
      // un secondo giro non cambia nulla
      expect(await s.exams.mergeDuplicateFinals(), 0);
      // «Aggiorna database» aggiorna l'esame rimasto, senza doppioni né
      // perdere lo stato
      await DataPackImporter(s.database).importMap({
        'format': 'university-manager-datapack',
        'version': 1,
        'courses': [
          {'externalId': 'polito:course:fis1', 'name': 'Fisica I', 'year': 1},
        ],
        'exams': [
          {
            'externalId': 'polito:exam:fis1',
            'courseExternalId': 'polito:course:fis1',
            'kind': 'final',
            'examType': 'scritto',
          },
        ],
      }, exclusionPatterns: const []);
      final after = await s.exams.byCourse(cid);
      expect(after, hasLength(1));
      expect(after.single.status, ExamStatus.passed);
      expect(after.single.examType, 'scritto');
      await s.database.close();
    });

    test(
      'restano i tentativi veri: prove sostenute e appelli con data',
      () async {
        final (s, cid) = await _services();
        await s.exams.save(
          Exam(
            courseId: cid,
            date: DateTime(2026, 1, 10),
            status: ExamStatus.failed,
          ),
        );
        await s.exams.save(
          Exam(
            courseId: cid,
            date: DateTime(2026, 6, 10),
            status: ExamStatus.booked,
          ),
        );
        expect(await s.exams.mergeDuplicateFinals(), 0);
        final all = await s.exams.all();
        expect(all, hasLength(2));
        // da sostenere solo l'appello prenotato: il non superato è storia
        expect(toTakeExams(all).single.status, ExamStatus.booked);
        await s.database.close();
      },
    );

    test('nuovo esame finale di un insegnamento che ne ha già uno', () {
      final existing = Exam(
        id: 7,
        courseId: 1,
        externalId: 'polito:exam:fis1',
        topics: 'Cinematica',
        studyMaterials: const ['Halliday'],
      );
      final typed = Exam(
        courseId: 1,
        date: DateTime(2027, 1, 20),
        time: '09:00',
        status: ExamStatus.booked,
      );
      final m = mergeIntoExistingFinal(existing, typed);
      expect(m.id, 7);
      expect(m.externalId, 'polito:exam:fis1');
      expect(m.status, ExamStatus.booked);
      expect(m.date, DateTime(2027, 1, 20));
      expect(m.time, '09:00');
      expect(m.topics, 'Cinematica');
      expect(m.studyMaterials, ['Halliday']);
    });
  });

  group('«Non superato» nel voto', () {
    test('voci del menù del voto e loro esito', () {
      expect(kOutcomeCodes.take(3), [
        kOutcomeNone,
        kOutcomeFailed,
        kOutcomePass,
      ]);
      expect(outcomeLabel(kOutcomeFailed, ExamStatus.booked), 'Non superato');
      expect(outcomeLabel(kOutcomeNone, ExamStatus.booked), 'Nessun voto');
      expect(
        outcomeLabel(kOutcomeNone, ExamStatus.taken),
        'In attesa dell\'esito',
      );
      expect(
        outcomeOf(kOutcomeFailed, current: ExamStatus.booked).status,
        ExamStatus.failed,
      );
      // nessun voto: una prova da sostenere resta com'è, le altre in attesa
      expect(
        outcomeOf(kOutcomeNone, current: ExamStatus.booked).status,
        ExamStatus.booked,
      );
      expect(
        outcomeOf(kOutcomeNone, current: ExamStatus.passed).status,
        ExamStatus.taken,
      );
      final lode = outcomeOf(30, current: ExamStatus.taken, laude: true);
      expect(lode.status, ExamStatus.passed);
      expect(lode.grade, 30);
      expect(lode.laude, isTrue);
      expect(outcomeCode(ExamStatus.failed, null), kOutcomeFailed);
      expect(outcomeCode(ExamStatus.passed, null), kOutcomePass);
      expect(outcomeCode(ExamStatus.passed, 30, laude: true), 30);
    });

    test('«Non superato» non conta nelle medie né nei CFU', () {
      const course = Course(id: 1, name: 'Fisica I', cfu: 6);
      final failed = Exam(courseId: 1, status: ExamStatus.failed);
      expect(acquiredCfu([failed], {1: course}), 0);
      final sum = AverageSummary('Tutti', [failed], {1: course});
      expect(sum.failed, 1);
      expect(sum.passed, 0);
      expect(sum.result.weightedAverage, isNull);
    });

    test('riprenotare un non superato toglie la data passata', () {
      final e = Exam(
        courseId: 1,
        date: DateTime(2026, 1, 10),
        time: '09:00',
        status: ExamStatus.failed,
      );
      final r = withStatus(e, ExamStatus.booked, now: DateTime(2026, 2, 1));
      expect(r.status, ExamStatus.booked);
      expect(r.date, isNull);
      expect(r.time, isNull);
      // con una data futura la data resta
      final future = withStatus(
        e.copyWith(date: DateTime(2026, 3, 1)),
        ExamStatus.booked,
        now: DateTime(2026, 2, 1),
      );
      expect(future.date, DateTime(2026, 3, 1));
    });

    testWidgets('dal dettaglio: «Voto» → «Non superato»', (tester) async {
      final (s, cid) = (await tester.runAsync(_services))!;
      final id = (await tester.runAsync(
        () => s.exams.save(Exam(courseId: cid, status: ExamStatus.booked)),
      ))!;
      await _pump(tester, s, Scaffold(body: ExamDetailView(examId: id)));
      await tester.tap(find.byTooltip('Inserisci il voto'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('grade-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Non superato').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('grade-save')));
      await _settle(tester);
      final e = (await tester.runAsync(() => s.exams.byId(id)))!;
      expect(e.status, ExamStatus.failed);
      expect(e.grade, isNull);
      expect(find.text('Non superato'), findsWidgets);
      await tester.runAsync(() => s.database.close());
    });
  });

  group('menù «Corso» di una prova nuova', () {
    const y1 = Course(id: 1, name: 'Analisi I', year: 1, degreeId: 'polito:l8');
    const y2 = Course(id: 2, name: 'Fisica II', year: 2, degreeId: 'polito:l8');
    const y3 = Course(id: 3, name: 'Reti', year: 3, degreeId: 'polito:l8');
    const ofa = Course(
      id: 4,
      name: 'OFA Matematica',
      year: 2,
      degreeId: 'polito:l8',
    );
    const other = Course(id: 5, name: 'Chimica', year: 2, degreeId: 'unito:x');
    final scope = PlanScope(profile: _profile(2), year: 2);
    final none = ExclusionFilter(const []);
    final noOfa = ExclusionFilter(const [r'\bOFA\b']);

    bool offered(Course c, {bool passed = false, ExclusionFilter? f}) =>
        offeredInExamForm(
          c,
          scope: scope,
          exclusions: f ?? none,
          passed: passed,
        );

    test('anno frequentato e arretrati, non gli anni successivi', () {
      expect(offered(y2), isTrue);
      expect(offered(y3), isFalse);
      expect(offered(y1), isTrue);
      expect(offered(y1, passed: true), isFalse);
      expect(offered(other), isFalse);
    });

    test('senza gli insegnamenti esclusi (OFA, inglese, facoltativi)', () {
      expect(offered(ofa), isTrue);
      expect(offered(ofa, f: noOfa), isFalse);
      // anche se lo studente l'ha rinominato: conta il nome ufficiale
      expect(
        offered(ofa.copyWith(customName: 'Recupero di matematica'), f: noOfa),
        isFalse,
      );
    });
  });

  group('eliminazione con «Non chiedere più»', () {
    testWidgets('conferma, poi più nessuna domanda; si ripristina', (
      tester,
    ) async {
      final (s, cid) = (await tester.runAsync(_services))!;
      final a = (await tester.runAsync(
        () => s.exams.save(Exam(courseId: cid, kind: ExamKind.midterm)),
      ))!;
      final b = (await tester.runAsync(
        () => s.exams.save(
          Exam(courseId: cid, kind: ExamKind.midterm, title: 'Seconda'),
        ),
      ))!;
      await _pump(tester, s, Scaffold(body: ExamDetailView(examId: a)));
      await tester.tap(find.text('Elimina'));
      await _settle(tester);
      expect(find.text('Eliminare la prova?'), findsOneWidget);
      // due pulsanti e la casella
      expect(find.text('Annulla'), findsOneWidget);
      expect(find.text('Non chiedere più'), findsOneWidget);
      await tester.tap(find.byKey(const Key('exam-delete-dont-ask')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('exam-delete-confirm')));
      await _settle(tester);
      expect(await tester.runAsync(() => s.exams.byId(a)), isNull);
      expect(
        await tester.runAsync(() => s.settings.get(kDontAskDeleteExamKey)),
        '1',
      );
      // la seconda si elimina senza domanda
      await _pump(tester, s, Scaffold(body: ExamDetailView(examId: b)));
      await tester.tap(find.text('Elimina'));
      await _settle(tester);
      expect(find.text('Eliminare la prova?'), findsNothing);
      expect(await tester.runAsync(() => s.exams.byId(b)), isNull);
      // «Ripristina le domande» la riporta
      await tester.runAsync(() => resetDontAskQuestions(s.settings));
      expect(
        await tester.runAsync(() => s.settings.get(kDontAskDeleteExamKey)),
        isNull,
      );
      await tester.runAsync(() => s.database.close());
    });
  });

  group('nome dell\'insegnamento', () {
    test('un solo dato, che «Aggiorna database» non cancella', () async {
      final (s, cid) = await _services();
      final c = (await s.courses.byId(cid))!;
      final renamed = (await applyCourseName(s, c, '  Fisica  generale '))!;
      expect(renamed.name, 'Fisica generale');
      expect(renamed.officialName, 'Fisica I');
      var stored = (await s.courses.byId(cid))!;
      expect(stored.name, 'Fisica generale');
      expect(stored.hasCustomName, isTrue);
      expect(stored.label, 'Fisica generale');
      // il database dei corsi cambia il nome ufficiale
      await DataPackImporter(s.database).importMap({
        'format': 'university-manager-datapack',
        'version': 1,
        'courses': [
          {
            'externalId': 'polito:course:fis1',
            'name': 'Fisica I (meccanica)',
            'year': 1,
          },
        ],
      }, exclusionPatterns: const []);
      stored = (await s.courses.byId(cid))!;
      expect(stored.name, 'Fisica generale');
      expect(stored.officialName, 'Fisica I (meccanica)');
      // ripristino: vuoto o uguale all'ufficiale
      final back = (await applyCourseName(s, stored, ''))!;
      expect(back.name, 'Fisica I (meccanica)');
      stored = (await s.courses.byId(cid))!;
      expect(stored.hasCustomName, isFalse);
      expect(stored.customName, isNull);
      // nel backup (e quindi nella sincronizzazione) c'è la colonna
      await applyCourseName(s, stored, 'Fisica generale');
      final row = (await s.database.db.query(
        'courses',
        where: 'id = ?',
        whereArgs: [cid],
      )).single;
      expect(row['custom_name'], 'Fisica generale');
      expect(row['name'], 'Fisica I (meccanica)');
      await s.database.close();
    });

    testWidgets('dal modulo dell\'insegnamento: nome suo, catalogo libero', (
      tester,
    ) async {
      final (s, cid) = (await tester.runAsync(_services))!;
      final c = (await tester.runAsync(() => s.courses.byId(cid)))!;
      await _pump(tester, s, CourseFormPage(course: c));
      await tester.enterText(
        find.byKey(const Key('course-name-field')),
        'Fisica generale',
      );
      await tester.pump();
      expect(find.text('Nome originale: Fisica I'), findsOneWidget);
      await tester.tap(find.text('Salva').last);
      await _settle(tester);
      final saved = (await tester.runAsync(() => s.courses.byId(cid)))!;
      expect(saved.name, 'Fisica generale');
      expect(saved.officialName, 'Fisica I');
      // cambiare solo il nome non blocca gli aggiornamenti del catalogo
      expect(saved.userEdited, isFalse);
      await tester.runAsync(() => s.database.close());
    });

    testWidgets('dal dettaglio della prova, in tutta la sezione Esami', (
      tester,
    ) async {
      final (s, cid) = (await tester.runAsync(_services))!;
      final id = (await tester.runAsync(
        () => s.exams.save(Exam(courseId: cid, status: ExamStatus.booked)),
      ))!;
      await _pump(tester, s, Scaffold(body: ExamDetailView(examId: id)));
      await tester.tap(find.byKey(const Key('detail-course-name')));
      await tester.pumpAndSettle();
      expect(find.text('Nome dell\'insegnamento'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('course-name-field')),
        'Fisica generale',
      );
      await tester.pump();
      // nome originale sotto il campo e icona per rimetterlo
      expect(find.text('Nome originale: Fisica I'), findsOneWidget);
      expect(find.byKey(const Key('course-name-restore')), findsOneWidget);
      await tester.tap(find.byKey(const Key('course-rename-save')));
      await _settle(tester);
      expect(find.text('Fisica generale'), findsOneWidget);
      expect(
        (await tester.runAsync(() => s.courses.byId(cid)))!.name,
        'Fisica generale',
      );
      await _pump(tester, s, const ExamsScreen());
      expect(find.text('Fisica generale'), findsWidgets);
      expect(find.text('Fisica I'), findsNothing);
      await tester.runAsync(() => s.database.close());
    });
  });
}
