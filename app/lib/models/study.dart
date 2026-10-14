import '../core/constants/enums.dart';
import '../utils/parse.dart';

class StudyModule {
  const StudyModule({
    this.id,
    required this.courseId,
    required this.name,
    this.sort = 0,
    this.notes,
  });

  final int? id;
  final int courseId;
  final String name;
  final int sort;

  /// Nota del modulo (menu «Nota»).
  final String? notes;

  factory StudyModule.fromMap(Map<String, Object?> m) => StudyModule(
    id: asInt(m['id']),
    courseId: asInt(m['course_id'])!,
    name: m['name'] as String,
    sort: asInt(m['sort']) ?? 0,
    notes: asString(m['notes']),
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'course_id': courseId,
    'name': name,
    'sort': sort,
    'notes': notes,
  };

  /// Copia con nome e/o nota cambiati ([notes] vuota = nessuna nota).
  StudyModule copyWith({String? name, String? notes}) => StudyModule(
    id: id,
    courseId: courseId,
    name: name ?? this.name,
    sort: sort,
    notes: notes == null ? this.notes : (notes.trim().isEmpty ? null : notes),
  );
}

class Topic {
  const Topic({
    this.id,
    required this.moduleId,
    required this.name,
    this.status = TopicStatus.notStarted,
    this.theoryDone = false,
    this.exercisesDone = false,
    this.reviewDone = false,
    this.notes,
    this.sort = 0,
  });

  final int? id;
  final int moduleId;
  final String name;
  final TopicStatus status;
  final bool theoryDone;
  final bool exercisesDone;
  final bool reviewDone;
  final String? notes;
  final int sort;

  factory Topic.fromMap(Map<String, Object?> m) => Topic(
    id: asInt(m['id']),
    moduleId: asInt(m['module_id'])!,
    name: m['name'] as String,
    status: TopicStatus.fromKey(m['status'] as String?),
    theoryDone: asBool(m['theory_done']) ?? false,
    exercisesDone: asBool(m['exercises_done']) ?? false,
    reviewDone: asBool(m['review_done']) ?? false,
    notes: asString(m['notes']),
    sort: asInt(m['sort']) ?? 0,
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'module_id': moduleId,
    'name': name,
    'status': status.key,
    'theory_done': theoryDone ? 1 : 0,
    'exercises_done': exercisesDone ? 1 : 0,
    'review_done': reviewDone ? 1 : 0,
    'notes': notes,
    'sort': sort,
  };

  Topic copyWith({
    String? name,
    TopicStatus? status,
    bool? theoryDone,
    bool? exercisesDone,
    bool? reviewDone,
    String? notes,
  }) => Topic(
    id: id,
    moduleId: moduleId,
    name: name ?? this.name,
    status: status ?? this.status,
    theoryDone: theoryDone ?? this.theoryDone,
    exercisesDone: exercisesDone ?? this.exercisesDone,
    reviewDone: reviewDone ?? this.reviewDone,
    notes: notes ?? this.notes,
    sort: sort,
  );
}

class StudySession {
  const StudySession({
    this.id,
    this.courseId,
    this.topicId,
    required this.start,
    this.end,
    required this.durationMinutes,
    this.activityType = ActivityType.other,
    this.notes,
    this.moduleId,
    this.focus = false,
    this.plannedMinutes,
  });

  final int? id;
  final int? courseId;
  final int? topicId;
  final DateTime start;
  final DateTime? end;
  final int durationMinutes;
  final ActivityType activityType;
  final String? notes;

  /// Modulo di Studio (sessioni Focus collegate a un modulo intero).
  final int? moduleId;

  /// Sessione Focus (le altre: cronometro o aggiunte a mano).
  final bool focus;

  /// Durata scelta per la sessione Focus, pause comprese.
  final int? plannedMinutes;

  factory StudySession.fromMap(Map<String, Object?> m) => StudySession(
    id: asInt(m['id']),
    courseId: asInt(m['course_id']),
    topicId: asInt(m['topic_id']),
    start: asDateTime(m['start_at'])!,
    end: asDateTime(m['end_at']),
    durationMinutes: asInt(m['duration_minutes']) ?? 0,
    activityType: ActivityType.fromKey(m['activity_type'] as String?),
    notes: asString(m['notes']),
    moduleId: asInt(m['module_id']),
    focus: asBool(m['focus']) ?? false,
    plannedMinutes: asInt(m['planned_minutes']),
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'course_id': courseId,
    'topic_id': topicId,
    'start_at': isoLocal(start),
    'end_at': end == null ? null : isoLocal(end!),
    'duration_minutes': durationMinutes,
    'activity_type': activityType.key,
    'notes': notes,
    'module_id': moduleId,
    'focus': focus ? 1 : 0,
    'planned_minutes': plannedMinutes,
  };
}
