import 'dart:ui' show Color;

import '../core/constants/enums.dart';
import '../core/database/app_database.dart';
import '../core/theme/university_colors.dart';
import '../models/calendar_entry.dart';
import '../models/calendar_event.dart';
import '../models/course.dart';
import '../models/exam.dart';
import '../utils/parse.dart';
import '../utils/place_text.dart';
import '../utils/dates.dart';

class CalendarRepository {
  CalendarRepository(this._db);
  final AppDatabase _db;

  Future<List<CalendarEvent>> eventsBetween(DateTime from, DateTime to) async {
    final rows = await _db.db.query(
      'events',
      where: 'start_at < ? AND COALESCE(end_at, start_at) >= ?',
      whereArgs: [isoLocal(to), isoLocal(from)],
      orderBy: 'start_at',
    );
    return rows.map(CalendarEvent.fromMap).toList();
  }

  Future<List<CalendarEvent>> eventsOfType(EventType type) async {
    final rows = await _db.db.query(
      'events',
      where: 'type = ?',
      whereArgs: [type.key],
      orderBy: 'start_at',
    );
    return rows.map(CalendarEvent.fromMap).toList();
  }

  Future<int> insertEvent(CalendarEvent e) =>
      _db.db.insert('events', e.toMap()..remove('id'));

  Future<void> updateEvent(CalendarEvent e) =>
      _db.db.update('events', e.toMap(), where: 'id = ?', whereArgs: [e.id]);

  Future<void> deleteEvent(int id) =>
      _db.db.delete('events', where: 'id = ?', whereArgs: [id]);

  /// Lezioni, finestre d'esame, eventi, esami e prove in itinere nel periodo,
  /// con colore risolto (corso > università > default).
  Future<List<CalendarEntry>> entriesBetween(DateTime from, DateTime to) async {
    final uniColors = <String, Color>{
      for (final r in await _db.db.query('universities'))
        r['id'] as String: Color(
          asInt(r['color']) ?? UniversityColors.fallback.toARGB32(),
        ),
    };
    final courses = {
      for (final r in await _db.db.query('courses'))
        asInt(r['id'])!: Course.fromMap(r),
    };

    Color colorFor(String? uniId, int? courseId) {
      final c = courseId == null ? null : courses[courseId];
      if (c?.color != null) return Color(c!.color!);
      final u = uniId ?? c?.universityId;
      return uniColors[u] ?? UniversityColors.forId(u);
    }

    final out = <CalendarEntry>[];
    for (final e in await eventsBetween(from, to)) {
      final course = e.courseId == null ? null : courses[e.courseId];
      final entry = CalendarEntry(
        kind: switch (e.type) {
          EventType.lecture => CalendarEntryKind.lecture,
          EventType.examWindow => CalendarEntryKind.examWindow,
          EventType.event => CalendarEntryKind.event,
          EventType.studyPlan => CalendarEntryKind.studyPlan,
          EventType.deadline => CalendarEntryKind.deadline,
        },
        // le lezioni del database hanno nel titolo il nome ufficiale: se lo
        // studente ha rinominato l'insegnamento si vede il suo nome
        title: course != null && course.hasCustomName
            ? e.title.replaceAll(course.officialName, course.name)
            : e.title,
        start: e.start,
        end: e.effectiveEnd,
        allDay: e.allDay,
        color: e.type == EventType.examWindow
            ? AssessmentColors.forUniversity(
                e.universityId ?? course?.universityId,
                midterm: false,
              )
            : colorFor(e.universityId, e.courseId),
        universityId: e.universityId ?? course?.universityId,
        courseId: e.courseId,
        courseName: course?.name,
        location: calendarLocation(e.room, e.building),
        teacher: e.teacher ?? course?.teacher,
        event: e,
      );
      out.addAll(
        periodMarkers(entry)
            .where((m) => m.start.isBefore(to) && !m.end.isBefore(from)),
      );
    }

    final examRows = await _db.db.query(
      'exams',
      where: 'date IS NOT NULL AND date >= ? AND date < ?',
      whereArgs: [isoDate(from), isoDate(to.add(const Duration(days: 1)))],
    );
    for (final r in examRows) {
      final x = Exam.fromMap(r);
      final dt = x.dateTime!;
      if (dt.isBefore(from) && x.time != null) continue;
      if (!dt.isBefore(to)) continue;
      final course = courses[x.courseId];
      final hasTime = x.time != null;
      out.add(
        CalendarEntry(
          kind: x.kind == ExamKind.midterm
              ? CalendarEntryKind.midterm
              : CalendarEntryKind.exam,
          title: '${x.kind.label}: ${x.title ?? course?.name ?? ''}',
          start: dt,
          end: hasTime
              ? dt.add(const Duration(hours: 2))
              : dt.add(const Duration(days: 1)),
          allDay: !hasTime,
          color: AssessmentColors.forUniversity(
            course?.universityId,
            midterm: x.kind == ExamKind.midterm,
          ),
          universityId: course?.universityId,
          courseId: x.courseId,
          courseName: course?.name,
          location: withoutStreet(x.location),
          teacher: course?.teacher,
          exam: x,
        ),
      );
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }
}

/// Periodo lungo: evento di tutto il giorno che dura più di una settimana.
bool isLongPeriod(CalendarEntry e) =>
    e.allDay && e.end.difference(e.start) > const Duration(days: 7);

/// Un periodo lungo (es. "Lezioni 1° semestre", "Esame … disponibile" per
/// tutta la sessione) non si ripete su ogni giorno: diventa un segnaposto il
/// primo giorno ("fino al 19/12") e uno l'ultimo ("Fine: …").
List<CalendarEntry> periodMarkers(CalendarEntry e) {
  if (!isLongPeriod(e)) return [e];
  final first = DateTime(e.start.year, e.start.month, e.start.day);
  // end è esclusivo (mezzanotte del giorno dopo) o un orario dell'ultimo giorno.
  final endInclusive = e.end.subtract(const Duration(minutes: 1));
  final last = DateTime(
    endInclusive.year,
    endInclusive.month,
    endInclusive.day,
  );
  CalendarEntry at(DateTime day, String title) => CalendarEntry(
    kind: e.kind,
    title: title,
    start: day,
    end: day.add(const Duration(days: 1)),
    color: e.color,
    allDay: true,
    universityId: e.universityId,
    courseId: e.courseId,
    courseName: e.courseName,
    location: e.location,
    teacher: e.teacher,
    event: e.event,
    exam: e.exam,
  );
  return [
    at(first, '${e.title} (fino al ${formatDmy(last)})'),
    at(last, 'Fine: ${e.title}'),
  ];
}
