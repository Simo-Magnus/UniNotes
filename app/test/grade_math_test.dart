import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/utils/grade_math.dart';

Exam _exam(
  int courseId, {
  int? grade,
  bool laude = false,
  ExamStatus status = ExamStatus.passed,
  ExamKind kind = ExamKind.finalExam,
  double? cfu,
}) => Exam(
  courseId: courseId,
  grade: grade,
  laude: laude,
  status: status,
  kind: kind,
  cfu: cfu,
);

void main() {
  final courses = {
    1: const Course(id: 1, name: 'Analisi I', cfu: 10),
    2: const Course(id: 2, name: 'Fisica I', cfu: 6),
    3: const Course(id: 3, name: 'Informatica', cfu: 8),
    4: const Course(id: 4, name: 'Senza CFU'),
  };

  group('weightedAverage', () {
    test('pondera sui CFU e calcola anche la media aritmetica', () {
      final r = weightedAverage([
        _exam(1, grade: 24),
        _exam(2, grade: 30),
      ], courses);
      expect(r.weightedAverage, closeTo((24 * 10 + 30 * 6) / 16, 1e-9));
      expect(r.arithmeticAverage, 27);
      expect(r.totalCfu, 16);
      expect(r.count, 2);
      expect(r.graduationBase, closeTo(r.weightedAverage! * 110 / 30, 1e-9));
    });

    test('la lode vale 30 (o il valore indicato)', () {
      final exams = [_exam(1, grade: 30, laude: true), _exam(2, grade: 27)];
      final r = weightedAverage(exams, courses);
      expect(r.weightedAverage, closeTo((30 * 10 + 27 * 6) / 16, 1e-9));
      final r33 = weightedAverage(exams, courses, laudeValue: 33);
      expect(r33.weightedAverage, closeTo((33 * 10 + 27 * 6) / 16, 1e-9));
    });

    test('lode senza voto esplicito conta come 30 e lode', () {
      final r = weightedAverage([_exam(1, laude: true)], courses);
      expect(r.weightedAverage, 30);
    });

    test('esclude esami non superati, pianificati e prove in itinere', () {
      final r = weightedAverage([
        _exam(1, grade: 28),
        _exam(2, grade: 18, status: ExamStatus.failed),
        _exam(2, grade: 20, status: ExamStatus.taken),
        _exam(3, status: ExamStatus.planned),
        _exam(3, grade: 30, kind: ExamKind.midterm),
        _exam(3, status: ExamStatus.passed), // superato senza voto (idoneità)
      ], courses);
      expect(r.weightedAverage, 28);
      expect(r.count, 1);
      expect(r.totalCfu, 10);
    });

    test(
      'senza CFU sull\'esame usa quelli del corso; CFU esame prevalgono',
      () {
        final fallback = weightedAverage([
          _exam(1, grade: 20),
          _exam(3, grade: 30),
        ], courses);
        expect(
          fallback.weightedAverage,
          closeTo((20 * 10 + 30 * 8) / 18, 1e-9),
        );
        final override = weightedAverage([
          _exam(1, grade: 20, cfu: 2),
          _exam(3, grade: 30),
        ], courses);
        expect(override.weightedAverage, closeTo((20 * 2 + 30 * 8) / 10, 1e-9));
      },
    );

    test(
      'corso senza CFU: entra nella media aritmetica ma non nella ponderata',
      () {
        final r = weightedAverage([
          _exam(4, grade: 18),
          _exam(2, grade: 30),
        ], courses);
        expect(r.weightedAverage, 30);
        expect(r.arithmeticAverage, 24);
        expect(r.totalCfu, 6);
      },
    );

    test('nessun voto: medie nulle', () {
      final r = weightedAverage(const [], courses);
      expect(r.weightedAverage, isNull);
      expect(r.arithmeticAverage, isNull);
      expect(r.graduationBase, isNull);
      expect(r.count, 0);
    });
  });

  group('midtermAverage', () {
    test('media semplice delle sole prove in itinere con voto', () {
      final avg = midtermAverage([
        _exam(1, grade: 26, kind: ExamKind.midterm),
        _exam(1, grade: 30, laude: true, kind: ExamKind.midterm),
        _exam(1, grade: 18), // finale: escluso
        _exam(1, kind: ExamKind.midterm, status: ExamStatus.planned),
        _exam(
          1,
          grade: 20,
          kind: ExamKind.midterm,
          status: ExamStatus.cancelled,
        ),
      ]);
      expect(avg, 28);
    });

    test('null se non ci sono prove valutate', () {
      expect(midtermAverage([_exam(1, grade: 30)]), isNull);
    });
  });

  group('courseProgress', () {
    test('vuoto = 0', () => expect(courseProgress(const []), 0));
    test('tutti completati = 1', () {
      expect(courseProgress([TopicStatus.completed, TopicStatus.completed]), 1);
    });
    test('media dei pesi degli stati', () {
      final p = courseProgress([
        TopicStatus.notStarted,
        TopicStatus.inProgress,
        TopicStatus.partial,
        TopicStatus.completed,
        TopicStatus.toReview,
      ]);
      expect(p, closeTo((0 + 0.4 + 0.7 + 1 + 0.85) / 5, 1e-9));
    });
  });
}
