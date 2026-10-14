import '../../models/course.dart';
import '../../models/exam.dart';
import '../constants/enums.dart';
import 'student_profile.dart';

/// Esito di un insegnamento nella schermata "Segna come completato".
enum GradeKind {
  /// Voto in trentesimi (18–30, eventuale lode).
  grade('Voto'),

  /// Esame senza voto: idoneità / superato.
  pass('Idoneità');

  const GradeKind(this.label);
  final String label;
}

/// L'esame finale conta come superato (con voto, lode o idoneità).
bool isFinalPassed(Exam e) =>
    e.kind == ExamKind.finalExam && e.status == ExamStatus.passed;

/// Quanto è completo un anno del piano.
class YearCompletion {
  YearCompletion._(this.done, this.missing);

  /// Valuta i [courses] dell'anno con i loro esami: un insegnamento è
  /// completato se ha un esame finale superato (voto, lode o idoneità).
  factory YearCompletion.evaluate(
    Iterable<Course> courses,
    Iterable<Exam> exams,
  ) {
    final passed = {
      for (final e in exams)
        if (isFinalPassed(e)) e.courseId,
    };
    final done = <Course>[];
    final missing = <Course>[];
    for (final c in courses) {
      (passed.contains(c.id) ? done : missing).add(c);
    }
    return YearCompletion._(done, missing);
  }

  final List<Course> done;
  final List<Course> missing;

  int get total => done.length + missing.length;
  bool get isComplete => missing.isEmpty;

  /// `completato` se ogni esame ha un esito, altrimenti `completato_parziale`.
  PlanYearStatus get status => isComplete
      ? PlanYearStatus.completato
      : PlanYearStatus.completatoParziale;

  /// "Mancano 2 esami: Fisica I, Chimica" (vuoto se completo).
  String get missingSummary {
    if (missing.isEmpty) return '';
    final names = missing.map((c) => c.name).take(3).join(', ');
    final more = missing.length > 3 ? '…' : '';
    return missing.length == 1
        ? 'Manca 1 esame: $names'
        : 'Mancano ${missing.length} esami: $names$more';
  }
}

/// Voto valido in trentesimi.
bool isValidGrade(int? g) => g != null && g >= 18 && g <= 30;
