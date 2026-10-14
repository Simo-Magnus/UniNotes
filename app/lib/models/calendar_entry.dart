import 'dart:ui' show Color;

import 'calendar_event.dart';
import 'exam.dart';

enum CalendarEntryKind {
  lecture('Lezione'),
  exam('Esame'),
  midterm('Prova in itinere'),
  examWindow('Esame disponibile'),
  event('Evento'),
  studyPlan('Studio pianificato'),
  deadline('Scadenza');

  const CalendarEntryKind(this.label);
  final String label;
}

/// Vista unificata per il calendario (eventi + esami/prove in itinere).
class CalendarEntry {
  const CalendarEntry({
    required this.kind,
    required this.title,
    required this.start,
    required this.end,
    required this.color,
    this.allDay = false,
    this.universityId,
    this.courseId,
    this.courseName,
    this.location,
    this.teacher,
    this.event,
    this.exam,
  });

  final CalendarEntryKind kind;
  final String title;
  final DateTime start;
  final DateTime end;
  final Color color;
  final bool allDay;
  final String? universityId;
  final int? courseId;
  final String? courseName;
  final String? location;
  final String? teacher;

  /// Origine: uno dei due è valorizzato.
  final CalendarEvent? event;
  final Exam? exam;
}
