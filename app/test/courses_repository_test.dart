import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/features/courses/course_list.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/models/university.dart';
import 'package:university_notes/repositories/book_repository.dart';
import 'package:university_notes/repositories/course_repository.dart';
import 'package:university_notes/repositories/exam_repository.dart';
import 'package:university_notes/utils/grade_math.dart';

void main() {
  late AppDatabase db;
  late CourseRepository courses;
  late ExamRepository exams;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    courses = CourseRepository(db);
    exams = ExamRepository(db);
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
      'universities',
      const University(
        id: 'unito',
        name: 'Università di Torino',
        shortName: 'UniTO',
        color: 0xFFC62828,
      ).toMap(),
    );
    await db.db.insert(
      'degrees',
      const Degree(
        id: 'polito:ing-informatica',
        universityId: 'polito',
        name: 'Ingegneria Informatica',
        maxGraduationScore: '110/110 e lode',
        source: 'https://www.polito.it',
        updatedAt: '2026-10-01',
      ).toMap(),
    );
  });
  tearDown(() => db.close());

  test('salva, modifica ed elimina un corso con tutti i campi', () async {
    final id = await courses.save(
      const Course(
        name: 'Analisi matematica I',
        code: '01RKCPL',
        teacher: 'Prof. Rossi',
        universityId: 'polito',
        degreeId: 'polito:ing-informatica',
        year: 1,
        semester: '1',
        cfu: 10,
        description: 'Limiti, derivate, integrali',
        color: 0xFF2E7D32,
        difficulty: 4.5,
        examMode: 'scritto+orale',
      ),
    );
    var c = (await courses.byId(id))!;
    expect(c.name, 'Analisi matematica I');
    expect(c.degreeId, 'polito:ing-informatica');
    expect(c.color, 0xFF2E7D32);
    expect(c.difficulty, 4.5);
    expect(c.status, CourseStatus.active);

    await courses.save(c.copyWith(status: CourseStatus.completed, cfu: 12));
    c = (await courses.byId(id))!;
    expect(c.status, CourseStatus.completed);
    expect(c.cfu, 12);
    expect((await courses.mapById()).keys, [id]);

    await courses.delete(id);
    expect(await courses.byId(id), isNull);
  });

  test('università indicizzate e corsi di laurea per università', () async {
    final unis = await courses.universitiesById();
    expect(unis['polito']!.shortName, 'PoliTo');
    expect(unis['unito']!.color, 0xFFC62828);
    expect(await courses.degreesOf('polito'), hasLength(1));
    expect(await courses.degreesOf('unito'), isEmpty);
  });

  test('esami e prove in itinere: save, byStatus, byCourse, medie', () async {
    final cid = await courses.save(
      const Course(name: 'Fisica I', universityId: 'polito', cfu: 8),
    );
    final m1 = await exams.save(
      Exam(
        courseId: cid,
        kind: ExamKind.midterm,
        title: 'Prima prova',
        date: DateTime(2026, 11, 12),
        time: '14:00',
        status: ExamStatus.passed,
        grade: 26,
        studyMaterials: const ['Lezioni 1-8', r'D:\Fisica\L01.pdf'],
      ),
    );
    await exams.save(
      Exam(
        courseId: cid,
        kind: ExamKind.midterm,
        title: 'Seconda prova',
        date: DateTime(2026, 12, 15),
        status: ExamStatus.passed,
        grade: 30,
        laude: true,
      ),
    );
    final finalId = await exams.save(
      Exam(
        courseId: cid,
        date: DateTime(2027, 1, 20),
        status: ExamStatus.booked,
      ),
    );

    final m = (await exams.byId(m1))!;
    expect(m.studyMaterials, ['Lezioni 1-8', r'D:\Fisica\L01.pdf']);
    expect(m.dateTime, DateTime(2026, 11, 12, 14));

    expect(await exams.byStatus([ExamStatus.booked]), hasLength(1));
    expect(await exams.byStatus(const []), isEmpty);

    final all = await exams.byCourse(cid);
    expect(all.map((e) => e.kind), [
      ExamKind.midterm,
      ExamKind.midterm,
      ExamKind.finalExam,
    ]);
    expect(midtermAverage(all), 28);

    // Registra il voto finale (update tramite save).
    final booked = (await exams.byId(finalId))!;
    await exams.save(booked.copyWith(status: ExamStatus.passed, grade: 27));
    final avg = weightedAverage(await exams.all(), await courses.mapById());
    expect(avg.weightedAverage, 27);
    expect(avg.totalCfu, 8);
  });

  test(
    'eliminare un corso elimina esami e materiali, scollega i libri',
    () async {
      final cid = await courses.save(const Course(name: 'Chimica'));
      final books = BookRepository(db);
      await exams.save(Exam(courseId: cid));
      await books.insert(Book(courseId: cid, title: 'Chimica generale'));
      await books.insertMaterial(StudyMaterial(courseId: cid, title: 'L1.pdf'));

      await courses.delete(cid);
      expect(await exams.all(), isEmpty);
      expect(await books.materials(), isEmpty);
      final remaining = await books.all();
      expect(remaining.single.courseId, isNull);
    },
  );

  test('raggruppamento e filtri della lista corsi', () async {
    final unis = await courses.universitiesById();
    const list = [
      Course(
        id: 1,
        name: 'Psicologia generale',
        universityId: 'unito',
        year: 1,
        semester: '2',
      ),
      Course(
        id: 2,
        name: 'Analisi I',
        universityId: 'polito',
        year: 1,
        semester: '1',
        teacher: 'Rossi',
      ),
      Course(
        id: 3,
        name: 'Fisica I',
        universityId: 'polito',
        year: 1,
        semester: '2',
      ),
      Course(
        id: 4,
        name: 'Algebra',
        universityId: 'polito',
        year: 1,
        semester: '1',
        status: CourseStatus.archived,
      ),
    ];
    final groups = groupCourses(list, unis);
    expect(groups.map((g) => g.universityId), ['polito', 'unito']);
    expect(groups.first.periods.map((p) => p.semester), ['1', '2']);
    expect(groups.first.periods.first.courses.map((c) => c.name), [
      'Algebra',
      'Analisi I',
    ]);

    const filter = CourseFilter();
    expect(list.where(filter.matches).map((c) => c.id), [1, 2, 3]);
    expect(
      list.where(filter.copyWith(query: 'rossi').matches).map((c) => c.id),
      [2],
    );
    expect(
      list
          .where(filter.copyWith(universityId: 'unito').matches)
          .map((c) => c.id),
      [1],
    );
    expect(
      list
          .where(filter.copyWith(statuses: {CourseStatus.archived}).matches)
          .map((c) => c.id),
      [4],
    );
    // nessuno stato scelto = tutti (non c'è «Tutti»)
    expect(list.where(filter.copyWith(statuses: {}).matches).map((c) => c.id), [
      1,
      2,
      3,
      4,
    ]);
    expect(filter.statuses, {CourseStatus.active});
  });
}
