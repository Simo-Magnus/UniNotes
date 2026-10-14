import '../../models/course.dart';
import '../constants/enums.dart';
import 'student_profile.dart';

/// Quali corsi mostrare nelle schermate con il selettore dell'anno (Home,
/// Registra, Studio, Libri, Esami, Insegnamenti): quelli del corso di
/// laurea scelto nell'anno selezionato. I dati dei corsi di laurea
/// precedenti restano nel database ma non si vedono. Senza profilo mostra
/// tutto (comportamento precedente).
class PlanScope {
  const PlanScope({this.profile, this.year});

  /// Nessun filtro.
  static const all = PlanScope();

  final StudentProfile? profile;

  /// Anno del piano scelto (null = tutti gli anni).
  final int? year;

  bool get isFiltered => profile != null;

  /// Il corso appartiene al percorso (stesso corso di laurea o aggiunto a
  /// mano senza corso di laurea) e all'anno scelto. Un corso senza anno
  /// compare in tutti gli anni.
  bool includes(Course c) {
    if (!inPath(c)) return false;
    if (profile == null || year == null || c.year == null) return true;
    return c.year == year;
  }

  /// Corso del percorso, di qualunque anno; gli insegnamenti a scelta
  /// rimossi (vedi [isDroppedElective]) non compaiono.
  bool inPath(Course c) => inDegree(c) && !isDroppedElective(c);

  /// Corso del corso di laurea attuale (o aggiunto a mano senza corso di
  /// laurea), anche se archiviato.
  bool inDegree(Course c) {
    final p = profile;
    if (p == null) return true;
    return c.degreeId == null || c.degreeId == p.degreeId;
  }
}

/// Insegnamento a scelta che lo studente ha tolto dal piano eliminandone
/// l'esame: resta archiviato (si ripristina da Insegnamenti) e sparisce da
/// Registra, Studio, Libri, Esami e Home.
bool isDroppedElective(Course c) =>
    c.mandatory == false && c.status == CourseStatus.archived;

/// Ordine comune delle liste di insegnamenti: prima gli obbligatori, gli
/// insegnamenti a scelta per ultimi.
int electivesLast(Course a, Course b) =>
    (a.mandatory == false ? 1 : 0).compareTo(b.mandatory == false ? 1 : 0);
