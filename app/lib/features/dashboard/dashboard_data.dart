import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/academic/course_status_sync.dart';
import '../../core/academic/plan_scope.dart';
import '../../core/academic/student_profile.dart';
import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/university_palette.dart';
import '../../models/book.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../models/study.dart';
import '../../utils/dates.dart';
import '../../utils/grade_math.dart';
import '../books/book_filters.dart';
import '../notes/lesson_transcripts.dart';
import '../notes/notes_store.dart';

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

/// Libri dei corsi mostrati: quanti sono scaricati, quanti obbligatori
/// vanno ancora procurati e l'ultimo aperto (per riprendere la lettura).
class BooksSummary {
  const BooksSummary({this.downloaded = 0, this.toProcure = 0, this.lastRead});
  final int downloaded;
  final int toProcure;
  final Book? lastRead;

  bool get isEmpty => downloaded == 0 && toProcure == 0 && lastRead == null;
}

/// Tutto ciò che serve alla Home, caricato in una volta.
class DashboardData {
  const DashboardData({
    required this.now,
    required this.exams,
    required this.weekSessions,
    required this.courses,
    required this.progress,
    required this.palette,
    this.recordings = const [],
    this.books = const BooksSummary(),
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
  final List<CourseProgressInfo> progress;
  final UniversityPalette palette;

  /// Ultime lezioni registrate (le più recenti per prime).
  final List<RecentRecording> recordings;
  final BooksSummary books;

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

    final progress = <CourseProgressInfo>[];
    for (final c in shown) {
      if (c.status != CourseStatus.active) continue;
      final topics = await s.study.topicsOfCourse(c.id!);
      if (topics.isEmpty) continue;
      progress.add(
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

    return DashboardData(
      now: now,
      exams: exams,
      weekSessions: weekSessions,
      courses: courses,
      progress: progress,
      palette: palette,
      recordings: await _recordings(s, shown),
      books: await _books(s, scope),
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

  /// Libri dei corsi del percorso (tutti gli anni dell'anno scelto).
  static Future<BooksSummary> _books(AppServices s, PlanScope scope) async {
    final courses = {
      for (final c in await s.courses.all())
        if (c.id != null) c.id!: c,
    };
    final books = [
      for (final b in await s.books.all())
        if (!b.isRemoved &&
            (b.courseId == null ||
                courses[b.courseId] == null ||
                scope.includes(courses[b.courseId]!)))
          b,
    ];
    if (books.isEmpty) return const BooksSummary();
    final covered = coursesWithRequiredCovered(books);
    Book? last;
    for (final b in books) {
      final at = b.lastOpenedAt;
      if (at == null || !isDownloaded(b)) continue;
      if (last == null || at.isAfter(last.lastOpenedAt!)) last = b;
    }
    return BooksSummary(
      downloaded: books.where(isDownloaded).length,
      toProcure: books
          .where((b) => BookAvailability.toProcure.matches(b, covered: covered))
          .length,
      lastRead: last,
    );
  }
}

/// "2 h 30 min", "45 min", "0 min".
String formatMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m min';
  if (m == 0) return '$h h';
  return '$h h $m min';
}
