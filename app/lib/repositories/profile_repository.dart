import 'package:sqflite/sqflite.dart';

import '../core/academic/academic_year.dart';
import '../core/academic/student_profile.dart';
import '../core/database/app_database.dart';
import '../utils/parse.dart';
import 'exam_repository.dart';

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
  /// Un profilo senza anno di partenza ([StudentProfile.startYear] null, es.
  /// dal passaggio al nuovo anno accademico) tiene quello già salvato.
  Future<void> save(StudentProfile p, {DateTime? now}) async {
    final stamp = isoLocal(now ?? DateTime.now());
    await _db.db.transaction((txn) async {
      final existing = await txn.query('profile', where: 'id = 1');
      await txn.insert('profile', {
        ...p.toMap(),
        'start_year':
            p.startYear ??
            (existing.isEmpty ? null : asInt(existing.first['start_year'])),
        'created_at': existing.isEmpty
            ? stamp
            : existing.first['created_at'] ?? stamp,
        'updated_at': stamp,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _syncPlanYears(txn, p);
    });
  }

  /// Nuovo percorso (onboarding da capo o cambio di corso): gli stati degli
  /// anni ripartono e l'anno scelto diventa l'anno di partenza. Gli esami
  /// degli anni prima mai compilati diventano «Da completare» (sullo stesso
  /// corso di laurea solo quelli degli anni che prima erano seguiti
  /// nell'app: le scelte già fatte negli Anni precedenti restano); quelli
  /// «Da completare» dall'anno di partenza in poi tornano «Da prenotare».
  Future<void> replace(StudentProfile p) async {
    final old = await load();
    final start = p.startYear ?? p.currentYear;
    await _db.db.delete('plan_years');
    await save(p.copyWith(startYear: () => start));
    final exams = ExamRepository(_db);
    await exams.restoreFromStartYear(start, degreeId: p.degreeId);
    await exams.markToComplete(
      below: start,
      from: old?.degreeId == p.degreeId ? old?.startYear : null,
      degreeId: p.degreeId,
    );
  }

  /// Anno di partenza del profilo [p] letto dal database: se manca (profilo
  /// di una versione precedente) si ricava da quando il profilo è stato
  /// creato ([deriveStartYear]), si salva e gli esami degli anni prima mai
  /// compilati diventano «Da completare» (una volta sola: poi l'anno c'è).
  /// A ogni avvio gli esami «Da completare» dall'anno di partenza in poi (es.
  /// arrivati dalla sincronizzazione con un altro anno) tornano «Da
  /// prenotare». Restituisce il profilo con l'anno.
  Future<StudentProfile> ensureStartYear(StudentProfile p) async {
    final exams = ExamRepository(_db);
    if (p.startYear != null) {
      await exams.restoreFromStartYear(p.trackedFrom, degreeId: p.degreeId);
      return p;
    }
    final rows = await _db.db.query(
      'profile',
      columns: ['created_at'],
      where: 'id = 1',
    );
    final created = rows.isEmpty
        ? null
        : DateTime.tryParse(asString(rows.first['created_at']) ?? '');
    final start = deriveStartYear(p, createdAt: created);
    await _db.db.update('profile', {'start_year': start}, where: 'id = 1');
    await exams.markToComplete(below: start, degreeId: p.degreeId);
    return p.copyWith(startYear: () => start);
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
