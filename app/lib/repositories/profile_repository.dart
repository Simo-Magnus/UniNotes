import 'package:sqflite/sqflite.dart';

import '../core/academic/academic_year.dart';
import '../core/academic/student_profile.dart';
import '../core/database/app_database.dart';
import '../utils/parse.dart';

/// Profilo dello studente e stato degli anni del piano.
class ProfileRepository {
  ProfileRepository(this._db);
  final AppDatabase _db;

  Future<StudentProfile?> load() async {
    final rows = await _db.db.query('profile', where: 'id = 1');
    return rows.isEmpty ? null : StudentProfile.fromMap(rows.first);
  }

  /// Salva il profilo e riallinea gli anni del piano: anni accademici
  /// ricalcolati, stati "completato" già segnati conservati.
  Future<void> save(StudentProfile p, {DateTime? now}) async {
    final stamp = isoLocal(now ?? DateTime.now());
    await _db.db.transaction((txn) async {
      final existing = await txn.query('profile', where: 'id = 1');
      await txn.insert('profile', {
        ...p.toMap(),
        'created_at': existing.isEmpty
            ? stamp
            : existing.first['created_at'] ?? stamp,
        'updated_at': stamp,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _syncPlanYears(txn, p);
    });
  }

  /// Nuovo percorso (onboarding da capo): gli stati degli anni ripartono.
  Future<void> replace(StudentProfile p) async {
    await _db.db.delete('plan_years');
    await save(p);
  }

  Future<void> _syncPlanYears(DatabaseExecutor ex, StudentProfile p) async {
    final current = {
      for (final r in await ex.query('plan_years'))
        asInt(r['year'])!: PlanYear.fromMap(r),
    };
    final years = planYearsOf(p);
    for (final k in years) {
      final old = current[k];
      var status = old?.status ?? initialPlanYearStatus(k, p.currentYear);
      // Un anno passato da "futuro" all'anno in corso (o prima) diventa "in
      // corso"; un anno tornato nel futuro (cambio d'anno a mano) "futuro",
      // a meno che lo studente non l'abbia già completato.
      final done =
          status == PlanYearStatus.completato ||
          status == PlanYearStatus.completatoParziale;
      if (!done) status = initialPlanYearStatus(k, p.currentYear);
      await ex.insert(
        'plan_years',
        PlanYear(
          year: k,
          academicYear: p.academicYearOf(k),
          status: status,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    final extra = current.keys.where((k) => !years.contains(k)).toList();
    for (final k in extra) {
      await ex.delete('plan_years', where: 'year = ?', whereArgs: [k]);
    }
  }

  Future<List<PlanYear>> planYears() async {
    final rows = await _db.db.query('plan_years', orderBy: 'year');
    return rows.map(PlanYear.fromMap).toList();
  }

  Future<PlanYear?> planYear(int year) async {
    final rows = await _db.db.query(
      'plan_years',
      where: 'year = ?',
      whereArgs: [year],
    );
    return rows.isEmpty ? null : PlanYear.fromMap(rows.first);
  }

  Future<void> setYearStatus(
    int year,
    PlanYearStatus status, {
    AcademicYear? academicYear,
  }) async {
    final existing = await planYear(year);
    await _db.db.insert(
      'plan_years',
      PlanYear(
        year: year,
        academicYear:
            academicYear ?? existing?.academicYear ?? AcademicYear.current(),
        status: status,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Toglie il profilo (torna l'onboarding). I dati personali restano.
  Future<void> clear() async {
    await _db.db.delete('profile');
    await _db.db.delete('plan_years');
  }
}
