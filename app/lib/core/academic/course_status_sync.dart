import 'dart:async';

import '../../models/course.dart';
import '../../models/exam.dart';
import '../../repositories/exam_repository.dart';
import '../constants/enums.dart';
import '../services/app_services.dart';
import '../services/error_log.dart';

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
/// **Da completare** se l'esame finale è «Da completare» ([toComplete]: anno
/// prima dell'anno di partenza, non ancora compilato dallo studente).
CourseStatus deriveCourseStatus(
  Course c, {
  required bool passed,
  required int? currentYear,
  required bool fuoriCorso,
  required DateTime now,
  bool toComplete = false,
}) {
  if (c.status == CourseStatus.archived) return CourseStatus.archived;
  if (passed) return CourseStatus.completed;
  if (toComplete) return CourseStatus.toComplete;
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
///
/// Una scrittura che non riesce (disco pieno, database in sola lettura o
/// bloccato) non ferma la lettura che segue: gli stati restano quelli di
/// prima fino alla prossima volta e l'errore va nel registro. Prima Home,
/// Insegnamenti, Studio, Libri ed Esami mostravano solo «Errore».
Future<int> syncCourseStatuses(AppServices s, {DateTime? now}) async {
  final profile = await s.profiles.load();
  final finals = <int, List<Exam>>{};
  for (final e in await s.exams.all()) {
    if (e.kind == ExamKind.finalExam) {
      finals.putIfAbsent(e.courseId, () => []).add(e);
    }
  }
  final passed = {
    for (final f in finals.entries)
      if (f.value.any((e) => e.status == ExamStatus.passed)) f.key,
  };
  // esame principale «Da completare» (anni prima dell'anno di partenza)
  final toComplete = {
    for (final f in finals.entries)
      if (primaryFinal(f.value)?.status.isToComplete ?? false) f.key,
  };
  final t = now ?? DateTime.now();
  var changed = 0;
  for (final c in await s.courses.all()) {
    final next = deriveCourseStatus(
      c,
      passed: c.id != null && passed.contains(c.id),
      toComplete: c.id != null && toComplete.contains(c.id),
      currentYear: profile?.currentYear,
      fuoriCorso: profile?.fuoriCorso ?? false,
      now: t,
    );
    if (next != c.status) {
      try {
        await s.courses.update(c.copyWith(status: next));
      } catch (e, st) {
        // le altre scritture non riuscirebbero meglio
        unawaited(ErrorLog.record(e, st, context: 'Stato degli insegnamenti'));
        break;
      }
      changed++;
    }
  }
  return changed;
}
