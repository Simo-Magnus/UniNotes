import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/academic/plan_scope.dart';
import 'package:university_notes/core/academic/academic_year.dart';
import 'package:university_notes/core/academic/course_status_sync.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';

void main() {
  CourseStatus derive(
    Course c, {
    bool passed = false,
    int? year = 2,
    bool fuori = false,
    DateTime? now,
  }) => deriveCourseStatus(
    c,
    passed: passed,
    currentYear: year,
    fuoriCorso: fuori,
    now: now ?? DateTime(2026, 11, 10),
  );

  test('semestre attuale dal calendario', () {
    expect(currentSemester(DateTime(2026, 10, 1)), '1');
    expect(currentSemester(DateTime(2027, 1, 20)), '1');
    expect(currentSemester(DateTime(2027, 3, 1)), '2');
    expect(currentSemester(DateTime(2027, 8, 1)), '2');
  });

  test('stati automatici dell\'insegnamento', () {
    const c = Course(name: 'Analisi', year: 2, semester: '1');
    expect(derive(c), CourseStatus.active);
    expect(derive(c, now: DateTime(2027, 3, 1)), CourseStatus.toTake);
    expect(
      derive(const Course(name: 'x', year: 2, semester: '2')),
      CourseStatus.upcoming,
    );
    expect(derive(const Course(name: 'x', year: 1)), CourseStatus.toTake);
    expect(derive(const Course(name: 'x', year: 3)), CourseStatus.upcoming);
    expect(
      derive(const Course(name: 'x', year: 2, semester: 'annuale')),
      CourseStatus.active,
    );
    expect(derive(c, passed: true), CourseStatus.completed);
    expect(
      derive(const Course(name: 'x', year: 2), fuori: true),
      CourseStatus.toTake,
    );
    expect(derive(const Course(name: 'x')), CourseStatus.active);
    // l'archivio lo decide lo studente
    expect(
      derive(const Course(name: 'x', year: 1, status: CourseStatus.archived)),
      CourseStatus.archived,
    );
    // vecchio stato «non frequentato»: si ricalcola
    expect(CourseStatus.fromKey('not_attended'), CourseStatus.active);
  });

  test('sincronizzazione nel database', () async {
    final db = await AppDatabase.openInMemory();
    final s = AppServices(db);
    await s.profiles.replace(
      const StudentProfile(
        universityId: 'polito',
        universityName: 'Politecnico di Torino',
        degreeId: 'polito-l-8',
        degreeName: 'Ingegneria Informatica',
        degreeType: 'L',
        durationYears: 3,
        currentYear: 2,
        referenceAa: AcademicYear(2026),
      ),
    );
    final a = await s.courses.insert(
      const Course(name: 'Analisi I', year: 1, semester: '1'),
    );
    final b = await s.courses.insert(
      const Course(name: 'Fisica II', year: 2, semester: '1'),
    );
    await s.exams.insert(
      Exam(courseId: a, status: ExamStatus.passed, grade: 28),
    );
    await syncCourseStatuses(s, now: DateTime(2026, 11, 10));
    final byId = {for (final c in await s.courses.all()) c.id: c.status};
    expect(byId[a], CourseStatus.completed);
    expect(byId[b], CourseStatus.active);
    await db.close();
  });

  test('cambio di corso di laurea: i dati del corso precedente restano nascosti', () async {
    final db = await AppDatabase.openInMemory();
    final s = AppServices(db);
    await db.db.insert('universities', {
      'id': 'polito',
      'name': 'PoliTo',
      'short_name': 'PoliTo',
      'color': 1,
    });
    await db.db.insert('universities', {
      'id': 'unito',
      'name': 'UniTo',
      'short_name': 'UniTo',
      'color': 2,
    });
    final old = await s.courses.insert(
      const Course(
        name: 'Chimica',
        universityId: 'polito',
        degreeId: 'polito-l-8',
      ),
    );
    await s.exams.insert(Exam(courseId: old, status: ExamStatus.planned));
    final manual = await s.courses.insert(const Course(name: 'a mano'));
    final keep = await s.courses.insert(
      const Course(
        name: 'Psicometria',
        universityId: 'unito',
        degreeId: 'unito-l-24',
      ),
    );
    const previous = StudentProfile(
      universityId: 'polito',
      universityName: 'Politecnico di Torino',
      degreeId: 'polito-l-8',
      degreeName: 'Ingegneria informatica',
      degreeType: 'L',
      durationYears: 3,
      currentYear: 1,
      referenceAa: AcademicYear(2026),
    );
    const profile = StudentProfile(
      universityId: 'unito',
      universityName: 'Università di Torino',
      degreeId: 'unito-l-24',
      degreeName: 'Scienze e tecniche psicologiche',
      degreeType: 'L',
      durationYears: 3,
      currentYear: 1,
      referenceAa: AcademicYear(2026),
    );
    final hidden = await PathSetupService(s).hideOtherPaths(previous, profile);
    expect(hidden, 2);
    // niente si elimina: esami e atenei restano
    final all = await s.courses.all();
    expect(all, hasLength(3));
    expect(await s.exams.all(), hasLength(1));
    expect(await db.db.query('universities'), hasLength(2));
    // l'insegnamento a mano passa al corso precedente
    expect(
      all.firstWhere((c) => c.id == manual).degreeId,
      'polito-l-8',
    );
    // si vede solo il nuovo corso di laurea; tornando indietro, il vecchio
    const scope = PlanScope(profile: profile);
    expect([for (final c in all) if (scope.inPath(c)) c.id], [keep]);
    const back = PlanScope(profile: previous);
    expect(
      [for (final c in all) if (back.inPath(c)) c.id],
      unorderedEquals([old, manual]),
    );
    await db.close();
  });
}
