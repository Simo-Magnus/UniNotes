import '../../models/exam.dart';
import '../constants/enums.dart';
import '../services/app_services.dart';
import 'plan_scope.dart';

/// Dopo l'eliminazione di una prova (esame finale, prova in itinere o
/// esonero): se l'insegnamento è a scelta e non gli resta NESSUNA prova (né
/// esame finale né prove in itinere / esoneri), lo studente non lo sostiene
/// più e l'insegnamento si archivia, sparendo da Registra, Studio, Libri,
/// Esami e Home (resta in Insegnamenti con il filtro «Archiviato» e si
/// riprende aggiungendo di nuovo una prova). Finché resta un'altra prova
/// l'insegnamento resta nel piano. Restituisce true se archiviato.
Future<bool> dropElectiveWithoutExam(AppServices s, int courseId) async {
  final c = await s.courses.byId(courseId);
  if (c == null || c.mandatory != false) return false;
  if (c.status == CourseStatus.archived) return false;
  if ((await s.exams.byCourse(courseId)).isNotEmpty) return false;
  await s.courses.update(c.copyWith(status: CourseStatus.archived));
  return true;
}

/// Vero se eliminare la prova [removing] (esame finale, prova in itinere o
/// esonero) farebbe archiviare l'insegnamento a scelta: è a scelta, non è già
/// archiviato e, tolta questa prova, non gliene resta nessun'altra. Serve
/// al dialogo di eliminazione, per avvisare prima (stessa condizione di
/// [dropElectiveWithoutExam]).
Future<bool> wouldDropElective(AppServices s, Exam removing) async {
  final c = await s.courses.byId(removing.courseId);
  if (c == null || c.mandatory != false) return false;
  if (c.status == CourseStatus.archived) return false;
  final others = (await s.exams.byCourse(removing.courseId))
      .where((e) => removing.id == null || e.id != removing.id);
  return others.isEmpty;
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
