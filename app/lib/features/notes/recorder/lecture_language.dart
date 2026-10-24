import '../../../models/course.dart';
import '../../../repositories/settings_repository.dart';
import 'recording_meta.dart';
import 'speech_language.dart';

/// Lingua delle lezioni registrate: **italiano** o **inglese**, mai il
/// rilevamento automatico. Si sceglie nell'onboarding («In che lingua sono
/// le tue lezioni?», [kLectureLanguageKey]) e si cambia in Registra prima di
/// registrare: quella scelta resta per l'insegnamento
/// ([courseLectureLanguageKey]). Vale per il testo dal vivo (riconoscitore
/// del sistema, Parakeet, Whisper), per «Completo la trascrizione» e per le
/// trascrizioni fatte dopo il salvataggio, che di predefinito usano la
/// lingua salvata con la registrazione (`RecordingMeta.language`).

/// Impostazione generale ('it' o 'en'; senza = italiano).
const kLectureLanguageKey = 'lecture_language';

/// Lingua scelta in Registra per un insegnamento.
String courseLectureLanguageKey(int courseId) =>
    'lecture_language_course_$courseId';

/// La lingua da proporre: quella scelta per l'insegnamento ([course]),
/// l'inglese per gli insegnamenti seguiti in inglese ([examLanguage]),
/// altrimenti quella generale ([general]), di predefinito l'italiano.
String pickLectureLanguage({
  String? course,
  String? examLanguage,
  String? general,
}) {
  if (course == 'it' || course == 'en') return course!;
  if ((examLanguage ?? '').trim().toLowerCase().startsWith('en')) return 'en';
  return lectureLanguage(general);
}

/// Lingua delle lezioni di [c] (vedi [pickLectureLanguage]).
Future<String> lectureLanguageOf(SettingsRepository s, Course? c) async {
  String? course;
  String? general;
  try {
    final id = c?.id;
    if (id != null) course = await s.get(courseLectureLanguageKey(id));
    general = await s.get(kLectureLanguageKey);
  } catch (_) {
    // impostazioni non leggibili: la lingua dell'insegnamento o l'italiano
  }
  return pickLectureLanguage(
    course: course,
    examLanguage: c?.examLanguage,
    general: general,
  );
}

/// Lingua della registrazione salvata [audioPath]: quella scelta in
/// Registra (salvata con la registrazione), altrimenti quella delle
/// lezioni di [c].
Future<String> recordingLanguageOf(
  SettingsRepository s,
  Course? c,
  String audioPath,
) async {
  try {
    final l = (await RecordingMeta.load(audioPath)).language;
    if (l != null) return l;
  } catch (_) {}
  return lectureLanguageOf(s, c);
}

/// Lingua generale (onboarding).
Future<void> setGeneralLectureLanguage(SettingsRepository s, String lang) =>
    s.set(kLectureLanguageKey, lectureLanguage(lang));

/// Lingua scelta in Registra per l'insegnamento [courseId].
Future<void> setCourseLectureLanguage(
  SettingsRepository s,
  int courseId,
  String lang,
) => s.set(courseLectureLanguageKey(courseId), lectureLanguage(lang));

/// «Italiano» o «Inglese».
String lectureLanguageLabel(String lang) =>
    lectureLanguage(lang) == 'en' ? 'Inglese' : 'Italiano';
