import '../core/database/app_database.dart';
import '../models/attachment.dart';
import '../models/study.dart';
import '../utils/parse.dart';

class StudyRepository {
  StudyRepository(this._db);
  final AppDatabase _db;

  // Moduli
  Future<List<StudyModule>> modules(int courseId) async {
    final rows = await _db.db.query(
      'modules',
      where: 'course_id = ?',
      whereArgs: [courseId],
      orderBy: 'sort, id',
    );
    return rows.map(StudyModule.fromMap).toList();
  }

  Future<int> insertModule(StudyModule m) =>
      _db.db.insert('modules', m.toMap()..remove('id'));
  Future<void> updateModule(StudyModule m) =>
      _db.db.update('modules', m.toMap(), where: 'id = ?', whereArgs: [m.id]);
  Future<void> deleteModule(int id) =>
      _db.db.delete('modules', where: 'id = ?', whereArgs: [id]);

  // Argomenti
  Future<List<Topic>> topics(int moduleId) async {
    final rows = await _db.db.query(
      'topics',
      where: 'module_id = ?',
      whereArgs: [moduleId],
      orderBy: 'sort, id',
    );
    return rows.map(Topic.fromMap).toList();
  }

  Future<List<Topic>> topicsOfCourse(int courseId) async {
    final rows = await _db.db.rawQuery(
      'SELECT t.* FROM topics t JOIN modules m ON m.id = t.module_id '
      'WHERE m.course_id = ? ORDER BY m.sort, m.id, t.sort, t.id',
      [courseId],
    );
    return rows.map(Topic.fromMap).toList();
  }

  Future<int> insertTopic(Topic t) =>
      _db.db.insert('topics', t.toMap()..remove('id'));
  Future<void> updateTopic(Topic t) =>
      _db.db.update('topics', t.toMap(), where: 'id = ?', whereArgs: [t.id]);
  Future<void> deleteTopic(int id) =>
      _db.db.delete('topics', where: 'id = ?', whereArgs: [id]);

  // Allegati di moduli e argomenti
  static const _attachmentsOfCourse =
      'SELECT a.* FROM attachments a '
      'LEFT JOIN topics t ON t.id = a.topic_id '
      'JOIN modules m ON m.id = COALESCE(a.module_id, t.module_id) '
      'WHERE m.course_id = ? ORDER BY a.created_at, a.id';

  Future<List<Attachment>> attachmentsOfCourse(int courseId) async {
    final rows = await _db.db.rawQuery(_attachmentsOfCourse, [courseId]);
    return rows.map(Attachment.fromMap).toList();
  }

  Future<List<Attachment>> allAttachments() async {
    final rows = await _db.db.query('attachments', orderBy: 'created_at, id');
    return rows.map(Attachment.fromMap).toList();
  }

  Future<int> insertAttachment(Attachment a) =>
      _db.db.insert('attachments', a.toMap()..remove('id'));

  /// Dopo la rinomina di appunti collegati: percorso e titolo aggiornati.
  Future<void> renameAttachmentPaths(
    Map<String, String> moves, {
    required String oldName,
    required String newName,
  }) async {
    for (final m in moves.entries) {
      final rows = await _db.db.query(
        'attachments',
        where: 'path = ?',
        whereArgs: [m.key],
      );
      for (final r in rows) {
        final title = r['title'] as String;
        await _db.db.update(
          'attachments',
          {
            'path': m.value,
            'title': title.endsWith(oldName)
                ? title.substring(0, title.length - oldName.length) + newName
                : title,
          },
          where: 'id = ?',
          whereArgs: [r['id']],
        );
      }
    }
  }

  /// Tipo del file (teoria, esercizi, ripasso).
  Future<void> setAttachmentKinds(int id, Set<AttachmentKind> kinds) =>
      _db.db.update(
        'attachments',
        {'kinds': AttachmentKind.encode(kinds)},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> deleteAttachment(int id) =>
      _db.db.delete('attachments', where: 'id = ?', whereArgs: [id]);

  /// File copiati nell'app dagli allegati di un modulo (e dei suoi
  /// argomenti) o di un argomento: da eliminare insieme a loro.
  Future<List<String>> storedAttachmentFiles({
    int? moduleId,
    int? topicId,
  }) async {
    final rows = await _db.db.rawQuery(
      'SELECT a.stored_file FROM attachments a '
      'LEFT JOIN topics t ON t.id = a.topic_id '
      'WHERE a.stored_file IS NOT NULL AND '
      '(a.topic_id = ? OR a.module_id = ? OR t.module_id = ?)',
      [topicId ?? -1, moduleId ?? -1, moduleId ?? -1],
    );
    return [for (final r in rows) r['stored_file'] as String];
  }

  // Sessioni
  Future<List<StudySession>> sessions({
    DateTime? from,
    DateTime? to,
    int? courseId,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (from != null) {
      where.add('start_at >= ?');
      args.add(isoLocal(from));
    }
    if (to != null) {
      where.add('start_at < ?');
      args.add(isoLocal(to));
    }
    if (courseId != null) {
      where.add('course_id = ?');
      args.add(courseId);
    }
    final rows = await _db.db.query(
      'study_sessions',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'start_at DESC',
    );
    return rows.map(StudySession.fromMap).toList();
  }

  Future<int> insertSession(StudySession s) =>
      _db.db.insert('study_sessions', s.toMap()..remove('id'));
  Future<void> updateSession(StudySession s) => _db.db.update(
    'study_sessions',
    s.toMap(),
    where: 'id = ?',
    whereArgs: [s.id],
  );
  Future<void> deleteSession(int id) =>
      _db.db.delete('study_sessions', where: 'id = ?', whereArgs: [id]);

  // Aggiunte per la feature Studio.

  /// Tutti gli argomenti (per risolvere i nomi nelle sessioni/statistiche).
  Future<List<Topic>> allTopics() async {
    final rows = await _db.db.query('topics', orderBy: 'module_id, sort, id');
    return rows.map(Topic.fromMap).toList();
  }

  /// Prossimo valore di `sort` per un nuovo modulo del corso.
  Future<int> nextModuleSort(int courseId) async {
    final r = await _db.db.rawQuery(
      'SELECT COALESCE(MAX(sort), -1) + 1 AS n FROM modules WHERE course_id = ?',
      [courseId],
    );
    return asInt(r.first['n']) ?? 0;
  }

  /// Prossimo valore di `sort` per un nuovo argomento del modulo.
  Future<int> nextTopicSort(int moduleId) async {
    final r = await _db.db.rawQuery(
      'SELECT COALESCE(MAX(sort), -1) + 1 AS n FROM topics WHERE module_id = ?',
      [moduleId],
    );
    return asInt(r.first['n']) ?? 0;
  }

  /// Salva l'ordine dei moduli: `sort` = posizione in [orderedIds].
  Future<void> reorderModules(List<int> orderedIds) =>
      _reorder('modules', orderedIds);

  /// Salva l'ordine degli argomenti: `sort` = posizione in [orderedIds].
  Future<void> reorderTopics(List<int> orderedIds) =>
      _reorder('topics', orderedIds);

  Future<void> _reorder(String table, List<int> ids) async {
    final batch = _db.db.batch();
    for (var i = 0; i < ids.length; i++) {
      batch.update(table, {'sort': i}, where: 'id = ?', whereArgs: [ids[i]]);
    }
    await batch.commit(noResult: true);
  }
}
