import '../core/database/app_database.dart';
import '../models/book.dart';

class BookRepository {
  BookRepository(this._db);
  final AppDatabase _db;

  Future<List<Book>> all({int? courseId}) async {
    final rows = await _db.db.query(
      'books',
      where: courseId == null ? null : 'course_id = ?',
      whereArgs: courseId == null ? null : [courseId],
      orderBy: 'title COLLATE NOCASE',
    );
    return rows.map(Book.fromMap).toList();
  }

  Future<int> insert(Book b) => _db.db.insert('books', b.toMap()..remove('id'));
  Future<void> update(Book b) =>
      _db.db.update('books', b.toMap(), where: 'id = ?', whereArgs: [b.id]);
  Future<void> delete(int id) =>
      _db.db.delete('books', where: 'id = ?', whereArgs: [id]);

  Future<Book?> byId(int id) async {
    final rows = await _db.db.query('books', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Book.fromMap(rows.first);
  }

  /// Salva la posizione di lettura senza toccare gli altri campi.
  Future<void> saveReadingPosition(
    int id, {
    required int page,
    int? pageCount,
    DateTime? at,
  }) => _db.db.update(
    'books',
    {
      'last_page': page,
      'page_count': ?pageCount,
      'last_opened_at': (at ?? DateTime.now()).toIso8601String(),
    },
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<List<StudyMaterial>> materials({int? courseId}) async {
    final rows = await _db.db.query(
      'materials',
      where: courseId == null ? null : 'course_id = ?',
      whereArgs: courseId == null ? null : [courseId],
      orderBy: 'kind, academic_year DESC, title COLLATE NOCASE',
    );
    return rows.map(StudyMaterial.fromMap).toList();
  }

  Future<int> insertMaterial(StudyMaterial m) =>
      _db.db.insert('materials', m.toMap()..remove('id'));
  Future<void> updateMaterial(StudyMaterial m) =>
      _db.db.update('materials', m.toMap(), where: 'id = ?', whereArgs: [m.id]);

  Future<void> saveMaterialPosition(
    int id, {
    required int page,
    int? pageCount,
  }) => _db.db.update(
    'materials',
    {'last_page': page, 'page_count': ?pageCount},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> deleteMaterial(int id) =>
      _db.db.delete('materials', where: 'id = ?', whereArgs: [id]);
}
