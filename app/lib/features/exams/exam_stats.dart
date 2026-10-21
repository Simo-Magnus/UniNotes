import '../../core/academic/plan_scope.dart';
import '../../core/academic/student_profile.dart';
import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../models/calendar_event.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../models/university.dart';
import '../../utils/grade_math.dart';
import '../courses/course_ui.dart';
import 'previous_years.dart';

/// Dati caricati una volta per la schermata Esami.
class ExamsData {
  const ExamsData({
    required this.exams,
    required this.courses,
    required this.universities,
    required this.degrees,
    this.examWindows = const [],
    this.scope = PlanScope.all,
    this.previous,
  });

  /// Esami degli anni prima dell'anno di partenza (riquadro «Anni
  /// precedenti» in Da sostenere); null senza profilo.
  final PreviousYearsData? previous;

  /// Percorso e anno scelti (selettore nella barra).
  final PlanScope scope;

  StudentProfile? get profile => scope.profile;

  /// Esami e prove dei corsi dell'anno scelto (tutti senza percorso).
  List<Exam> get scopedExams => [
    for (final e in exams)
      if (_inScope(e.courseId)) e,
  ];

  /// Esami e prove dei corsi del percorso, di tutti gli anni.
  List<Exam> get pathExams => [
    for (final e in exams)
      if (courses[e.courseId] == null || scope.inPath(courses[e.courseId]!)) e,
  ];

  bool _inScope(int courseId) {
    final c = courses[courseId];
    return c == null || scope.includes(c);
  }

  /// Corsi dell'anno scelto.
  List<Course> get scopedCourses => [
    for (final c in courses.values)
      if (scope.includes(c)) c,
  ];

  /// Prossimo appello noto (dal catalogo o dal calendario) di un corso.
  CalendarEvent? nextWindow(int courseId, DateTime today) {
    CalendarEvent? best;
    for (final w in examWindows) {
      if (w.courseId != courseId) continue;
      final end = w.end ?? w.start;
      if (end.isBefore(today)) continue;
      if (best == null || w.start.isBefore(best.start)) best = w;
    }
    return best;
  }

  final List<Exam> exams;
  final Map<int, Course> courses;
  final Map<String, University> universities;
  final List<Degree> degrees;

  /// Eventi "Esame disponibile": finestre di sessione e date degli appelli.
  final List<CalendarEvent> examWindows;

  bool get isEmpty => exams.isEmpty;
}

Future<ExamsData> loadExamsData(AppServices s) async {
  // un solo esame finale per insegnamento (anche dopo «Aggiorna database»):
  // le due pagine leggono la stessa prova e mostrano lo stesso stato
  await s.exams.mergeDuplicateFinals();
  PreviousYearsData? previous;
  try {
    previous = await loadPreviousYears(s);
  } catch (_) {
    previous = null;
  }
  return ExamsData(
    previous: previous,
    exams: await s.exams.all(),
    courses: await s.courses.mapById(),
    universities: await s.courses.universitiesById(),
    degrees: await s.courses.degrees(),
    examWindows: await s.calendar.eventsOfType(EventType.examWindow),
    scope: s.scope,
  );
}

/// Prova «da sostenere»: da prenotare o prenotata, oppure esame finale non
/// superato (resta da sostenere, con il suo stato, e si riprenota).
bool isToTake(Exam e) =>
    e.status.isPending ||
    (e.kind == ExamKind.finalExam && e.status == ExamStatus.failed);

/// Prove della lista «Da sostenere»: da prenotare e prenotate, più l'esame
/// finale non superato di un insegnamento che non ha un altro esame finale
/// più avanti (superato, in attesa dell'esito o di nuovo da sostenere); se
/// ce n'è più d'uno non superato, solo l'ultimo. [all]: tutte le prove (anche
/// fuori dall'anno scelto), per sapere com'è messo l'insegnamento.
List<Exam> toTakeExams(Iterable<Exam> exams, {Iterable<Exam>? all}) {
  final every = (all ?? exams).toList();
  final settled = <int>{
    for (final e in every)
      if (e.kind == ExamKind.finalExam &&
          (e.status.isPending ||
              e.status == ExamStatus.passed ||
              e.status == ExamStatus.taken))
        e.courseId,
  };
  // ultimo esame finale non superato di ogni insegnamento
  final lastFailed = <int, Exam>{};
  for (final e in every) {
    if (e.kind != ExamKind.finalExam || e.status != ExamStatus.failed) continue;
    final cur = lastFailed[e.courseId];
    if (cur == null || _isLater(e, cur)) lastFailed[e.courseId] = e;
  }
  bool shown(Exam e) {
    if (e.status.isPending) return true;
    if (!isToTake(e) || settled.contains(e.courseId)) return false;
    final last = lastFailed[e.courseId];
    return identical(last, e) || (e.id != null && last?.id == e.id);
  }

  return [
    for (final e in exams)
      if (shown(e)) e,
  ];
}

bool _isLater(Exam a, Exam b) {
  final da = a.dateTime, db = b.dateTime;
  if (da != null && db != null && da != db) return da.isAfter(db);
  if (da != null && db == null) return true;
  if (da == null && db != null) return false;
  return (a.id ?? 0) > (b.id ?? 0);
}

/// Stati considerati "sostenuti" (con o senza esito).
const Set<ExamStatus> kTakenStatuses = {
  ExamStatus.taken,
  ExamStatus.passed,
  ExamStatus.failed,
  ExamStatus.cancelled,
};

/// CFU acquisiti: esami finali superati (anche senza voto, es. idoneità).
double acquiredCfu(Iterable<Exam> exams, Map<int, Course> courses) {
  var total = 0.0;
  final counted = <int>{};
  for (final e in exams) {
    if (e.kind != ExamKind.finalExam || e.status != ExamStatus.passed) continue;
    if (courses[e.courseId]?.status == CourseStatus.archived) continue;
    // Un corso conta una sola volta anche se ci sono più record superati.
    if (!counted.add(e.courseId)) continue;
    total += e.cfu ?? courses[e.courseId]?.cfu ?? 0;
  }
  return total;
}

/// Riepilogo medie per un insieme di esami (tutti, un'università, un corso di laurea).
class AverageSummary {
  AverageSummary(
    this.label,
    Iterable<Exam> exams,
    Map<int, Course> courses, {
    double laudeValue = 30,
  }) : result = weightedAverage(exams, courses, laudeValue: laudeValue),
       cfu = acquiredCfu(exams, courses),
       passed = exams
           .where(
             (e) =>
                 e.kind == ExamKind.finalExam && e.status == ExamStatus.passed,
           )
           .length,
       failed = exams.where((e) => e.status == ExamStatus.failed).length;

  final String label;
  final AverageResult result;
  final double cfu;
  final int passed;
  final int failed;
}

/// Esami finali e prove in itinere di un corso.
class CourseExamGroup {
  CourseExamGroup(this.course, this.courseId, List<Exam> exams)
    : finals = exams.where((e) => e.kind == ExamKind.finalExam).toList(),
      midterms = exams.where((e) => e.kind == ExamKind.midterm).toList(),
      midtermAvg = midtermAverage(exams);

  final Course? course;
  final int courseId;
  final List<Exam> finals;
  final List<Exam> midterms;
  final double? midtermAvg;

  List<Exam> get all => [...finals, ...midterms];

  /// Esame finale superato (il più recente), se presente.
  Exam? get passedFinal {
    final p = finals.where((e) => e.status == ExamStatus.passed).toList();
    return p.isEmpty ? null : p.last;
  }

  String get name => course?.name ?? 'Corso sconosciuto';
}

/// Raggruppa per corso, in ordine alfabetico (insegnamenti a scelta per
/// ultimi).
List<CourseExamGroup> groupByCourse(
  Iterable<Exam> exams,
  Map<int, Course> courses,
) {
  final byId = <int, List<Exam>>{};
  for (final e in exams) {
    byId.putIfAbsent(e.courseId, () => []).add(e);
  }
  final groups = [
    for (final entry in byId.entries)
      CourseExamGroup(courses[entry.key], entry.key, entry.value),
  ];
  groups.sort((a, b) {
    final e = _electiveRank(a.course).compareTo(_electiveRank(b.course));
    if (e != 0) return e;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return groups;
}

int _electiveRank(Course? c) => c?.mandatory == false ? 1 : 0;

/// Gruppo di una lista di Esami: un semestre del piano.
class SemesterGroup<T> {
  SemesterGroup(this.label, this.items);
  final String label;
  final List<T> items;
}

/// Divide [items] per semestre dell'insegnamento (1°, 2°, annuale, non
/// indicato; con l'anno davanti quando gli anni sono più d'uno), tenendo
/// l'ordine di [items]; in ogni semestre gli insegnamenti a scelta vengono
/// per ultimi.
List<SemesterGroup<T>> groupBySemester<T>(
  List<T> items,
  Course? Function(T item) courseOf,
) {
  final years = {for (final x in items) courseOf(x)?.year};
  final withYear = years.length > 1;
  final keys = <String, (int, int, String)>{};
  final byKey = <String, List<(int, T)>>{};
  for (var i = 0; i < items.length; i++) {
    final c = courseOf(items[i]);
    final y = c?.year ?? 99;
    final so = semesterOrder(c?.semester);
    final key = '$y|$so';
    keys[key] = (
      y,
      so,
      withYear
          ? '${yearLabel(c?.year)} · ${semesterLabel(c?.semester)}'
          : semesterLabel(c?.semester),
    );
    byKey.putIfAbsent(key, () => []).add((i, items[i]));
  }
  final ordered = keys.keys.toList()
    ..sort((a, b) {
      final ka = keys[a]!, kb = keys[b]!;
      final y = ka.$1.compareTo(kb.$1);
      return y != 0 ? y : ka.$2.compareTo(kb.$2);
    });
  return [
    for (final k in ordered)
      SemesterGroup(keys[k]!.$3, [
        for (final e
            in byKey[k]!..sort((a, b) {
              final r = _electiveRank(courseOf(a.$2))
                  .compareTo(_electiveRank(courseOf(b.$2)));
              return r != 0 ? r : a.$1.compareTo(b.$1);
            }))
          e.$2,
      ]),
  ];
}

/// Ordina per data crescente, senza data in fondo; a parità (o senza data)
/// per nome dell'insegnamento, senza badare a maiuscole e minuscole.
List<Exam> sortByDate(
  Iterable<Exam> exams, [
  Map<int, Course> courses = const {},
]) {
  String name(Exam e) => (courses[e.courseId]?.name ?? '').toLowerCase();
  final list = exams.toList();
  list.sort((a, b) {
    final da = a.dateTime, db = b.dateTime;
    if (da == null && db != null) return 1;
    if (db == null && da != null) return -1;
    final d = da == null ? 0 : da.compareTo(db!);
    return d != 0 ? d : name(a).compareTo(name(b));
  });
  return list;
}

const _months = [
  'Gennaio',
  'Febbraio',
  'Marzo',
  'Aprile',
  'Maggio',
  'Giugno',
  'Luglio',
  'Agosto',
  'Settembre',
  'Ottobre',
  'Novembre',
  'Dicembre',
];

String monthLabel(DateTime? d) =>
    d == null ? 'Senza data' : '${_months[d.month - 1]} ${d.year}';
