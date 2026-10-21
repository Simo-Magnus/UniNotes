import '../core/database/app_database.dart';
import '../models/course.dart';
import '../models/university.dart';

class CourseRepository {
  CourseRepository(this._db);
  final AppDatabase _db;

  Future<List<University>> universities() async {
    final rows = await _db.db.query('universities', orderBy: 'name');
    return rows.map(University.fromMap).toList();
  }

  Future<List<Degree>> degrees() async {
    final rows = await _db.db.query('degrees', orderBy: 'name');
    return rows.map(Degree.fromMap).toList();
  }

  Future<void> updateUniversityColor(String id, int color) => _db.db.update(
    'universities',
    {'color': color},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<List<Course>> all({String? universityId}) async {
    final rows = await _db.db.query(
      'courses',
      where: universityId == null ? null : 'university_id = ?',
      whereArgs: universityId == null ? null : [universityId],
      orderBy:
          'university_id, year, semester, COALESCE(custom_name, name) '
          'COLLATE NOCASE',
    );
    return rows.map(Course.fromMap).toList();
  }

  /// Nome scelto dallo studente per l'insegnamento [id]: vuoto o uguale a
  /// quello ufficiale lo toglie (torna il nome ufficiale). Solo la colonna
  /// `custom_name`: il nome ufficiale resta quello del database dei corsi.
  Future<void> setCustomName(int id, String? name) async {
    final rows = await _db.db.query(
      'courses',
      columns: ['name'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return;
    final clean = cleanCourseName(name);
    await _db.db.update(
      'courses',
      {'custom_name': clean == rows.first['name'] ? null : clean},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Course?> byId(int id) async {
    final rows = await _db.db.query(
      'courses',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : Course.fromMap(rows.first);
  }

  Future<int> insert(Course c) =>
      _db.db.insert('courses', c.toMap()..remove('id'));

  Future<void> update(Course c) =>
      _db.db.update('courses', c.toMap(), where: 'id = ?', whereArgs: [c.id]);

  Future<void> delete(int id) =>
      _db.db.delete('courses', where: 'id = ?', whereArgs: [id]);

  /// Inserisce se `id` è null, altrimenti aggiorna. Restituisce l'id.
  Future<int> save(Course c) async {
    if (c.id == null) return insert(c);
    await update(c);
    return c.id!;
  }

  /// Corsi indicizzati per id (utile per calcolo medie e raggruppamenti).
  Future<Map<int, Course>> mapById() async {
    final list = await all();
    return {for (final c in list) c.id!: c};
  }

  /// Università indicizzate per id.
  Future<Map<String, University>> universitiesById() async {
    final list = await universities();
    return {for (final u in list) u.id: u};
  }

  /// Corsi di laurea di un'università.
  Future<List<Degree>> degreesOf(String universityId) async {
    final rows = await _db.db.query(
      'degrees',
      where: 'university_id = ?',
      whereArgs: [universityId],
      orderBy: 'name',
    );
    return rows.map(Degree.fromMap).toList();
  }
}
