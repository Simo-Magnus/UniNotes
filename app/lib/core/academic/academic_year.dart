/// Anni accademici e corrispondenza con gli anni del piano di studi.
library;

/// L'anno accademico inizia il **1° settembre** (convenzione dell'app,
/// costante per tutti gli atenei): dal 1° settembre 2026 al 31 agosto 2027
/// è l'anno accademico "2026/27".
const int kAcademicYearStartMonth = 9;
const int kAcademicYearStartDay = 1;

/// Anno accademico identificato dall'anno solare in cui inizia.
class AcademicYear implements Comparable<AcademicYear> {
  const AcademicYear(this.startYear);

  /// Anno solare d'inizio (2026 per "2026/27").
  final int startYear;

  /// Anno accademico in corso alla data [d].
  factory AcademicYear.of(DateTime d) {
    final started =
        d.month > kAcademicYearStartMonth ||
        (d.month == kAcademicYearStartMonth && d.day >= kAcademicYearStartDay);
    return AcademicYear(started ? d.year : d.year - 1);
  }

  factory AcademicYear.current() => AcademicYear.of(DateTime.now());

  /// Accetta "2026/27", "2026/2027", "2026-27" o "2026".
  static AcademicYear? tryParse(String? s) {
    if (s == null) return null;
    final m = RegExp(r'^\s*(\d{4})').firstMatch(s);
    if (m == null) return null;
    return AcademicYear(int.parse(m.group(1)!));
  }

  /// "2026/27"
  String get label =>
      '$startYear/${((startYear + 1) % 100).toString().padLeft(2, '0')}';

  DateTime get start =>
      DateTime(startYear, kAcademicYearStartMonth, kAcademicYearStartDay);

  /// Ultimo istante dell'anno accademico (31 agosto, 23:59:59).
  DateTime get end =>
      start.copyWith(year: startYear + 1).subtract(const Duration(seconds: 1));

  bool contains(DateTime d) => AcademicYear.of(d) == this;

  AcademicYear operator +(int years) => AcademicYear(startYear + years);
  AcademicYear operator -(int years) => AcademicYear(startYear - years);

  /// Differenza in anni (this − other).
  int difference(AcademicYear other) => startYear - other.startYear;

  @override
  int compareTo(AcademicYear other) => startYear.compareTo(other.startYear);

  bool operator <(AcademicYear o) => startYear < o.startYear;
  bool operator >(AcademicYear o) => startYear > o.startYear;

  @override
  bool operator ==(Object other) =>
      other is AcademicYear && other.startYear == startYear;

  @override
  int get hashCode => startYear.hashCode;

  @override
  String toString() => label;
}

/// Anno accademico dell'anno [k] del piano, sapendo che lo studente frequenta
/// l'anno [selected] nell'anno accademico [current]:
/// `current − (selected − k)`. Esempio: 2° anno nel 2026/27 → 1° anno nel
/// 2025/26, 3° anno nel 2027/28.
AcademicYear academicYearOfPlanYear(
  int k, {
  required int selected,
  required AcademicYear current,
}) => current - (selected - k);

/// Anno del piano frequentato nell'anno accademico [aa] (può uscire da
/// 1..durata: chi controlla deve limitarlo).
int planYearInAcademicYear(
  AcademicYear aa, {
  required int selected,
  required AcademicYear current,
}) => selected + aa.difference(current);

/// "2° anno"
String planYearLabel(int year) => '$year° anno';
