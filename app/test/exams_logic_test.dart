import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/features/exams/exam_stats.dart';
import 'package:university_notes/features/exams/exam_status.dart';
import 'package:university_notes/features/exams/exam_ui.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';

void main() {
  group("stato dall'icona della prova", () {
    test('niente «Pianificato»: la chiave storica è «Da prenotare»', () {
      expect(ExamStatus.fromKey('planned').label, 'Da prenotare');
      expect(
        ExamStatus.values.map((s) => s.label),
        isNot(contains('Pianificato')),
      );
    });

    test('sempre due scelte, tutti gli stati raggiungibili', () {
      for (final s in ExamStatus.values) {
        final next = nextExamStatuses(s);
        expect(next, hasLength(2), reason: s.label);
        expect(next.map((n) => n.status), isNot(contains(s)));
      }
      // da «Da prenotare» si arriva a ogni stato. «Sostenuto» e «Esito»
      // aprono il menù del voto, che offre anche «Non superato».
      final seen = {ExamStatus.planned};
      var frontier = [ExamStatus.planned];
      while (frontier.isNotEmpty) {
        frontier = [
          for (final s in frontier)
            for (final n in nextExamStatuses(s))
              for (final to in [
                n.status,
                if (n.status == ExamStatus.taken ||
                    n.status == ExamStatus.passed)
                  ExamStatus.failed,
              ])
                if (seen.add(to)) to,
        ];
      }
      // tranne «Da completare»: solo per gli esami degli anni prima
      // dell'anno di partenza mai compilati, non si sceglie
      expect(seen, ExamStatus.values.toSet()..remove(ExamStatus.toComplete));
      // da «Da completare»: «Sostenuto» (superato, voto facoltativo) o «Da
      // sostenere» (arretrato)
      expect(nextExamStatuses(ExamStatus.toComplete).map((n) => n.status), [
        ExamStatus.passed,
        ExamStatus.planned,
      ]);
    });

    test('dopo l\'esito (in attesa o con il voto) si torna a «Prenotato»', () {
      for (final s in [ExamStatus.taken, ExamStatus.passed]) {
        expect(
          nextExamStatuses(s).map((n) => n.status),
          contains(ExamStatus.booked),
          reason: s.label,
        );
      }
      // e da «Prenotato» a «Da prenotare»: catena all'indietro completa
      var s = ExamStatus.passed;
      final back = [s];
      while (s != ExamStatus.planned) {
        s = nextExamStatuses(s)
            .map((n) => n.status)
            .firstWhere(
              (n) =>
                  n == ExamStatus.booked ||
                  (s == ExamStatus.booked && n == ExamStatus.planned),
            );
        back.add(s);
      }
      expect(back, [ExamStatus.passed, ExamStatus.booked, ExamStatus.planned]);
    });

    test('lo stato scelto toglie il voto', () {
      const e = Exam(
        courseId: 1,
        status: ExamStatus.passed,
        grade: 30,
        laude: true,
      );
      final b = withStatus(e, ExamStatus.booked);
      expect(b.status, ExamStatus.booked);
      expect(b.grade, isNull);
      expect(b.laude, isFalse);
    });

    test('colore della card del corso: segue lo stato della prova', () {
      CourseExamGroup g(List<Exam> exams) =>
          CourseExamGroup(const Course(id: 1, name: 'A'), 1, exams);
      expect(
        g([const Exam(courseId: 1, status: ExamStatus.failed)]).headlineStatus,
        ExamStatus.failed,
      );
      // non superato e poi superato: vale il superato
      expect(
        g([
          const Exam(courseId: 1, status: ExamStatus.failed),
          const Exam(courseId: 1, status: ExamStatus.passed, grade: 24),
        ]).headlineStatus,
        ExamStatus.passed,
      );
      // solo prove in itinere: l'ultima
      expect(
        g([
          const Exam(
            courseId: 1,
            kind: ExamKind.midterm,
            status: ExamStatus.taken,
          ),
        ]).headlineStatus,
        ExamStatus.taken,
      );
      expect(g(const []).headlineStatus, isNull);
    });
  });

  group('validateExamGrade', () {
    test('stato superato: voto tra 18 e 30, oppure nessun voto (idoneità)', () {
      expect(validateExamGrade(ExamStatus.passed, null, false), isNull);
      expect(validateExamGrade(ExamStatus.passed, 17, false), isNotNull);
      expect(validateExamGrade(ExamStatus.passed, 31, false), isNotNull);
      expect(validateExamGrade(ExamStatus.passed, 18, false), isNull);
      expect(validateExamGrade(ExamStatus.passed, 30, false), isNull);
    });

    test('lode solo con 30', () {
      expect(validateExamGrade(ExamStatus.passed, 29, true), isNotNull);
      expect(validateExamGrade(ExamStatus.passed, 30, true), isNull);
    });

    test('nessun voto se lo stato non è superato', () {
      for (final s in ExamStatus.values.where((s) => s != ExamStatus.passed)) {
        expect(validateExamGrade(s, null, false), isNull, reason: s.key);
        expect(validateExamGrade(s, 25, false), isNotNull, reason: s.key);
        expect(validateExamGrade(s, null, true), isNotNull, reason: s.key);
      }
    });
  });

  group('statistiche esami', () {
    final courses = {
      1: const Course(id: 1, name: 'Analisi I', cfu: 10),
      2: const Course(id: 2, name: 'Basi di dati', cfu: 6),
    };

    test('CFU acquisiti includono gli esami superati senza voto', () {
      final exams = [
        const Exam(courseId: 1, status: ExamStatus.passed, grade: 28),
        const Exam(courseId: 2, status: ExamStatus.passed),
        const Exam(
          courseId: 2,
          kind: ExamKind.midterm,
          status: ExamStatus.passed,
          grade: 30,
        ),
        const Exam(courseId: 1, status: ExamStatus.failed),
      ];
      expect(acquiredCfu(exams, courses), 16);
    });

    test('raggruppamento per corso separa finali e prove in itinere', () {
      final groups = groupByCourse([
        const Exam(courseId: 2, kind: ExamKind.midterm, grade: 24),
        const Exam(courseId: 2, kind: ExamKind.midterm, grade: 28),
        const Exam(courseId: 2, status: ExamStatus.passed, grade: 27),
        const Exam(courseId: 1, status: ExamStatus.failed),
      ], courses);
      expect(groups.map((g) => g.name), ['Analisi I', 'Basi di dati']);
      final db = groups[1];
      expect(db.finals, hasLength(1));
      expect(db.midterms, hasLength(2));
      expect(db.midtermAvg, 26);
      expect(db.passedFinal?.grade, 27);
    });

    test('ordinamento per data con le prove senza data in fondo', () {
      final sorted = sortByDate([
        const Exam(courseId: 1, title: 'senza data'),
        Exam(
          courseId: 1,
          title: 'b',
          date: DateTime(2026, 12, 1),
          time: '14:00',
        ),
        Exam(
          courseId: 1,
          title: 'a',
          date: DateTime(2026, 12, 1),
          time: '09:00',
        ),
      ]);
      expect(sorted.map((e) => e.title), ['a', 'b', 'senza data']);
    });

    test("senza data: per nome dell'insegnamento (maiuscole ignorate)", () {
      const courses = {
        1: Course(id: 1, name: 'fisica I'),
        2: Course(id: 2, name: 'Analisi I'),
        3: Course(id: 3, name: 'Chimica'),
      };
      final sorted = sortByDate([
        const Exam(courseId: 1),
        const Exam(courseId: 3),
        Exam(courseId: 1, title: 'datata', date: DateTime(2027, 1, 20)),
        const Exam(courseId: 2),
      ], courses);
      expect(sorted.map((e) => e.title ?? courses[e.courseId]!.name), [
        'datata',
        'Analisi I',
        'Chimica',
        'fisica I',
      ]);
    });
  });

  group('formattazione', () {
    test('data italiana e voto', () {
      expect(formatDate(DateTime(2026, 11, 12)), 'gio 12/11/2026');
      expect(
        gradeLabel(const Exam(courseId: 1, grade: 30, laude: true)),
        '30 e lode',
      );
      expect(gradeLabel(const Exam(courseId: 1)), isNull);
    });

    test('riconosce i percorsi locali', () {
      expect(looksLikePath(r'D:\Materiale\L01.pdf'), isTrue);
      expect(looksLikePath('/home/u/file.pdf'), isTrue);
      expect(looksLikePath('Lezioni 1-8 (slide)'), isFalse);
      expect(pathBaseName(r'D:\Materiale\L01.pdf'), 'L01.pdf');
    });
  });
}
