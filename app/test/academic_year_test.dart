import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/academic/academic_year.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/academic/year_transition.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/repositories/profile_repository.dart';

StudentProfile _profile({
  int year = 2,
  int duration = 3,
  String aa = '2026/27',
  bool fuoriCorso = false,
}) => StudentProfile(
  universityId: 'unibo',
  universityName: 'Università degli Studi di Bologna',
  universityShort: 'UniBo',
  degreeId: 'unibo-l8-ing',
  degreeName: 'Ingegneria informatica',
  degreeType: 'L',
  durationYears: duration,
  currentYear: year,
  fuoriCorso: fuoriCorso,
  referenceAa: AcademicYear.tryParse(aa)!,
);

void main() {
  group('anno accademico (inizio 1° settembre)', () {
    test('31 agosto è ancora l\'anno precedente, 1° settembre il nuovo', () {
      expect(AcademicYear.of(DateTime(2026, 8, 31, 23, 59)).label, '2025/26');
      expect(AcademicYear.of(DateTime(2026, 9, 1)).label, '2026/27');
      expect(AcademicYear.of(DateTime(2026, 10, 4)).label, '2026/27');
      expect(AcademicYear.of(DateTime(2027, 1, 15)).label, '2026/27');
      expect(AcademicYear.of(DateTime(2099, 12, 31)).label, '2099/00');
    });

    test('parsing, confronto, limiti', () {
      final aa = AcademicYear.tryParse('2026/27')!;
      expect(aa, const AcademicYear(2026));
      expect(AcademicYear.tryParse('2026/2027'), aa);
      expect(AcademicYear.tryParse('boh'), isNull);
      expect((aa + 1).label, '2027/28');
      expect(aa > const AcademicYear(2025), isTrue);
      expect(aa.start, DateTime(2026, 9, 1));
      expect(aa.contains(DateTime(2027, 8, 31)), isTrue);
      expect(aa.contains(DateTime(2027, 9, 1)), isFalse);
      expect(aa.end.isBefore(DateTime(2027, 9, 1)), isTrue);
    });
  });

  group('anni del piano → anni accademici', () {
    test('anno k = corrente − (scelto − k)', () {
      const cur = AcademicYear(2026);
      expect(
        academicYearOfPlanYear(1, selected: 2, current: cur).label,
        '2025/26',
      );
      expect(
        academicYearOfPlanYear(2, selected: 2, current: cur).label,
        '2026/27',
      );
      expect(
        academicYearOfPlanYear(3, selected: 2, current: cur).label,
        '2027/28',
      );
      expect(
        planYearInAcademicYear(
          const AcademicYear(2027),
          selected: 2,
          current: cur,
        ),
        3,
      );
    });

    test('etichetta del selettore', () {
      final p = _profile();
      expect(p.yearChipLabel(2), '2° anno · 2026/27');
      expect(p.yearChipLabel(1), '1° anno · 2025/26');
      expect(
        _profile(year: 3, fuoriCorso: true).yearChipLabel(3),
        'Fuori corso · 2026/27',
      );
      expect(planYearsOf(p), [1, 2, 3]);
    });
  });

  group('nuovo anno accademico', () {
    test('nessuna domanda nello stesso anno', () {
      expect(pendingTransition(_profile(), DateTime(2027, 8, 31)), isNull);
    });

    test('dal 1° settembre: "sei al 3° anno?"', () {
      final t = pendingTransition(_profile(), DateTime(2027, 9, 1))!;
      expect(t.to.label, '2027/28');
      expect(t.nextYear, 3);
      expect(t.becomesFuoriCorso, isFalse);
      expect(
        t.question,
        'È iniziato il nuovo anno accademico 2027/28: sei al 3° anno?',
      );
      final next = applyTransition(_profile(), t, advance: true);
      expect(next.currentYear, 3);
      expect(next.referenceAa.label, '2027/28');
      expect(next.academicYearOf(1).label, '2025/26');
      // "No": stesso anno del piano nel nuovo anno accademico.
      final same = applyTransition(_profile(), t, advance: false);
      expect(same.currentYear, 2);
      expect(same.academicYearOf(2).label, '2027/28');
    });

    test('dopo l\'ultimo anno: fuori corso', () {
      final t = pendingTransition(_profile(year: 3), DateTime(2027, 10, 1))!;
      expect(t.becomesFuoriCorso, isTrue);
      expect(t.question, contains('fuori corso'));
      final next = applyTransition(_profile(year: 3), t, advance: true);
      expect(next.currentYear, 3);
      expect(next.fuoriCorso, isTrue);
    });
  });

  test('profilo e anni del piano nel database', () async {
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    final repo = ProfileRepository(db);
    expect(await repo.load(), isNull);
    await repo.save(_profile());
    final p = (await repo.load())!;
    expect(p.universityId, 'unibo');
    expect(p.referenceAa.label, '2026/27');
    var years = await repo.planYears();
    expect(
      [for (final y in years) y.academicYear.label],
      ['2025/26', '2026/27', '2027/28'],
    );
    expect(
      [for (final y in years) y.status],
      [PlanYearStatus.inCorso, PlanYearStatus.inCorso, PlanYearStatus.futuro],
    );
    // Il 1° anno completato resta tale dopo il passaggio al 3° anno.
    await repo.setYearStatus(1, PlanYearStatus.completato);
    await repo.save(
      p.copyWith(currentYear: 3, referenceAa: const AcademicYear(2027)),
    );
    years = await repo.planYears();
    expect(years[0].status, PlanYearStatus.completato);
    expect(years[0].academicYear.label, '2025/26');
    expect(years[2].status, PlanYearStatus.inCorso);
    expect(years[2].academicYear.label, '2027/28');
  });
}
