import '../../core/academic/plan_scope.dart';
import '../../core/academic/student_profile.dart';
import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../repositories/exam_repository.dart';
import '../../repositories/settings_repository.dart';
import '../../utils/exclusion_filter.dart';
import 'exam_status.dart' show withOutcome;
import 'exam_ui.dart' show ExamOutcome;

/// Esami degli anni precedenti: chi inizia a usare UniNotes al 2°, 3° anno
/// o dopo non ha compilato gli esami degli anni prima. L'anno indicato
/// nell'onboarding (o nel cambio di corso) è l'**anno di partenza**
/// (`StudentProfile.startYear`): gli esami degli anni prima che lo studente
/// non ha mai toccato sono «Da completare» ([ExamStatus.toComplete]) e non
/// arretrati; gli arretrati si contano dall'anno di partenza in poi, più
/// quelli degli anni prima che lo studente segna «Da sostenere». Si
/// compilano in Esami → Anni precedenti ([loadPreviousYears] e le azioni
/// qui sotto); la Home e una notifica lo ricordano ([PreviousYearsPrompt]).

/// Scelta di una riga degli Anni precedenti (nessuna = da completare).
enum PreviousChoice { taken, toTake }

/// Insegnamento di un anno precedente con il suo esame finale principale
/// ([exam] null: l'insegnamento non ha ancora un esame finale).
class PreviousCourse {
  const PreviousCourse(this.course, this.exam);
  final Course course;
  final Exam? exam;

  /// Insegnamento a scelta: non conta tra quelli da completare (chi non
  /// l'ha scelto lo lascia così) e «Segna tutti come sostenuti» non lo tocca.
  bool get elective => course.mandatory == false;

  bool get toComplete => exam?.status.isToComplete ?? false;

  /// Scelta mostrata: «Sostenuto» (superato, in attesa dell'esito o non
  /// superato), «Da sostenere» (da prenotare, prenotato, annullato) o nessuna.
  PreviousChoice? get choice => switch (exam?.status) {
    null || ExamStatus.toComplete => null,
    ExamStatus.passed ||
    ExamStatus.taken ||
    ExamStatus.failed => PreviousChoice.taken,
    _ => PreviousChoice.toTake,
  };

  /// La scelta si può togliere (si torna a «Da completare») senza perdere
  /// dati che lo studente ha messo altrove: non una prenotazione o una data.
  bool get canReset {
    final e = exam;
    if (e == null || e.id == null) return false;
    return switch (e.status) {
      ExamStatus.passed || ExamStatus.taken || ExamStatus.failed => true,
      ExamStatus.planned => e.date == null,
      _ => false,
    };
  }
}

/// Un anno prima dell'anno di partenza: obbligatori per primi, poi quelli
/// a scelta, in ordine di nome.
class PreviousYear {
  PreviousYear(this.year, this.courses);
  final int year;
  final List<PreviousCourse> courses;

  List<PreviousCourse> get mandatory => [
    for (final c in courses)
      if (!c.elective) c,
  ];

  List<PreviousCourse> get electives => [
    for (final c in courses)
      if (c.elective) c,
  ];

  /// Obbligatori ancora da completare.
  List<PreviousCourse> get mandatoryToComplete => [
    for (final c in mandatory)
      if (c.toComplete) c,
  ];

  int get toComplete => mandatoryToComplete.length;
}

/// Gli anni prima dell'anno di partenza con i loro insegnamenti.
class PreviousYearsData {
  const PreviousYearsData({required this.profile, required this.years});
  final StudentProfile profile;
  final List<PreviousYear> years;

  int get startYear => profile.trackedFrom;

  /// C'è qualcosa da mostrare: anno di partenza oltre il 1° e almeno un
  /// insegnamento negli anni prima.
  bool get applies => years.any((y) => y.courses.isNotEmpty);

  /// Insegnamenti obbligatori ancora «Da completare».
  int get toComplete => years.fold(0, (n, y) => n + y.toComplete);

  int _count(PreviousChoice c) =>
      years.fold(0, (n, y) => n + y.courses.where((x) => x.choice == c).length);

  int get taken => _count(PreviousChoice.taken);
  int get toTake => _count(PreviousChoice.toTake);

  /// «del 1° anno», «del 1° e del 2° anno», «dal 1° al 3° anno».
  String get yearsLabel => previousYearsLabel(startYear);
}

/// Insegnamenti degli anni prima dell'anno di partenza, con l'esame finale:
/// solo quelli del percorso (non gli insegnamenti a scelta tolti dal piano,
/// non gli archiviati) e senza quelli esclusi in Impostazioni → Esclusioni
/// (OFA, inglese, facoltativi), riconosciuti dal nome ufficiale. Null senza
/// profilo.
Future<PreviousYearsData?> loadPreviousYears(AppServices s) async {
  final p = s.profile.value ?? await s.profiles.load();
  if (p == null) return null;
  final start = p.trackedFrom;
  if (start <= 1) return PreviousYearsData(profile: p, years: const []);
  final exclusions = ExclusionFilter(await s.settings.exclusionPatterns());
  final scope = PlanScope(profile: p);
  final finals = <int, List<Exam>>{};
  for (final e in await s.exams.all()) {
    if (e.kind == ExamKind.finalExam) {
      finals.putIfAbsent(e.courseId, () => []).add(e);
    }
  }
  final byYear = <int, List<PreviousCourse>>{};
  for (final c in await s.courses.all()) {
    final y = c.year;
    if (c.id == null || y == null || y < 1 || y >= start) continue;
    if (!scope.inPath(c) || c.status == CourseStatus.archived) continue;
    if (exclusions.isExcluded([c.officialName])) continue;
    byYear
        .putIfAbsent(y, () => [])
        .add(PreviousCourse(c, primaryFinal(finals[c.id] ?? const [])));
  }
  for (final list in byYear.values) {
    list.sort((a, b) {
      final e = electivesLast(a.course, b.course);
      if (e != 0) return e;
      return a.course.name.toLowerCase().compareTo(b.course.name.toLowerCase());
    });
  }
  return PreviousYearsData(
    profile: p,
    years: [for (var y = 1; y < start; y++) PreviousYear(y, byYear[y] ?? [])],
  );
}

Exam _finalOf(PreviousCourse c) =>
    c.exam ?? Exam(courseId: c.course.id!, kind: ExamKind.finalExam);

/// «Sostenuto» con l'esito [o]: voto, lode o idoneità (superato), oppure in
/// attesa dell'esito o «Non superato» (arretrato da sostenere). Senza esame
/// finale lo crea.
Future<Exam> setPreviousTaken(
  AppServices s,
  PreviousCourse c,
  ExamOutcome o,
) async {
  final next = withOutcome(_finalOf(c), o);
  final id = await s.exams.save(next);
  if (next.status == ExamStatus.failed) {
    // da rifare: tornano anche le sue prove in itinere
    await s.exams.moveMidterms(
      next.courseId,
      ExamStatus.toComplete,
      ExamStatus.planned,
    );
  }
  s.revision.bump();
  return Exam.fromMap({...next.toMap(), 'id': id});
}

/// «Da sostenere»: l'esame diventa un arretrato da prenotare (compare in Da
/// sostenere, nel menù «Corso» delle prove nuove e nei promemoria), con le
/// sue prove in itinere.
Future<void> setPreviousToTake(AppServices s, PreviousCourse c) async {
  final base = _finalOf(c);
  await s.exams.save(
    base.copyWith(status: ExamStatus.planned, clearGrade: true, laude: false),
  );
  await s.exams.moveMidterms(
    base.courseId,
    ExamStatus.toComplete,
    ExamStatus.planned,
  );
  s.revision.bump();
}

/// Toglie la scelta: l'esame torna «Da completare» (senza voto), con le sue
/// prove in itinere ancora da prenotare.
Future<void> resetPreviousToComplete(AppServices s, PreviousCourse c) async {
  final e = c.exam;
  if (e == null || !c.canReset) return;
  await s.exams.save(
    e.copyWith(status: ExamStatus.toComplete, clearGrade: true, laude: false),
  );
  await s.exams.moveMidterms(
    e.courseId,
    ExamStatus.planned,
    ExamStatus.toComplete,
  );
  s.revision.bump();
}

/// «Segna tutti come sostenuti» per l'anno [y]: gli esami obbligatori
/// ancora da completare diventano superati senza voto (il voto si aggiunge
/// dopo, esame per esame). Quelli a scelta restano da indicare uno per uno.
/// Restituisce quanti.
Future<int> markPreviousYearTaken(AppServices s, PreviousYear y) async {
  var n = 0;
  for (final c in y.mandatoryToComplete) {
    await s.exams.save(
      _finalOf(c)
          .copyWith(status: ExamStatus.passed, clearGrade: true, laude: false),
    );
    n++;
  }
  if (n > 0) s.revision.bump();
  return n;
}

/// Come si chiede di completare gli anni precedenti: un riquadro nella Home
/// (subito dopo l'onboarding o il cambio di corso; «Più tardi» lo nasconde
/// per [homeDelay]) e una notifica dopo 3 giorni, con una sola ripetizione
/// dopo 14 ([reminderDays], vedi `previousYearsReminders`). Tutto smette
/// quando non resta nulla da completare. Impostazioni del dispositivo (non
/// sincronizzate, come le altre domande).
class PreviousYearsPrompt {
  PreviousYearsPrompt._();

  /// Fino a quando il riquadro della Home resta nascosto («Più tardi»).
  static const laterKey = 'previous_years_later';

  /// Da quando si chiede (onboarding, cambio di corso o primo avvio con
  /// esami da completare): le notifiche partono da qui.
  static const sinceKey = 'previous_years_since';

  /// «Non chiedere più» della conferma di «Segna tutti come sostenuti» (si
  /// ripristina da Impostazioni → «Ripristina le domande»).
  static const dontAskMarkAllKey = 'dont_ask_mark_all_taken';

  static const homeDelay = Duration(days: 7);

  /// Giorni dopo [sinceKey] delle due notifiche.
  static const reminderDays = [3, 14];

  /// Nuovo percorso: il riquadro torna subito e le notifiche ripartono.
  static Future<void> restart(SettingsRepository st, {DateTime? now}) async {
    await st.set(laterKey, null);
    await st.set(sinceKey, (now ?? DateTime.now()).toIso8601String());
  }

  /// «Più tardi»: il riquadro torna tra [homeDelay].
  static Future<void> later(SettingsRepository st, {DateTime? now}) => st.set(
    laterKey,
    (now ?? DateTime.now()).add(homeDelay).toIso8601String(),
  );

  /// Il riquadro della Home si può mostrare ora (non rimandato).
  static Future<bool> homeVisible(
    SettingsRepository st, {
    DateTime? now,
  }) async {
    final until = DateTime.tryParse(await st.get(laterKey) ?? '');
    return until == null || !(now ?? DateTime.now()).isBefore(until);
  }

  /// Inizio dei promemoria; se non c'è (es. aggiornamento dell'app o un
  /// altro dispositivo) parte ora.
  static Future<DateTime> since(SettingsRepository st, {DateTime? now}) async {
    final v = DateTime.tryParse(await st.get(sinceKey) ?? '');
    if (v != null) return v;
    final t = now ?? DateTime.now();
    await st.set(sinceKey, t.toIso8601String());
    return t;
  }
}
