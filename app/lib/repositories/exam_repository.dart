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

  /// Esame finale dell'insegnamento [courseId] (quello «principale», vedi
  /// [primaryFinal]), null se non ne ha.
  Future<Exam?> finalOf(int courseId) async {
    final finals = [
      for (final e in await byCourse(courseId))
        if (e.kind == ExamKind.finalExam) e,
    ];
    return primaryFinal(finals);
  }

  /// Un insegnamento ha un solo esame finale con un solo stato. Prima
  /// potevano essercene due: quello creato dal database dei corsi («Da
  /// prenotare») e quello aggiunto a mano con «Nuova prova», così «Da
  /// sostenere» e «Sostenuti» mostravano lo stesso esame con stati diversi.
  /// Qui gli esami finali ancora da sostenere (da prenotare o prenotati, o
  /// «Da completare» degli anni precedenti) di un
  /// insegnamento che ne ha più d'uno confluiscono in quello principale
  /// ([primaryFinal]): i campi vuoti si riempiono (id del database, argomenti,
  /// materiali, data…), poi il doppione si cancella. Restano le prove già
  /// sostenute (in attesa, superate, non superate, annullate) e gli appelli
  /// aggiunti a mano con la loro data: sono tentativi veri. Restituisce quante
  /// prove sono state unite.
  Future<int> mergeDuplicateFinals() async {
    final rows = await _db.db.query(
      'exams',
      where: "kind = 'final'",
      orderBy: 'course_id, id',
    );
    final byCourse = <int, List<Map<String, Object?>>>{};
    for (final r in rows) {
      final c = r['course_id'];
      if (c is int) byCourse.putIfAbsent(c, () => []).add(r);
    }
    var merged = 0;
    for (final group in byCourse.values) {
      if (group.length < 2) continue;
      final exams = group.map(Exam.fromMap).toList();
      final primary = primaryFinal(exams)!;
      final pRow = group.firstWhere((r) => r['id'] == primary.id);
      // valori: quelli dell'esame principale, i vuoti dai doppioni
      final values = {for (final k in _valueFields) k: pRow[k]};
      final joined = <Map<String, Object?>>[pRow];
      for (final r in group) {
        if (r['id'] == primary.id) continue;
        final status = ExamStatus.fromKey(r['status'] as String?);
        if (!status.isPending && !status.isToComplete) continue;
        // un appello prenotato a mano, con la sua data, è un tentativo vero
        // (per esempio per migliorare il voto): resta
        if (r['external_id'] == null && r['date'] != null) continue;
        // due id diversi del database dei corsi: si lasciano com'erano
        if (r['external_id'] != null &&
            values['external_id'] != null &&
            r['external_id'] != values['external_id']) {
          continue;
        }
        for (final k in _mergeFields) {
          final v = r[k];
          if (v == null) continue;
          final cur = values[k];
          if (cur == null || (cur is String && cur.trim().isEmpty)) {
            values[k] = v;
            // l'ora segue la data
            if (k == 'date' && values['time'] == null) {
              values['time'] = r['time'];
            }
          }
        }
        joined.add(r);
      }
      if (joined.length < 2) continue;
      // resta la riga del database dei corsi (id stabile anche per la
      // sincronizzazione tra dispositivi), con i valori uniti
      final keep = joined.firstWhere(
        (r) => r['external_id'] != null,
        orElse: () => pRow,
      );
      final drop = [
        for (final r in joined)
          if (r['id'] != keep['id']) r['id'] as int,
      ];
      await _db.db.transaction((txn) async {
        for (final id in drop) {
          await txn.delete('exams', where: 'id = ?', whereArgs: [id]);
        }
        await txn.update(
          'exams',
          values,
          where: 'id = ?',
          whereArgs: [keep['id']],
        );
      });
      merged += drop.length;
    }
    return merged;
  }

  /// Colonne dei dati di una prova che l'unione dei doppioni scrive (non le
  /// colonne tecniche, come quelle della sincronizzazione).
  static const _valueFields = [
    ..._mergeFields,
    'time',
    'status',
    'grade',
    'laude',
  ];

  /// Campi che il doppione passa all'esame principale se lì sono vuoti.
  static const _mergeFields = [
    'external_id',
    'title',
    'date',
    'location',
    'exam_type',
    'cfu',
    'topics',
    'imported_topics',
    'study_materials',
    'imported_study_materials',
    'notes',
    'imported_notes',
    'source',
  ];

  /// Prove mai toccate dallo studente: create dal database dei corsi, ancora
  /// «Da prenotare», senza voto e con note, argomenti e materiali come li ha
  /// messi l'import (data e luogo possono venire dal database).
  static const _untouched =
      "status = 'planned' AND grade IS NULL AND laude = 0 "
      'AND external_id IS NOT NULL '
      'AND (notes IS NULL OR notes = imported_notes) '
      'AND (topics IS NULL OR topics = imported_topics) '
      'AND (study_materials IS NULL OR '
      'study_materials = imported_study_materials)';

  /// Anno di partenza [below] (vedi `StudentProfile.startYear`): le prove mai
  /// toccate degli insegnamenti degli anni prima (dall'anno [from], se c'è)
  /// del corso di laurea [degreeId] diventano «Da completare»: lo studente
  /// non le ha compilate perché è arrivato nell'app dopo, non sono
  /// arretrati. Restituisce quante.
  Future<int> markToComplete({
    required int below,
    int? from,
    String? degreeId,
  }) async {
    if (below <= 1 || (from != null && from >= below)) return 0;
    return _db.db.rawUpdate(
      "UPDATE exams SET status = 'to_complete' WHERE $_untouched AND "
      'course_id IN (SELECT id FROM courses WHERE year IS NOT NULL AND '
      'year < ?${from == null ? '' : ' AND year >= ?'}'
      '${degreeId == null ? '' : ' AND degree_id = ?'})',
      [below, ?from, ?degreeId],
    );
  }

  /// Le prove «Da completare» dall'anno di partenza [start] in poi (o di
  /// insegnamenti senza anno) tornano «Da prenotare»: lì la compilazione
  /// parte dall'app. Restituisce quante.
  Future<int> restoreFromStartYear(int start, {String? degreeId}) =>
      _db.db.rawUpdate(
        "UPDATE exams SET status = 'planned' WHERE status = 'to_complete' "
        'AND course_id IN (SELECT id FROM courses WHERE (year IS NULL OR '
        'year >= ?)${degreeId == null ? '' : ' AND (degree_id = ? OR '
                  'degree_id IS NULL)'})',
        [start, ?degreeId],
      );

  /// Prove in itinere ed esoneri dell'insegnamento [courseId] con lo stato
  /// [from] passano a [to] (es. l'esame di un anno precedente segnato «Da
  /// sostenere»: anche le sue prove tornano visibili).
  Future<int> moveMidterms(int courseId, ExamStatus from, ExamStatus to) =>
      _db.db.update(
        'exams',
        {'status': to.key},
        where: "course_id = ? AND kind = 'midterm' AND status = ?",
        whereArgs: [courseId, from.key],
      );

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

/// Esame finale «principale» di un insegnamento tra [finals] (tutti dello
/// stesso insegnamento): quello che dice com'è messo l'esame. In ordine:
/// superato, in attesa dell'esito, prenotato, da prenotare con una data o
/// aggiunto a mano (un nuovo tentativo), non superato, da prenotare come
/// l'ha creato il database dei corsi, da completare (anni prima dell'anno
/// di partenza), annullato; a parità quello con la data
/// più recente, poi l'ultimo aggiunto.
Exam? primaryFinal(Iterable<Exam> finals) {
  Exam? best;
  for (final e in finals) {
    if (best == null || _beats(e, best)) best = e;
  }
  return best;
}

int _rank(Exam e) => switch (e.status) {
  ExamStatus.passed => 0,
  ExamStatus.taken => 10,
  ExamStatus.booked => 20,
  ExamStatus.planned when e.date != null || e.externalId == null => 25,
  ExamStatus.failed => 30,
  ExamStatus.planned => 40,
  ExamStatus.toComplete => 45,
  ExamStatus.cancelled => 50,
};

bool _beats(Exam a, Exam b) {
  final r = _rank(a).compareTo(_rank(b));
  if (r != 0) return r < 0;
  final da = a.date, db = b.date;
  if (da != null && db == null) return true;
  if (da == null && db != null) return false;
  if (da != null && db != null && da != db) return da.isAfter(db);
  return (a.id ?? 0) > (b.id ?? 0);
}
