import '../core/constants/enums.dart';
import '../utils/parse.dart';

class Course {
  const Course({
    this.id,
    this.externalId,
    this.universityId,
    this.degreeId,
    required this.name,
    this.code,
    this.teacher,
    this.year,
    this.semester,
    this.cfu,
    this.description,
    this.color,
    this.status = CourseStatus.active,
    this.lectureHours,
    this.difficulty,
    this.examMode,
    this.examStructure,
    this.optionalOralInfo,
    this.materialsFound,
    this.materialsNote,
    this.source,
    this.updatedAt,
    this.booksStatus,
    this.examsStatus,
    this.syllabusUrl,
    this.ssd,
    this.mandatory,
    this.curriculum,
    this.userEdited = false,
    this.examLanguage,
  });

  /// Modificato dallo studente: «Aggiorna database» non riscrive i campi
  /// del catalogo (nome, codice, docenti, anno, semestre, CFU).
  final bool userEdited;

  /// Lingua dell'esame scelta («en») per gli insegnamenti offerti anche in
  /// inglese; null = italiano.
  final String? examLanguage;

  final int? id;
  final String? externalId;
  final String? universityId;
  final String? degreeId;
  final String name;
  final String? code;
  final String? teacher;
  final int? year;
  final String? semester;
  final double? cfu;
  final String? description;

  /// Colore ARGB personalizzato; se null si usa quello dell'università.
  final int? color;
  final CourseStatus status;
  final double? lectureHours;

  /// Difficoltà 0-5.
  final double? difficulty;

  /// scritto | orale | scritto+orale | altro
  final String? examMode;
  final String? examStructure;
  final String? optionalOralInfo;
  final bool? materialsFound;
  final String? materialsNote;
  final String? source;
  final String? updatedAt;

  /// Stato dei libri nel catalogo pubblico: completo | da_aggiungere |
  /// nessun_libro (null = corso non dal catalogo).
  final String? booksStatus;

  /// Stato delle date d'esame nel catalogo: completo | da_aggiungere.
  final String? examsStatus;

  /// Pagina dell'insegnamento (scheda / syllabus).
  final String? syllabusUrl;
  final String? ssd;

  /// false = insegnamento a scelta.
  final bool? mandatory;
  final String? curriculum;

  /// Nome mostrato in Registra e Studio: «Robotica (a scelta)» per gli
  /// insegnamenti a scelta.
  String get label => mandatory == false ? '$name (a scelta)' : name;

  /// Il catalogo non ha ancora i libri di questo insegnamento.
  bool get booksToAdd => booksStatus == 'da_aggiungere';

  /// Il catalogo non ha ancora le date d'esame di questo insegnamento.
  bool get examsToAdd => examsStatus == 'da_aggiungere';

  factory Course.fromMap(Map<String, Object?> m) => Course(
    id: asInt(m['id']),
    externalId: asString(m['external_id']),
    universityId: asString(m['university_id']),
    degreeId: asString(m['degree_id']),
    name: m['name'] as String,
    code: asString(m['code']),
    teacher: asString(m['teacher']),
    year: asInt(m['year']),
    semester: asString(m['semester']),
    cfu: asDouble(m['cfu']),
    description: asString(m['description']),
    color: asInt(m['color']),
    status: CourseStatus.fromKey(m['status'] as String?),
    lectureHours: asDouble(m['lecture_hours']),
    difficulty: asDouble(m['difficulty']),
    examMode: asString(m['exam_mode']),
    examStructure: asString(m['exam_structure']),
    optionalOralInfo: asString(m['optional_oral_info']),
    materialsFound: asBool(m['materials_found']),
    materialsNote: asString(m['materials_note']),
    source: asString(m['source']),
    updatedAt: asString(m['updated_at']),
    booksStatus: asString(m['books_status']),
    examsStatus: asString(m['exams_status']),
    syllabusUrl: asString(m['syllabus_url']),
    ssd: asString(m['ssd']),
    mandatory: asBool(m['mandatory']),
    curriculum: asString(m['curriculum']),
    userEdited: asBool(m['user_edited']) ?? false,
    examLanguage: asString(m['exam_language']),
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'external_id': externalId,
    'university_id': universityId,
    'degree_id': degreeId,
    'name': name,
    'code': code,
    'teacher': teacher,
    'year': year,
    'semester': semester,
    'cfu': cfu,
    'description': description,
    'color': color,
    'status': status.key,
    'lecture_hours': lectureHours,
    'difficulty': difficulty,
    'exam_mode': examMode,
    'exam_structure': examStructure,
    'optional_oral_info': optionalOralInfo,
    'materials_found': materialsFound == null
        ? null
        : (materialsFound! ? 1 : 0),
    'materials_note': materialsNote,
    'source': source,
    'updated_at': updatedAt,
    'books_status': booksStatus,
    'exams_status': examsStatus,
    'syllabus_url': syllabusUrl,
    'ssd': ssd,
    'mandatory': mandatory == null ? null : (mandatory! ? 1 : 0),
    'curriculum': curriculum,
    'user_edited': userEdited ? 1 : 0,
    'exam_language': examLanguage,
  };

  Course withUserEdited() => Course(
    id: id,
    externalId: externalId,
    universityId: universityId,
    degreeId: degreeId,
    name: name,
    code: code,
    teacher: teacher,
    year: year,
    semester: semester,
    cfu: cfu,
    description: description,
    color: color,
    status: status,
    lectureHours: lectureHours,
    difficulty: difficulty,
    examMode: examMode,
    examStructure: examStructure,
    optionalOralInfo: optionalOralInfo,
    materialsFound: materialsFound,
    materialsNote: materialsNote,
    source: source,
    updatedAt: updatedAt,
    booksStatus: booksStatus,
    examsStatus: examsStatus,
    syllabusUrl: syllabusUrl,
    ssd: ssd,
    mandatory: mandatory,
    curriculum: curriculum,
    userEdited: true,
    examLanguage: examLanguage,
  );

  Course copyWith({
    String? name,
    String? code,
    String? teacher,
    int? year,
    String? semester,
    double? cfu,
    String? description,
    int? color,
    CourseStatus? status,
    String? universityId,
    String? degreeId,
    bool? mandatory,
    String? syllabusUrl,
  }) => Course(
    id: id,
    externalId: externalId,
    universityId: universityId ?? this.universityId,
    degreeId: degreeId ?? this.degreeId,
    name: name ?? this.name,
    code: code ?? this.code,
    teacher: teacher ?? this.teacher,
    year: year ?? this.year,
    semester: semester ?? this.semester,
    cfu: cfu ?? this.cfu,
    description: description ?? this.description,
    color: color ?? this.color,
    status: status ?? this.status,
    lectureHours: lectureHours,
    difficulty: difficulty,
    examMode: examMode,
    examStructure: examStructure,
    optionalOralInfo: optionalOralInfo,
    materialsFound: materialsFound,
    materialsNote: materialsNote,
    source: source,
    updatedAt: updatedAt,
    booksStatus: booksStatus,
    examsStatus: examsStatus,
    syllabusUrl: syllabusUrl ?? this.syllabusUrl,
    ssd: ssd,
    mandatory: mandatory ?? this.mandatory,
    curriculum: curriculum,
    userEdited: userEdited,
    examLanguage: examLanguage,
  );
}
