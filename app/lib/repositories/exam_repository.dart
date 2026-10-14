import '../core/constants/enums.dart';
import '../core/database/app_database.dart';
import '../models/exam.dart';

class ExamRepository {
  ExamRepository(this._db);
  final AppDatabase _db;

  Future<List<Exam>> all() async {
    final rows = await _db.db.query(
      'exams',
      orderBy: 'date IS NULL, date, time',
    );
    return rows.map(Exam.fromMap).toList();
  }

  Future<List<Exam>> byCourse(int courseId) async {
    final rows = await _db.db.query(
      'exams',
      where: 'course_id = ?',
      whereArgs: [courseId],
      orderBy: 'date IS NULL, date, time',
    );
    return rows.map(Exam.fromMap).toList();
  }

  Future<List<Exam>> upcoming({int limit = 10}) async {
    final today = DateTime.now();
    final d =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final rows = await _db.db.query(
      'exams',
      where: "date >= ? AND status IN ('planned','booked')",
      whereArgs: [d],
      orderBy: 'date, time',
      limit: limit,
    );
    return rows.map(Exam.fromMap).toList();
  }

  Future<int> insert(Exam e) => _db.db.insert('exams', e.toMap()..remove('id'));

  Future<void> update(Exam e) =>
      _db.db.update('exams', e.toMap(), where: 'id = ?', whereArgs: [e.id]);

  Future<void> delete(int id) =>
      _db.db.delete('exams', where: 'id = ?', whereArgs: [id]);

  /// Inserisce se `id` è null, altrimenti aggiorna. Restituisce l'id.
  Future<int> save(Exam e) async {
    if (e.id == null) return insert(e);
    await update(e);
    return e.id!;
  }

  Future<Exam?> byId(int id) async {
    final rows = await _db.db.query('exams', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Exam.fromMap(rows.first);
  }

  /// Esami/prove con uno degli stati indicati, in ordine di data.
  Future<List<Exam>> byStatus(Iterable<ExamStatus> statuses) async {
    final keys = statuses.map((s) => s.key).toList();
    if (keys.isEmpty) return const [];
    final marks = List.filled(keys.length, '?').join(',');
    final rows = await _db.db.query(
      'exams',
      where: 'status IN ($marks)',
      whereArgs: keys,
      orderBy: 'date IS NULL, date, time',
    );
    return rows.map(Exam.fromMap).toList();
  }
}
