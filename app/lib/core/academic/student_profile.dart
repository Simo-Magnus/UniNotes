import '../../utils/parse.dart';
import 'academic_year.dart';

/// Percorso di studio scelto nell'onboarding (tabella `profile`, una riga).
class StudentProfile {
  const StudentProfile({
    required this.universityId,
    required this.universityName,
    this.universityShort,
    this.universityType,
    required this.degreeId,
    required this.degreeName,
    required this.degreeType,
    this.classCode,
    required this.durationYears,
    required this.currentYear,
    this.fuoriCorso = false,
    required this.referenceAa,
    this.manual = false,
    this.catalogVersion,
    this.curriculum,
    this.startYear,
  });

  /// Anno di partenza: l'anno di corso indicato quando lo studente ha
  /// iniziato a usare l'app (onboarding o cambio di corso). Gli esami degli
  /// anni prima, se lo studente non li ha compilati, sono «Da completare»
  /// (non arretrati). Null = non ancora salvato (vedi [trackedFrom]).
  final int? startYear;

  /// Primo anno del piano seguito nell'app: l'anno di partenza (1 se non
  /// salvato), mai oltre l'anno frequentato.
  int get trackedFrom =>
      (startYear ?? 1).clamp(1, currentYear < 1 ? 1 : currentYear);

  /// Percorso seguito (curriculum, orientamento) nei corsi che ne hanno
  /// più d'uno; null = il percorso principale del corso.
  final String? curriculum;

  final String universityId;
  final String universityName;
  final String? universityShort;

  /// statale | non_statale | ordinamento_speciale | telematica
  final String? universityType;

  /// Id del corso nel catalogo, oppure `manuale:<ateneo>:<slug>`.
  final String degreeId;
  final String degreeName;

  /// L | LP | LM | LMCU | altro
  final String degreeType;
  final String? classCode;
  final int durationYears;

  /// Anno del piano frequentato in [referenceAa] (fuori corso: l'anno del
  /// piano che si sta completando).
  final int currentYear;
  final bool fuoriCorso;

  /// Anno accademico in cui lo studente frequenta [currentYear].
  final AcademicYear referenceAa;

  /// Corso inserito a mano («Aggiungi corso»).
  final bool manual;

  /// Versione del database (`meta.json.versione`) dell'ultimo import.
  final String? catalogVersion;

  String get universityLabel => universityShort ?? universityName;

  /// Anno accademico dell'anno [k] del piano.
  AcademicYear academicYearOf(int k) =>
      academicYearOfPlanYear(k, selected: currentYear, current: referenceAa);

  /// "2° anno · 2026/27" (o "Fuori corso · 2026/27").
  String yearChipLabel(int k) {
    final aa = academicYearOf(k).label;
    if (fuoriCorso && k == currentYear) return 'Fuori corso · $aa';
    return '${planYearLabel(k)} · $aa';
  }

  factory StudentProfile.fromMap(Map<String, Object?> m) => StudentProfile(
    universityId: m['university_id'] as String,
    universityName: m['university_name'] as String,
    universityShort: asString(m['university_short']),
    universityType: asString(m['university_type']),
    degreeId: m['degree_id'] as String,
    degreeName: m['degree_name'] as String,
    degreeType: asString(m['degree_type']) ?? 'altro',
    classCode: asString(m['class_code']),
    durationYears: asInt(m['duration_years']) ?? 3,
    currentYear: asInt(m['current_year']) ?? 1,
    fuoriCorso: asBool(m['fuori_corso']) ?? false,
    referenceAa:
        AcademicYear.tryParse(asString(m['reference_aa'])) ??
        AcademicYear.current(),
    manual: asBool(m['manual']) ?? false,
    catalogVersion: asString(m['catalog_version']),
    curriculum: asString(m['curriculum']),
    startYear: asInt(m['start_year']),
  );

  Map<String, Object?> toMap() => {
    'id': 1,
    'university_id': universityId,
    'university_name': universityName,
    'university_short': universityShort,
    'university_type': universityType,
    'degree_id': degreeId,
    'degree_name': degreeName,
    'degree_type': degreeType,
    'class_code': classCode,
    'duration_years': durationYears,
    'current_year': currentYear,
    'fuori_corso': fuoriCorso ? 1 : 0,
    'reference_aa': referenceAa.label,
    'manual': manual ? 1 : 0,
    'catalog_version': catalogVersion,
    'curriculum': curriculum,
    'start_year': startYear,
  };

  StudentProfile copyWith({
    String? degreeId,
    String? degreeName,
    String? degreeType,
    String? Function()? classCode,
    int? durationYears,
    int? currentYear,
    bool? fuoriCorso,
    AcademicYear? referenceAa,
    String? Function()? catalogVersion,
    String? Function()? curriculum,
    int? Function()? startYear,
  }) => StudentProfile(
    universityId: universityId,
    universityName: universityName,
    universityShort: universityShort,
    universityType: universityType,
    degreeId: degreeId ?? this.degreeId,
    degreeName: degreeName ?? this.degreeName,
    degreeType: degreeType ?? this.degreeType,
    classCode: classCode == null ? this.classCode : classCode(),
    durationYears: durationYears ?? this.durationYears,
    currentYear: currentYear ?? this.currentYear,
    fuoriCorso: fuoriCorso ?? this.fuoriCorso,
    referenceAa: referenceAa ?? this.referenceAa,
    manual: manual,
    catalogVersion: catalogVersion == null
        ? this.catalogVersion
        : catalogVersion(),
    curriculum: curriculum == null ? this.curriculum : curriculum(),
    startYear: startYear == null ? this.startYear : startYear(),
  );
}

/// Stato di un anno del piano (tabella `plan_years`).
enum PlanYearStatus {
  inCorso('in_corso', 'In corso'),
  completato('completato', 'Completato'),
  completatoParziale('completato_parziale', 'Completato in parte'),
  futuro('futuro', 'Futuro');

  const PlanYearStatus(this.key, this.label);
  final String key;
  final String label;

  static PlanYearStatus fromKey(String? k) {
    for (final v in values) {
      if (v.key == k) return v;
    }
    return PlanYearStatus.futuro;
  }
}

class PlanYear {
  const PlanYear({
    required this.year,
    required this.academicYear,
    required this.status,
  });
  final int year;
  final AcademicYear academicYear;
  final PlanYearStatus status;

  factory PlanYear.fromMap(Map<String, Object?> m) => PlanYear(
    year: asInt(m['year'])!,
    academicYear:
        AcademicYear.tryParse(asString(m['academic_year'])) ??
        AcademicYear.current(),
    status: PlanYearStatus.fromKey(asString(m['status'])),
  );

  Map<String, Object?> toMap() => {
    'year': year,
    'academic_year': academicYear.label,
    'status': status.key,
  };
}

/// Stato iniziale dell'anno [k] quando lo studente frequenta [current]:
/// gli anni passati restano "in corso" finché non vengono segnati come
/// completati (schermata dei voti), i successivi sono "futuri".
PlanYearStatus initialPlanYearStatus(int k, int current) =>
    k > current ? PlanYearStatus.futuro : PlanYearStatus.inCorso;

/// Anno di partenza ricavato per un profilo salvato prima che l'app lo
/// ricordasse: l'anno frequentato meno gli anni accademici passati dalla
/// creazione del profilo ([createdAt], `profile.created_at`), almeno 1. Senza
/// data di creazione l'anno frequentato. Nel dubbio l'anno è più basso
/// (più esami restano arretrati, come prima), mai più alto.
int deriveStartYear(StudentProfile p, {DateTime? createdAt}) {
  final current = p.currentYear < 1 ? 1 : p.currentYear;
  if (createdAt == null) return current;
  final passed = p.referenceAa.difference(AcademicYear.of(createdAt));
  return (current - (passed < 0 ? 0 : passed)).clamp(1, current);
}

/// Anni prima dell'anno di partenza [start] a parole: «del 1° anno», «del
/// 1° e del 2° anno», «dal 1° al 3° anno».
String previousYearsLabel(int start) => switch (start) {
  <= 2 => 'del 1° anno',
  3 => 'del 1° e del 2° anno',
  _ => 'dal 1° al ${start - 1}° anno',
};

/// Anni del piano (1..durata, più l'anno frequentato se fuori corso oltre).
List<int> planYearsOf(StudentProfile p) => [
  for (var k = 1; k <= p.durationYears; k++) k,
  for (var k = p.durationYears + 1; k <= p.currentYear; k++) k,
];
