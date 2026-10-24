import '../../core/academic/course_status_sync.dart';
import '../../core/constants/enums.dart';
import '../../models/course.dart';
import 'dashboard_data.dart';

/// Suddivisioni della card «Moduli e argomenti» della Home (1° semestre,
/// 2° semestre, Annuale, OFA…; mai con l'anno: si sceglie con la casella
/// accanto al corso di laurea), nell'ordine dei gruppi di Studio. La card ne
/// mostra una alla volta.
class ProgressGroup {
  const ProgressGroup({
    required this.label,
    required this.courses,
    required this.items,
  });

  /// Nome della suddivisione (anche chiave del selettore).
  final String label;

  /// Insegnamenti della suddivisione (anche quelli senza argomenti).
  final List<Course> courses;

  /// Avanzamento degli insegnamenti con almeno un argomento.
  final List<CourseProgressInfo> items;

  /// Suddivisione ancora in corso: almeno un insegnamento «In corso» secondo
  /// anno di corso e semestre attuali (vedi deriveCourseStatus).
  bool get inProgress => courses.any((c) => c.status == CourseStatus.active);

  /// Suddivisione del semestre [semester] ('1' o '2').
  bool isSemester(String semester) =>
      courses.any((c) => c.semester?.trim() == semester);

  bool contains(int courseId) => courses.any((c) => c.id == courseId);
}

/// Nome della suddivisione senza l'anno davanti: le versioni precedenti
/// usavano «2° anno · 1° semestre» (o «Anno non indicato · Annuale») quando
/// gli anni mostrati erano più d'uno. Un nome senza anno resta com'è.
String progressGroupName(String label) {
  final m = RegExp(r'^(?:\d+° anno|Anno non indicato) · (.+)$')
      .firstMatch(label);
  return m == null ? label : m.group(1)!;
}

/// Oltre questo tempo l'ultimo argomento cambiato non decide più la
/// suddivisione mostrata: si torna al semestre in corso. Un mese copre una
/// pausa normale dallo studio (vacanze, sessione d'esami di un'altra
/// materia) senza riaprire la Home su un semestre ormai lontano.
const Duration kRecentTopicChange = Duration(days: 30);

/// Suddivisione con cui si apre la card:
/// 1. quella dell'insegnamento dell'ultimo argomento a cui è cambiato lo
///    stato ([last]), se il cambio ha meno di [kRecentTopicChange] e la
///    suddivisione è ancora in corso;
/// 2. altrimenti il semestre in corso secondo la data (currentSemester);
/// 3. se quel semestre non ha argomenti, una suddivisione in corso (es.
///    annuale), infine la prima.
/// Null senza suddivisioni.
String? initialProgressGroup(
  List<ProgressGroup> groups, {
  ({int courseId, DateTime at})? last,
  required DateTime now,
}) {
  if (groups.isEmpty) return null;
  if (last != null && now.difference(last.at) <= kRecentTopicChange) {
    for (final g in groups) {
      if (g.contains(last.courseId) && g.inProgress) return g.label;
    }
  }
  final sem = currentSemester(now);
  final bySemester = [
    for (final g in groups)
      if (g.isSemester(sem)) g,
  ];
  for (final g in bySemester) {
    if (g.inProgress) return g.label;
  }
  if (bySemester.isNotEmpty) return bySemester.first.label;
  for (final g in groups) {
    if (g.inProgress) return g.label;
  }
  return groups.first.label;
}
