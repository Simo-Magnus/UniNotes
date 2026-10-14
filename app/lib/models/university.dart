import '../utils/parse.dart';

class University {
  const University({
    required this.id,
    required this.name,
    required this.shortName,
    required this.color,
    this.website,
    this.source,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String shortName;
  final int color;
  final String? website;
  final String? source;
  final String? updatedAt;

  factory University.fromMap(Map<String, Object?> m) => University(
    id: m['id'] as String,
    name: m['name'] as String,
    shortName: m['short_name'] as String,
    color: asInt(m['color']) ?? 0xFF607D8B,
    website: asString(m['website']),
    source: asString(m['source']),
    updatedAt: asString(m['updated_at']),
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'short_name': shortName,
    'color': color,
    'website': website,
    'source': source,
    'updated_at': updatedAt,
  };
}

class Degree {
  const Degree({
    required this.id,
    required this.universityId,
    required this.name,
    this.classCode,
    this.minEntryScore,
    this.maxGraduationScore,
    this.referenceAverages,
    this.notes,
    this.source,
    this.updatedAt,
  });

  final String id;
  final String universityId;
  final String name;
  final String? classCode;
  final String? minEntryScore;
  final String? maxGraduationScore;
  final String? referenceAverages;
  final String? notes;
  final String? source;
  final String? updatedAt;

  factory Degree.fromMap(Map<String, Object?> m) => Degree(
    id: m['id'] as String,
    universityId: m['university_id'] as String,
    name: m['name'] as String,
    classCode: asString(m['class_code']),
    minEntryScore: asString(m['min_entry_score']),
    maxGraduationScore: asString(m['max_graduation_score']),
    referenceAverages: asString(m['reference_averages']),
    notes: asString(m['notes']),
    source: asString(m['source']),
    updatedAt: asString(m['updated_at']),
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'university_id': universityId,
    'name': name,
    'class_code': classCode,
    'min_entry_score': minEntryScore,
    'max_graduation_score': maxGraduationScore,
    'reference_averages': referenceAverages,
    'notes': notes,
    'source': source,
    'updated_at': updatedAt,
  };
}
