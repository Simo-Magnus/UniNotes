import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/academic/course_status_sync.dart';
import '../../core/academic/plan_scope.dart';
import '../../core/academic/student_profile.dart';
import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/university_palette.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../models/study.dart';
import '../../utils/dates.dart';
import '../../utils/grade_math.dart';
import '../notes/lesson_transcripts.dart';
import '../notes/notes_store.dart';
import '../study/course_groups.dart';
import 'progress_groups.dart';

/// Progresso di studio di un corso (media degli stati degli argomenti dei
/// moduli).
class CourseProgressInfo {
  const CourseProgressInfo({
    required this.course,
    required this.progress,
    required this.topics,
    required this.completed,
    this.toReview = 0,
  });

  final Course course;

  /// 0..1
  final double progress;
  final int topics;
  final int completed;

  /// Argomenti segnati «Da ripassare».
  final int toReview;
}

/// Una lezione registrata, con le sue trascrizioni.
class RecentRecording {
  const RecentRecording({
    required this.course,
    required this.file,
    required this.transcripts,
  });
  final Course course;
  final NoteFile file;
  final LessonTranscripts transcripts;
}

/// Tutto ciò che serve alla Home, caricato in una volta.
class DashboardData {
  const DashboardData({
    required this.now,
    required this.exams,
    required this.weekSessions,
    required this.courses,
    required this.palette,
    this.progressGroups = const [],
    this.lastTopicChange,
    this.recordings = const [],
    this.profile,
    this.year,
  });

  /// Percorso dello studente e anno mostrato (null senza onboarding).
  final StudentProfile? profile;
  final int? year;

  final DateTime now;

  /// Esami e prove in itinere da sostenere (da prenotare o prenotati).
  final List<Exam> exams;
  final List<StudySession> weekSessions;
  final Map<int, Course> courses;
  final UniversityPalette palette;

  /// «Moduli e argomenti»: suddivisioni (semestri, annuale…) con gli
  /// insegnamenti che hanno argomenti, nell'ordine di Studio.
  final List<ProgressGroup> progressGroups;

  /// Ultimo cambio di stato di un argomento (vedi
  /// StudyRepository.lastTopicChange).
  final ({int courseId, DateTime at})? lastTopicChange;

  /// Ultime lezioni registrate (le più recenti per prime).
  final List<RecentRecording> recordings;

  DateTime get weekStart => startOfWeek(now);

  int get weekMinutes =>
      weekSessions.fold(0, (sum, s) => sum + s.durationMinutes);

  /// Minuti di studio per giorno della settimana (lun..dom).
  List<int> get minutesPerWeekday {
    final out = List<int>.filled(7, 0);
    for (final s in weekSessions) {
      out[s.start.weekday - 1] += s.durationMinutes;
    }
    return out;
  }

  Course? courseOf(int? id) => id == null ? null : courses[id];

  /// Registrazioni mostrate nella Home.
  static const int maxRecordings = 3;

  static Future<DashboardData> load(AppServices s) async {
    await syncCourseStatuses(s);
    final now = DateTime.now();
    final weekStart = startOfWeek(now);

    final palette = await UniversityPalette.load(s);
    final scope = s.scope;
    final courseList = await s.courses.all();
    final courses = {
      for (final c in courseList)
        if (c.id != null) c.id!: c,
    };

    // Esami e prove in itinere dell'anno scelto.
    final exams = [
      for (final e in await s.exams.upcoming(limit: 60))
        if (courses[e.courseId] == null || scope.includes(courses[e.courseId]!))
          e,
    ].take(5).toList();

    // sessioni di studio dei soli insegnamenti del corso di laurea attuale
    bool inPath(int? id) =>
        id == null || courses[id] == null || scope.inPath(courses[id]!);
    final weekSessions = [
      for (final x in await s.study.sessions(
        from: weekStart,
        to: addDays(weekStart, 7),
      ))
        if (inPath(x.courseId)) x,
    ];

    final shown = [
      for (final c in [...courseList]..sort(electivesLast))
        if (c.id != null && scope.includes(c)) c,
    ];

    // Moduli e argomenti: insegnamenti non superati né archiviati, divisi
    // come in Studio (semestre, annuale, OFA) e nello stesso ordine
    final studied = applyCourseOrder([
      for (final c in shown)
        if (c.status != CourseStatus.completed &&
            c.status != CourseStatus.archived)
          c,
    ], await loadStudyCourseOrder(s));
    final progressGroups = <ProgressGroup>[];
    // una sola lettura per tutti gli argomenti (non una per insegnamento)
    final topicsOf = studied.isEmpty
        ? const <int, List<Topic>>{}
        : await s.study.topicsByCourse();
    for (final g in groupStudyCourses(studied)) {
      final items = <CourseProgressInfo>[];
      for (final c in g.courses) {
        final topics = topicsOf[c.id!] ?? const <Topic>[];
        if (topics.isEmpty) continue;
        items.add(
          CourseProgressInfo(
            course: c,
            progress: courseProgress(topics.map((t) => t.status)),
            topics: topics.length,
            completed: topics
                .where((t) => t.status == TopicStatus.completed)
                .length,
            toReview: topics
                .where((t) => t.status == TopicStatus.toReview)
                .length,
          ),
        );
      }
      if (items.isEmpty) continue;
      progressGroups.add(
        ProgressGroup(label: g.label, courses: g.courses, items: items),
      );
    }

    return DashboardData(
      now: now,
      exams: exams,
      weekSessions: weekSessions,
      courses: courses,
      palette: palette,
      progressGroups: progressGroups,
      lastTopicChange: await s.study.lastTopicChange(),
      recordings: await _recordings(s, shown),
      profile: scope.profile,
      year: scope.year,
    );
  }

  /// Ultime registrazioni dei corsi mostrati: si leggono solo le cartelle
  /// dei corsi che esistono già (niente cartelle create dalla Home).
  static Future<List<RecentRecording>> _recordings(
    AppServices s,
    List<Course> shown,
  ) async {
    try {
      final root = await s.notes.root();
      final found = <(Course, NoteFile)>[];
      for (final c in shown) {
        final base = p.join(root.path, NotesStore.folderName(c));
        final dir = Directory(p.join(base, NoteFolder.recordings.dirName));
        if (!await dir.exists()) continue;
        await for (final e in dir.list()) {
          if (e is! File) continue;
          final ext = p.extension(e.path).toLowerCase();
          if (!NotesStore.audioExtensions.contains(ext)) continue;
          if (p.basename(e.path).startsWith('.')) continue;
          final st = await e.stat();
          found.add((
            c,
            NoteFile(e, NoteFolder.recordings, st.modified, st.size),
          ));
        }
      }
      found.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
      return [
        for (final (c, f) in found.take(maxRecordings))
          RecentRecording(
            course: c,
            file: f,
            transcripts: await loadLessonTranscripts(
              Directory(
                p.join(
                  root.path,
                  NotesStore.folderName(c),
                  NoteFolder.transcripts.dirName,
                ),
              ),
              f.name,
            ),
          ),
      ];
    } catch (_) {
      // cartella degli appunti non disponibile (es. nei test)
      return const [];
    }
  }
}

/// "2 h 30 min", "45 min", "0 min".
String formatMinutes(int minutes) {
  // durata negativa (sessione importata male): con il resto della divisione
  // uscirebbero ore e minuti sbagliati, non un valore sensato
  if (minutes < 0) minutes = 0;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m min';
  if (m == 0) return '$h h';
  return '$h h $m min';
}
