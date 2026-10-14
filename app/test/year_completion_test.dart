import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/academic/plan_scope.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/academic/year_completion.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/features/academic/year_grades_screen.dart';
import 'package:university_notes/features/exams/exam_stats.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';

import 'support/plan_services.dart';

void main() {
  test('completato / completato in parte (logica pura)', () {
    const a = Course(id: 1, name: 'Analisi', cfu: 10);
    const f = Course(id: 2, name: 'Fisica', cfu: 8);
    final none = YearCompletion.evaluate([a, f], const []);
    expect(none.status, PlanYearStatus.completatoParziale);
    expect(none.missingSummary, 'Mancano 2 esami: Analisi, Fisica');
    final partial = YearCompletion.evaluate(
      [a, f],
      const [
        Exam(courseId: 1, status: ExamStatus.passed, grade: 27),
        // Una prova in itinere non completa l'insegnamento.
        Exam(courseId: 2, kind: ExamKind.midterm, status: ExamStatus.passed),
      ],
    );
    expect(partial.status, PlanYearStatus.completatoParziale);
    expect(partial.missingSummary, 'Manca 1 esame: Fisica');
    final done = YearCompletion.evaluate(
      [a, f],
      const [
        Exam(courseId: 1, status: ExamStatus.passed, grade: 27),
        // Idoneità: superato senza voto.
        Exam(courseId: 2, status: ExamStatus.passed),
      ],
    );
    expect(done.status, PlanYearStatus.completato);
    expect(isValidGrade(17), isFalse);
    expect(isValidGrade(30), isTrue);
  });

  test('voti del 1° anno: in parte, poi completato; medie per anno', () async {
    final s = await planServices();
    addTearDown(s.database.close);
    final courses = await yearCourses(s, 1);
    expect(
      [for (final c in courses) c.name],
      ['Analisi matematica I', 'Fisica I'],
    );
    final exams = await s.exams.all();
    Exam finalOf(Course c) => exams.singleWhere(
      (e) => e.courseId == c.id && e.kind == ExamKind.finalExam,
    );

    // Solo Analisi: 30 e lode.
    final entries = [for (final c in courses) GradeEntry(c, finalOf(c))];
    entries[0]
      ..grade = 30
      ..laude = true;
    var r = await saveYearGrades(s, 1, entries, markYear: true);
    expect(r.status, PlanYearStatus.completatoParziale);
    expect(
      (await s.profiles.planYear(1))!.status,
      PlanYearStatus.completatoParziale,
    );

    // Fisica come idoneità, CFU corretti a mano (9 invece di 8).
    final again = [
      for (final c in courses)
        GradeEntry(
          c,
          (await s.exams.all()).singleWhere(
            (e) => e.courseId == c.id && e.kind == ExamKind.finalExam,
          ),
        ),
    ];
    expect(again[0].grade, 30);
    expect(again[0].laude, isTrue);
    again[1]
      ..kind = GradeKind.pass
      ..passed = true
      ..cfu = 9;
    r = await saveYearGrades(s, 1, again, markYear: true);
    expect(r.status, PlanYearStatus.completato);
    expect((await s.profiles.planYear(1))!.status, PlanYearStatus.completato);

    final data = await loadExamsData(s);
    final fisica = data.exams.singleWhere(
      (e) => e.courseId == courses[1].id && e.kind == ExamKind.finalExam,
    );
    expect(fisica.status, ExamStatus.passed);
    expect(fisica.grade, isNull);
    expect(fisica.cfu, 9);

    // Media: solo Analisi (30, 10 CFU); l'idoneità conta nei CFU.
    final year1 = AverageSummary(
      '1° anno',
      data.pathExams.where((e) => data.courses[e.courseId]?.year == 1),
      data.courses,
    );
    expect(year1.result.weightedAverage, 30);
    expect(year1.result.graduationBase, 110);
    expect(year1.cfu, 19);
    final year2 = AverageSummary(
      '2° anno',
      data.pathExams.where((e) => data.courses[e.courseId]?.year == 2),
      data.courses,
    );
    expect(year2.result.weightedAverage, isNull);

    // Un voto in un anno futuro (esame anticipato) non cambia lo stato.
    final y3 = await yearCourses(s, 3);
    final e3 = [for (final c in y3) GradeEntry(c, finalOf(c))];
    e3.single.grade = 24;
    await saveYearGrades(s, 3, e3, markYear: false);
    expect((await s.profiles.planYear(3))!.status, PlanYearStatus.futuro);
    final overall = AverageSummary(
      'Complessiva',
      (await loadExamsData(s)).pathExams,
      data.courses,
    );
    // (30×10 + 24×6) / 16 = 27,75
    expect(overall.result.weightedAverage, closeTo(27.75, 1e-9));
  });

  test('il filtro di anno mostra i corsi giusti', () async {
    final s = await planServices();
    addTearDown(s.database.close);
    final all = await s.courses.all();
    final scope1 = PlanScope(profile: s.profile.value, year: 1);
    expect(all.where(scope1.includes), hasLength(2));
    final scope2 = PlanScope(profile: s.profile.value, year: 2);
    expect(
      all.where(scope2.includes).single.name,
      'Algoritmi e programmazione',
    );
    // Corso aggiunto a mano senza anno: in tutti gli anni.
    expect(scope2.includes(const Course(name: 'Extra')), isTrue);
    // Corso di un altro corso di laurea: mai.
    expect(
      scope2.includes(const Course(name: 'Altro', degreeId: 'x', year: 2)),
      isFalse,
    );
    expect(
      PlanScope.all.includes(const Course(name: 'x', degreeId: 'y')),
      isTrue,
    );
  });
}
