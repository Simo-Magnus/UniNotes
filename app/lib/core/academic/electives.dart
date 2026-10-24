import '../constants/enums.dart';
import '../services/app_services.dart';
import 'plan_scope.dart';

/// Dopo l'eliminazione di un esame finale: se l'insegnamento è a scelta e
/// non ha più esami finali, lo studente non lo sostiene più e
/// l'insegnamento si archivia, sparendo da Registra, Studio, Libri, Esami e
/// Home (resta in Insegnamenti con il filtro «Archiviato» e si riprende
/// aggiungendo di nuovo l'esame). Restituisce true se archiviato.
Future<bool> dropElectiveWithoutExam(AppServices s, int courseId) async {
  final c = await s.courses.byId(courseId);
  if (c == null || c.mandatory != false) return false;
  if (c.status == CourseStatus.archived) return false;
  final finals = (await s.exams.byCourse(courseId))
      .where((e) => e.kind == ExamKind.finalExam);
  if (finals.isNotEmpty) return false;
  await s.courses.update(c.copyWith(status: CourseStatus.archived));
  return true;
}

/// Un esame aggiunto a un insegnamento a scelta rimosso lo riporta nel
/// piano (lo stato si ricalcola alla prossima lista). Con [status] (lo stato
/// che l'insegnamento aveva prima di [dropElectiveWithoutExam], per
/// «Annulla») torna a quello invece che «In corso».
Future<void> restoreElective(
  AppServices s,
  int courseId, {
  CourseStatus? status,
}) async {
  final c = await s.courses.byId(courseId);
  if (c == null || !isDroppedElective(c)) return;
  final back = status == null || status == CourseStatus.archived
      ? CourseStatus.active
      : status;
  await s.courses.update(c.copyWith(status: back));
}
