import 'academic_year.dart';
import 'student_profile.dart';

/// Passaggio a un nuovo anno accademico (primo avvio dopo il 1° settembre di
/// un anno accademico successivo a quello del profilo).
class YearTransition {
  const YearTransition({
    required this.from,
    required this.to,
    required this.currentYear,
    required this.nextYear,
    required this.becomesFuoriCorso,
  });

  /// Anno accademico del profilo e quello appena iniziato.
  final AcademicYear from;
  final AcademicYear to;

  /// Anno del piano frequentato finora.
  final int currentYear;

  /// Anno del piano proposto ora (al massimo la durata del corso).
  final int nextYear;

  /// Lo studente supererebbe la durata normale: si chiede "sei fuori corso?".
  final bool becomesFuoriCorso;

  /// "È iniziato il nuovo anno accademico 2027/28: sei al 3° anno?"
  String get question => becomesFuoriCorso
      ? 'È iniziato il nuovo anno accademico ${to.label}: sei fuori corso?'
      : 'È iniziato il nuovo anno accademico ${to.label}: '
            'sei al ${planYearLabel(nextYear)}?';
}

/// Passaggio da proporre alla data [now], oppure null se l'anno accademico
/// del profilo è ancora quello in corso.
YearTransition? pendingTransition(StudentProfile p, DateTime now) {
  final aa = AcademicYear.of(now);
  final diff = aa.difference(p.referenceAa);
  if (diff <= 0) return null;
  final target = p.currentYear + diff;
  final over = target > p.durationYears;
  return YearTransition(
    from: p.referenceAa,
    to: aa,
    currentYear: p.currentYear,
    nextYear: over ? p.durationYears : target,
    becomesFuoriCorso: over,
  );
}

/// Profilo dopo la risposta alla domanda del nuovo anno: [advance] = sì
/// (passa all'anno proposto / fuori corso), no = ripete l'anno in corso.
StudentProfile applyTransition(
  StudentProfile p,
  YearTransition t, {
  required bool advance,
}) {
  if (!advance) return p.copyWith(referenceAa: t.to);
  return p.copyWith(
    currentYear: t.nextYear,
    fuoriCorso: t.becomesFuoriCorso || p.fuoriCorso,
    referenceAa: t.to,
  );
}
