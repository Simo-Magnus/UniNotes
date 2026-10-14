import '../../../core/database/app_database.dart';
import '../../../utils/exclusion_filter.dart';
import '../../../utils/parse.dart';

/// Elemento trovato dal filtro esclusioni.
class ExcludedItem {
  const ExcludedItem(this.id, this.label);
  final int id;
  final String label;
}

/// Elementi già presenti nel database che corrispondono alle esclusioni.
class ExclusionMatches {
  const ExclusionMatches({required this.courses, required this.events, required this.exams});

  final List<ExcludedItem> courses;

  /// Eventi con titolo escluso o appartenenti a un corso escluso.
  final List<ExcludedItem> events;

  /// Esami/prove con titolo escluso o di un corso escluso.
  final List<ExcludedItem> exams;

  bool get isEmpty => courses.isEmpty && events.isEmpty && exams.isEmpty;
  int get total => courses.length + events.length + exams.length;

  /// Titoli degli eventi raggruppati (es. "Inglese B2 ×24").
  Map<String, int> get eventTitleCounts {
    final m = <String, int>{};
    for (final e in events) {
      m[e.label] = (m[e.label] ?? 0) + 1;
    }
    return m;
  }
}

/// "Applica ai dati esistenti": rimuove corsi, eventi ed esami già importati
/// che corrispondono ai pattern di esclusione.
class ExclusionCleanup {
  ExclusionCleanup(this._db);
  final AppDatabase _db;

  Future<ExclusionMatches> find(List<String> patterns) async {
    final filter = ExclusionFilter(patterns);
    final db = _db.db;

    final courseIds = <int>{};
    final courses = <ExcludedItem>[];
    for (final r in await db.query('courses', columns: ['id', 'name'], orderBy: 'name')) {
      final name = r['name'] as String;
      if (filter.isExcluded([name])) {
        final id = asInt(r['id'])!;
        courseIds.add(id);
        courses.add(ExcludedItem(id, name));
      }
    }

    final events = <ExcludedItem>[];
    for (final r in await db.query(
      'events',
      columns: ['id', 'title', 'course_id'],
      orderBy: 'title, start_at',
    )) {
      final title = r['title'] as String;
      if (filter.isExcluded([title]) || courseIds.contains(asInt(r['course_id']))) {
        events.add(ExcludedItem(asInt(r['id'])!, title));
      }
    }

    final exams = <ExcludedItem>[];
    for (final r in await db.rawQuery(
      'SELECT x.id, x.title, x.course_id, c.name AS course_name FROM exams x '
      'LEFT JOIN courses c ON c.id = x.course_id ORDER BY c.name, x.date',
    )) {
      final title = asString(r['title']);
      final course = asString(r['course_name']);
      if (filter.isExcluded([title]) || courseIds.contains(asInt(r['course_id']))) {
        final label = [?title, if (course != null && course != title) '($course)'].join(' ');
        exams.add(ExcludedItem(asInt(r['id'])!, label.isEmpty ? 'Esame senza titolo' : label));
      }
    }
    return ExclusionMatches(courses: courses, events: events, exams: exams);
  }

  /// Cancella gli elementi in un'unica transazione. I moduli, gli argomenti
  /// e i materiali dei corsi rimossi vengono eliminati a cascata.
  Future<int> apply(ExclusionMatches m) async {
    var n = 0;
    await _db.db.transaction((txn) async {
      for (final e in m.events) {
        n += await txn.delete('events', where: 'id = ?', whereArgs: [e.id]);
      }
      for (final x in m.exams) {
        n += await txn.delete('exams', where: 'id = ?', whereArgs: [x.id]);
      }
      for (final c in m.courses) {
        n += await txn.delete('courses', where: 'id = ?', whereArgs: [c.id]);
      }
    });
    return n;
  }
}
