import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/academic/electives.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/exams/exam_detail.dart';
import 'package:university_notes/features/exams/exam_form.dart';
import 'package:university_notes/features/exams/exam_stats.dart';
import 'package:university_notes/features/exams/exam_ui.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/utils/grade_math.dart';

/// Prove in itinere ed esoneri: non contano nel voto, quindi non si
/// trasformano in esame finale; eliminare l'ultima prova di un insegnamento a
/// scelta (nessun esame finale né altre prove dopo) avvisa e lo archivia.

Future<AppServices> _empty() async {
  final db = await AppDatabase.openInMemory();
  for (final t in ['courses', 'exams', 'modules', 'topics', 'events']) {
    await db.db.delete(t);
  }
  return AppServices(db);
}

Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
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

/// Segmenti «Esame finale» / «Prova in itinere» del modulo, per tipo.
Map<ExamKind, bool> _segments(WidgetTester tester) {
  final b = tester.widget<SegmentedButton<ExamKind>>(
    find.byType(SegmentedButton<ExamKind>),
  );
  return {for (final g in b.segments) g.value: g.enabled};
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  group('prove in itinere ed esoneri non diventano esami finali', () {
    testWidgets('dettaglio: il tipo di una prova in itinere non si cambia', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(_empty))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final c = (await tester.runAsync(
        () => s.courses.insert(const Course(name: 'Fisica', cfu: 6)),
      ))!;
      final id = (await tester.runAsync(
        () => s.exams.save(
          Exam(
            courseId: c,
            kind: ExamKind.midterm,
            status: ExamStatus.passed,
            grade: 25,
          ),
        ),
      ))!;
      await _pump(tester, s, ExamDetailScreen(examId: id));
      expect(find.byType(ExamKindChip), findsOneWidget);
      expect(find.byTooltip('Cambia tipo'), findsNothing);
      await tester.tap(find.byType(ExamKindChip));
      await _settle(tester);
      // nessun foglio con la scelta «Esame finale»
      expect(find.text('Esame finale'), findsNothing);
      final e = (await tester.runAsync(() => s.exams.byId(id)))!;
      expect(e.kind, ExamKind.midterm);
      expect(e.grade, 25);
    });

    testWidgets('dettaglio: nemmeno un esame finale cambia tipo', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(_empty))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final c = (await tester.runAsync(
        () => s.courses.insert(const Course(name: 'Fisica', cfu: 6)),
      ))!;
      final id = (await tester.runAsync(
        () => s.exams.save(
          Exam(courseId: c, status: ExamStatus.passed, grade: 30, laude: true),
        ),
      ))!;
      await _pump(tester, s, ExamDetailScreen(examId: id));
      expect(find.byTooltip('Cambia tipo'), findsNothing);
      await tester.tap(find.byType(ExamKindChip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Prova in itinere o esonero'), findsNothing);
      await _settle(tester, 4);
      final e = (await tester.runAsync(() => s.exams.byId(id)))!;
      expect(e.kind, ExamKind.finalExam);
      expect(e.grade, 30);
      expect(e.laude, isTrue);
    });

    testWidgets('modulo di modifica: il tipo resta quello della prova; per una '
        'prova nuova si sceglie', (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(_empty))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final c = (await tester.runAsync(
        () => s.courses.insert(const Course(name: 'Fisica', cfu: 6)),
      ))!;
      final mid = (await tester.runAsync(
        () => s.exams.save(Exam(courseId: c, kind: ExamKind.midterm)),
      ))!;
      final fin = (await tester.runAsync(
        () => s.exams.save(Exam(courseId: c)),
      ))!;
      final midterm = (await tester.runAsync(() => s.exams.byId(mid)))!;
      final finalExam = (await tester.runAsync(() => s.exams.byId(fin)))!;

      await _pump(tester, s, ExamFormPage(exam: midterm));
      expect(_segments(tester), {
        ExamKind.finalExam: false,
        ExamKind.midterm: true,
      });
      // il tocco sul segmento disattivato non cambia il tipo
      await tester.tap(find.text('Esame finale'));
      await _settle(tester);
      expect(find.text('Modifica prova in itinere o esonero'), findsOneWidget);

      await _pump(tester, s, const SizedBox());
      await _pump(tester, s, ExamFormPage(exam: finalExam));
      expect(_segments(tester), {
        ExamKind.finalExam: true,
        ExamKind.midterm: false,
      });
      // il tocco sul segmento disattivato non cambia il tipo
      await tester.tap(find.text('Prova in itinere o Esonero'));
      await _settle(tester);
      expect(find.text('Modifica prova in itinere o esonero'), findsNothing);

      await _pump(tester, s, const SizedBox());
      await _pump(tester, s, ExamFormPage(initialCourseId: c));
      expect(_segments(tester), {
        ExamKind.finalExam: true,
        ExamKind.midterm: true,
      });
    });
  });

  group('medie e conteggi ignorano prove in itinere ed esoneri', () {
    test('medie, base di laurea, CFU, superati e non superati', () {
      const fisica = Course(id: 1, name: 'Fisica', cfu: 6);
      const chimica = Course(id: 2, name: 'Chimica', cfu: 9);
      final courses = {1: fisica, 2: chimica};
      final exams = [
        Exam(
          id: 1,
          courseId: 1,
          status: ExamStatus.passed,
          grade: 24,
          date: DateTime(2027, 1, 20),
        ),
        // prova in itinere superata con un punteggio alto, anche con cfu e
        // lode salvati: non conta
        Exam(
          id: 2,
          courseId: 1,
          kind: ExamKind.midterm,
          status: ExamStatus.passed,
          grade: 30,
          laude: true,
          cfu: 9,
          date: DateTime(2027, 2, 1),
        ),
        // esonero superato di un insegnamento senza esame finale superato
        Exam(
          id: 3,
          courseId: 2,
          kind: ExamKind.midterm,
          status: ExamStatus.passed,
          grade: 30,
        ),
        // prove in itinere non superate: non sono «non superati»
        Exam(
          id: 4,
          courseId: 2,
          kind: ExamKind.midterm,
          status: ExamStatus.failed,
        ),
      ];
      final r = weightedAverage(exams, courses);
      expect(r.count, 1);
      expect(r.arithmeticAverage, 24);
      expect(r.weightedAverage, 24);
      expect(r.totalCfu, 6);
      expect(r.graduationBase, closeTo(24 * 110 / 30, 1e-9));
      expect(acquiredCfu(exams, courses), 6);

      final summary = AverageSummary('Tutti', exams, courses);
      expect(summary.passed, 1);
      expect(summary.failed, 0);
      expect(summary.cfu, 6);
      expect(summary.result.count, 1);

      // solo prove in itinere: nessuna media, nessun CFU
      final only = exams.where((e) => e.kind == ExamKind.midterm).toList();
      final none = weightedAverage(only, courses);
      expect(none.count, 0);
      expect(none.weightedAverage, isNull);
      expect(none.arithmeticAverage, isNull);
      expect(none.graduationBase, isNull);
      expect(acquiredCfu(only, courses), 0);
      final noneSummary = AverageSummary('Tutti', only, courses);
      expect(noneSummary.passed, 0);
      expect(noneSummary.failed, 0);
    });
  });

  group('eliminare l\'ultima prova di un insegnamento a scelta', () {
    /// Insegnamento (a scelta o no) con le prove indicate; apre «Elimina»
    /// sulla prova [target] e restituisce servizi, id insegnamento e prova.
    Future<(AppServices, int, Exam)> setup(
      WidgetTester tester, {
      required bool elective,
      required bool withFinal,
      CourseStatus status = CourseStatus.active,
    }) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(_empty))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final c = (await tester.runAsync(
        () => s.courses.insert(
          Course(
            name: 'Robotica',
            mandatory: elective ? false : null,
            status: status,
          ),
        ),
      ))!;
      final id = (await tester.runAsync(
        () => s.exams.save(Exam(courseId: c, kind: ExamKind.midterm)),
      ))!;
      if (withFinal) {
        await tester.runAsync(() => s.exams.save(Exam(courseId: c)));
      }
      final target = (await tester.runAsync(() => s.exams.byId(id)))!;
      late BuildContext ctx;
      await _pump(
        tester,
        s,
        Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return TextButton(
                onPressed: () => deleteExamWithConfirm(ctx, target),
                child: const Text('Elimina prova'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Elimina prova'));
      await _settle(tester);
      return (s, c, target);
    }

    testWidgets('senza esame finale: avviso e «Annulla» lascia tutto com\'è', (
      tester,
    ) async {
      final (s, c, target) = await setup(
        tester,
        elective: true,
        withFinal: false,
      );
      expect(find.text('Eliminare la prova?'), findsOneWidget);
      expect(find.textContaining('è un insegnamento a scelta'), findsOneWidget);
      expect(
        find.textContaining('questa è la sua ultima prova'),
        findsOneWidget,
      );
      // due soli pulsanti, più la casella
      expect(find.widgetWithText(TextButton, 'Annulla'), findsOneWidget);
      expect(find.byKey(const Key('exam-delete-confirm')), findsOneWidget);
      expect(find.text('Non chiedere più'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Annulla'));
      await _settle(tester);
      expect(await tester.runAsync(() => s.exams.byId(target.id!)), isNotNull);
      expect(
        (await tester.runAsync(() => s.courses.byId(c)))!.status,
        CourseStatus.active,
      );
    });

    testWidgets('«Non chiedere più» non salta l\'avviso dell\'insegnamento a '
        'scelta', (tester) async {
      final (s, c, target) = await setup(
        tester,
        elective: true,
        withFinal: false,
      );
      await tester.runAsync(() => s.settings.set(kDontAskDeleteExamKey, '1'));
      // il dialogo di prima è già aperto: lo si chiude e si riprova
      await tester.tap(find.widgetWithText(TextButton, 'Annulla'));
      await _settle(tester);
      await tester.tap(find.text('Elimina prova'));
      await _settle(tester);
      expect(find.textContaining('è un insegnamento a scelta'), findsOneWidget);
      await tester.tap(find.byKey(const Key('exam-delete-confirm')));
      await _settle(tester, 10);
      expect(await tester.runAsync(() => s.exams.byId(target.id!)), isNull);
      expect(
        (await tester.runAsync(() => s.courses.byId(c)))!.status,
        CourseStatus.archived,
      );
    });

    testWidgets('con un esame finale: nessun avviso sull\'insegnamento', (
      tester,
    ) async {
      final (s, c, target) = await setup(
        tester,
        elective: true,
        withFinal: true,
      );
      expect(find.text('Eliminare la prova?'), findsOneWidget);
      expect(find.textContaining('è un insegnamento a scelta'), findsNothing);
      await tester.tap(find.byKey(const Key('exam-delete-confirm')));
      await _settle(tester, 10);
      expect(await tester.runAsync(() => s.exams.byId(target.id!)), isNull);
      expect(
        (await tester.runAsync(() => s.courses.byId(c)))!.status,
        CourseStatus.active,
      );
    });

    testWidgets('insegnamento obbligatorio: nessun avviso', (tester) async {
      await setup(tester, elective: false, withFinal: false);
      expect(find.text('Eliminare la prova?'), findsOneWidget);
      expect(find.textContaining('è un insegnamento a scelta'), findsNothing);
    });

    test('wouldDropElective segue le stesse regole di '
        'dropElectiveWithoutExam', () async {
      final s = await _empty();
      addTearDown(s.database.close);
      final elective = await s.courses.insert(
        const Course(name: 'Robotica', mandatory: false),
      );
      final required = await s.courses.insert(const Course(name: 'Fisica'));
      final mid = (await s.exams.byId(
        await s.exams.save(Exam(courseId: elective, kind: ExamKind.midterm)),
      ))!;
      final reqMid = (await s.exams.byId(
        await s.exams.save(Exam(courseId: required, kind: ExamKind.midterm)),
      ))!;
      expect(await wouldDropElective(s, mid), isTrue);
      expect(await wouldDropElective(s, reqMid), isFalse);
      final fin = (await s.exams.byId(
        await s.exams.save(Exam(courseId: elective)),
      ))!;
      // c'è un esame finale: eliminando la prova l'insegnamento resta
      expect(await wouldDropElective(s, mid), isFalse);
      // resta la prova in itinere: eliminando l'esame finale l'insegnamento
      // resta nel piano (si archivia solo senza nessuna prova)
      expect(await wouldDropElective(s, fin), isFalse);
      await s.exams.delete(mid.id!);
      // l'esame finale è l'ultima prova: eliminandolo si archivia
      expect(await wouldDropElective(s, fin), isTrue);
    });
  });
}
