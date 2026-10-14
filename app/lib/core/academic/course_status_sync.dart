import '../../models/course.dart';
import '../constants/enums.dart';
import '../services/app_services.dart';

/// Semestre in corso secondo il calendario: il primo va da settembre a
/// gennaio (lezioni ed esami della sessione invernale), il secondo da
/// febbraio ad agosto.
String currentSemester(DateTime now) =>
    (now.month >= 9 || now.month == 1) ? '1' : '2';

/// Stato di un insegnamento calcolato dall'app (vedi [CourseStatus]):
/// - **Superato** se l'esame finale è superato;
/// - **Archiviato** resta come l'ha scelto lo studente;
/// - rispetto all'anno di corso che frequenti ([currentYear]) e al
///   semestre attuale: **In corso** (anno e semestre attuali, o annuale),
///   **Da sostenere** (lezioni già finite: anni o semestri precedenti, o
///   fuori corso), **Non ancora iniziato** (anni o semestri successivi).
/// Senza anno nel piano l'insegnamento resta «In corso».
CourseStatus deriveCourseStatus(
  Course c, {
  required bool passed,
  required int? currentYear,
  required bool fuoriCorso,
  required DateTime now,
}) {
  if (c.status == CourseStatus.archived) return CourseStatus.archived;
  if (passed) return CourseStatus.completed;
  final y = c.year;
  if (y == null || currentYear == null) return CourseStatus.active;
  if (fuoriCorso) {
    return y <= currentYear ? CourseStatus.toTake : CourseStatus.upcoming;
  }
  if (y < currentYear) return CourseStatus.toTake;
  if (y > currentYear) return CourseStatus.upcoming;
  final sem = c.semester;
  final now1 = currentSemester(now);
  if (sem == '1' && now1 == '2') return CourseStatus.toTake;
  if (sem == '2' && now1 == '1') return CourseStatus.upcoming;
  return CourseStatus.active;
}

/// Aggiorna nel database lo stato di tutti gli insegnamenti (solo quelli
/// cambiati). Si chiama prima di mostrare elenchi di corsi; non avvisa le
/// schermate (nessun `revision.bump`). Restituisce quanti sono cambiati.
Future<int> syncCourseStatuses(AppServices s, {DateTime? now}) async {
  final profile = await s.profiles.load();
  final passed = {
    for (final e in await s.exams.byStatus([ExamStatus.passed]))
      if (e.kind == ExamKind.finalExam) e.courseId,
  };
  final t = now ?? DateTime.now();
  var changed = 0;
  for (final c in await s.courses.all()) {
    final next = deriveCourseStatus(
      c,
      passed: c.id != null && passed.contains(c.id),
      currentYear: profile?.currentYear,
      fuoriCorso: profile?.fuoriCorso ?? false,
      now: t,
    );
    if (next != c.status) {
      await s.courses.update(c.copyWith(status: next));
      changed++;
    }
  }
  return changed;
}
