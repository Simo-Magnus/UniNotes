import '../../../core/constants/enums.dart';
import '../../../models/study.dart';
import '../../../repositories/study_repository.dart';

/// Vocabolario del corso per la trascrizione (prompt di Whisper): nome
/// dell'insegnamento, poi il **modulo in corso** con i suoi argomenti, poi
/// gli altri moduli e i loro argomenti. Si legge solo il piano di studio
/// dell'insegnamento (moduli e argomenti nel database dell'app).
///
/// Modulo in corso: il primo (in ordine) con un argomento «In corso» o
/// «Parzialmente completato», altrimenti il primo con argomenti non
/// ancora iniziati, altrimenti il primo. Dentro un modulo: prima gli
/// argomenti in corso, poi quelli da iniziare, da ripassare e completati.
List<String> courseVocabulary(
  String courseName,
  List<StudyModule> modules,
  List<Topic> topics,
) {
  final mods = [...modules]..sort((a, b) => a.sort.compareTo(b.sort));
  List<Topic> of(StudyModule m) =>
      [
        for (final t in topics)
          if (t.moduleId == m.id) t,
      ]..sort((a, b) {
        final r = _rank(a.status).compareTo(_rank(b.status));
        return r != 0 ? r : a.sort.compareTo(b.sort);
      });
  StudyModule? current;
  for (final m in mods) {
    if (of(m).any(
      (t) =>
          t.status == TopicStatus.inProgress || t.status == TopicStatus.partial,
    )) {
      current = m;
      break;
    }
  }
  current ??= mods
      .where((m) => of(m).any((t) => t.status == TopicStatus.notStarted))
      .firstOrNull;
  current ??= mods.firstOrNull;
  final others = [
    for (final m in mods)
      if (m != current) m,
  ];
  return [
    courseName,
    if (current != null) ...[current.name, for (final t in of(current)) t.name],
    for (final m in others) m.name,
    for (final m in others)
      for (final t in of(m)) t.name,
  ];
}

int _rank(TopicStatus s) => switch (s) {
  TopicStatus.inProgress || TopicStatus.partial => 0,
  TopicStatus.notStarted => 1,
  TopicStatus.toReview => 2,
  TopicStatus.completed => 3,
};

/// Vocabolario dell'insegnamento [courseId] (solo il nome se il piano di
/// studio non si legge).
Future<List<String>> loadCourseVocabulary(
  StudyRepository study,
  int? courseId,
  String courseName,
) async {
  if (courseId == null) return [courseName];
  try {
    return courseVocabulary(
      courseName,
      await study.modules(courseId),
      await study.topicsOfCourse(courseId),
    );
  } catch (_) {
    return [courseName];
  }
}
