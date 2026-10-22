import 'dart:convert';

import '../core/constants/enums.dart';
import '../utils/parse.dart';

/// Esame finale o prova in itinere (record distinti, stesso corso).
class Exam {
  const Exam({
    this.id,
    this.externalId,
    required this.courseId,
    this.kind = ExamKind.finalExam,
    this.title,
    this.date,
    this.time,
    this.location,
    this.examType,
    this.status = ExamStatus.planned,
    this.grade,
    this.laude = false,
    this.cfu,
    this.topics,
    this.studyMaterials = const [],
    this.notes,
    this.source,
  });

  final int? id;
  final String? externalId;
  final int courseId;
  final ExamKind kind;
  final String? title;

  /// Solo data (ora in [time], "HH:mm").
  final DateTime? date;
  final String? time;
  final String? location;

  /// scritto | orale | scritto+orale | quiz | progetto | altro
  final String? examType;
  final ExamStatus status;

  /// Voto in trentesimi (18-30), null se non presente.
  final int? grade;
  final bool laude;

  /// CFU dell'esame; se null si usano quelli del corso.
  final double? cfu;

  /// Argomenti oggetto della prova.
  final String? topics;

  /// Materiali da studiare (titoli o percorsi locali).
  final List<String> studyMaterials;
  final String? notes;
  final String? source;

  DateTime? get dateTime {
    if (date == null) return null;
    final t = time;
    if (t == null) return date;
    final parts = t.split(':');
    final h = int.tryParse(parts[0]) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    // ora non valida (dati importati o sincronizzati: «99:99», o numeri
    // enormi che il costruttore di DateTime rifiuta con un errore): vale
    // come giornata intera, come nell'agenda
    if (h < 0 || h > 23 || m < 0 || m > 59) {
      return DateTime(date!.year, date!.month, date!.day);
    }
    return DateTime(date!.year, date!.month, date!.day, h, m);
  }

  factory Exam.fromMap(Map<String, Object?> m) {
    final raw = asString(m['study_materials']);
    var materials = const <String>[];
    if (raw != null) {
      try {
        materials = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
      } catch (_) {
        materials = raw.split('\n').where((s) => s.trim().isNotEmpty).toList();
      }
    }
    return Exam(
      id: asInt(m['id']),
      externalId: asString(m['external_id']),
      courseId: asInt(m['course_id']) ?? 0,
      kind: ExamKind.fromKey(m['kind'] as String?),
      title: asString(m['title']),
      date: asDateTime(m['date']),
      time: asString(m['time']),
      location: asString(m['location']),
      examType: asString(m['exam_type']),
      status: ExamStatus.fromKey(m['status'] as String?),
      grade: asInt(m['grade']),
      laude: asBool(m['laude']) ?? false,
      cfu: asDouble(m['cfu']),
      topics: asString(m['topics']),
      studyMaterials: materials,
      notes: asString(m['notes']),
      source: asString(m['source']),
    );
  }

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'external_id': externalId,
    'course_id': courseId,
    'kind': kind.key,
    'title': title,
    'date': date == null ? null : isoDate(date!),
    'time': time,
    'location': location,
    'exam_type': examType,
    'status': status.key,
    'grade': grade,
    'laude': laude ? 1 : 0,
    'cfu': cfu,
    'topics': topics,
    'study_materials': studyMaterials.isEmpty
        ? null
        : jsonEncode(studyMaterials),
    'notes': notes,
    'source': source,
  };

  Exam copyWith({
    ExamStatus? status,
    int? grade,
    bool clearGrade = false,
    bool? laude,
    String? notes,
    DateTime? date,
    String? time,
    bool clearDate = false,
    String? location,
    String? title,
    String? examType,
    String? topics,
    List<String>? studyMaterials,
    ExamKind? kind,
    double? cfu,
  }) => Exam(
    id: id,
    externalId: externalId,
    courseId: courseId,
    kind: kind ?? this.kind,
    title: title ?? this.title,
    date: clearDate ? null : (date ?? this.date),
    time: clearDate ? null : (time ?? this.time),
    location: location ?? this.location,
    examType: examType ?? this.examType,
    status: status ?? this.status,
    grade: clearGrade ? null : (grade ?? this.grade),
    laude: laude ?? this.laude,
    cfu: cfu ?? this.cfu,
    topics: topics ?? this.topics,
    studyMaterials: studyMaterials ?? this.studyMaterials,
    notes: notes ?? this.notes,
    source: source,
  );
}
