import '../core/constants/enums.dart';
import '../models/course.dart';
import '../models/exam.dart';

/// Risultato del calcolo medie.
class AverageResult {
  const AverageResult({
    required this.weightedAverage,
    required this.arithmeticAverage,
    required this.totalCfu,
    required this.count,
  });

  /// Media ponderata sui CFU (null se nessun voto).
  final double? weightedAverage;
  final double? arithmeticAverage;
  final double totalCfu;
  final int count;

  /// Voto di partenza alla laurea (media ponderata * 110 / 30).
  double? get graduationBase =>
      weightedAverage == null ? null : weightedAverage! * 110 / 30;
}

/// Media ponderata degli esami **finali superati** con voto.
/// La lode vale 30 (convenzione più comune; alcuni regolamenti la valutano
/// diversamente: [laudeValue] permette di cambiarla).
AverageResult weightedAverage(
  Iterable<Exam> exams,
  Map<int, Course> courses, {
  double laudeValue = 30,
}) {
  var sum = 0.0;
  var sumW = 0.0;
  var plain = 0.0;
  var n = 0;
  // un solo esame superato per corso (il più recente); i corsi archiviati
  // non contano
  final latest = <int, Exam>{};
  final others = <Exam>[];
  for (final e in exams) {
    if (e.kind != ExamKind.finalExam || e.status != ExamStatus.passed) continue;
    if (courses[e.courseId]?.status == CourseStatus.archived) continue;
    if (!courses.containsKey(e.courseId)) {
      others.add(e);
      continue;
    }
    final prev = latest[e.courseId];
    if (prev == null || _after(e, prev)) latest[e.courseId] = e;
  }
  for (final e in [...latest.values, ...others]) {
    // Una lode senza voto esplicito vale comunque 30 e lode.
    if (e.grade == null && !e.laude) continue;
    final g = e.laude ? laudeValue : e.grade!.toDouble();
    final w = e.cfu ?? courses[e.courseId]?.cfu ?? 0;
    plain += g;
    n++;
    if (w > 0) {
      sum += g * w;
      sumW += w;
    }
  }
  return AverageResult(
    weightedAverage: sumW > 0 ? sum / sumW : null,
    arithmeticAverage: n > 0 ? plain / n : null,
    totalCfu: sumW,
    count: n,
  );
}

bool _after(Exam a, Exam b) {
  final da = a.date, db = b.date;
  if (da != null && db != null && da != db) return da.isAfter(db);
  return (a.id ?? 0) > (b.id ?? 0);
}

/// Media delle prove in itinere di un corso (ponderata uniformemente).
/// Le prove annullate non contano.
double? midtermAverage(Iterable<Exam> exams, {double laudeValue = 30}) {
  final graded = exams
      .where(
        (e) =>
            e.kind == ExamKind.midterm &&
            e.status != ExamStatus.cancelled &&
            (e.grade != null || e.laude),
      )
      .map((e) => e.laude ? laudeValue : e.grade!.toDouble())
      .toList();
  if (graded.isEmpty) return null;
  return graded.reduce((a, b) => a + b) / graded.length;
}

/// Progresso del corso 0..1 in base agli stati degli argomenti.
double courseProgress(Iterable<TopicStatus> statuses) {
  final list = statuses.toList();
  if (list.isEmpty) return 0;
  return list.map((s) => s.progressWeight).reduce((a, b) => a + b) /
      list.length;
}
