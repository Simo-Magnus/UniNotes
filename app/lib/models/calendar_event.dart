import '../core/constants/enums.dart';
import '../utils/parse.dart';

/// Elemento del calendario: lezione, finestra d'esame, evento, studio
/// pianificato o scadenza. Esami e prove in itinere stanno nella tabella
/// exams e vengono uniti al calendario dal CalendarRepository.
class CalendarEvent {
  const CalendarEvent({
    this.id,
    this.externalId,
    this.courseId,
    this.universityId,
    required this.type,
    required this.title,
    required this.start,
    this.end,
    this.allDay = false,
    this.room,
    this.building,
    this.site,
    this.teacher,
    this.notes,
    this.placeId,
    this.source,
  });

  final int? id;
  final String? externalId;
  final int? courseId;
  final String? universityId;
  final EventType type;
  final String title;
  final DateTime start;
  final DateTime? end;
  final bool allDay;
  final String? room;
  final String? building;
  final String? site;
  final String? teacher;
  final String? notes;
  final int? placeId;
  final String? source;

  DateTime get effectiveEnd =>
      end ??
      (allDay
          ? start.add(const Duration(days: 1))
          : start.add(const Duration(hours: 1)));

  factory CalendarEvent.fromMap(Map<String, Object?> m) => CalendarEvent(
    id: asInt(m['id']),
    externalId: asString(m['external_id']),
    courseId: asInt(m['course_id']),
    universityId: asString(m['university_id']),
    type: EventType.fromKey(m['type'] as String?),
    title: m['title'] as String,
    start: asDateTime(m['start_at'])!,
    end: asDateTime(m['end_at']),
    allDay: asBool(m['all_day']) ?? false,
    room: asString(m['room']),
    building: asString(m['building']),
    site: asString(m['site']),
    teacher: asString(m['teacher']),
    notes: asString(m['notes']),
    placeId: asInt(m['place_id']),
    source: asString(m['source']),
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'external_id': externalId,
    'course_id': courseId,
    'university_id': universityId,
    'type': type.key,
    'title': title,
    'start_at': isoLocal(start),
    'end_at': end == null ? null : isoLocal(end!),
    'all_day': allDay ? 1 : 0,
    'room': room,
    'building': building,
    'site': site,
    'teacher': teacher,
    'notes': notes,
    'place_id': placeId,
    'source': source,
  };
}
