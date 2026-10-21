import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../utils/exclusion_filter.dart';
import '../../utils/parse.dart';
import '../constants/enums.dart';
import '../database/app_database.dart';
import '../theme/university_colors.dart';

class DataPackException implements Exception {
  DataPackException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ImportReport {
  int courses = 0;
  int events = 0;
  int eventsRemoved = 0;
  int exams = 0;
  int books = 0;
  int materials = 0;
  int places = 0;
  int benefits = 0;
  int modules = 0;
  int excluded = 0;
  final List<String> excludedTitles = [];

  String summary() =>
      'Corsi: $courses · Eventi: $events'
      '${eventsRemoved > 0 ? ' (rimossi $eventsRemoved)' : ''} · '
      'Esami/prove: $exams · Libri: $books · Materiali: $materials'
      // luoghi e vantaggi non sono più nell'app: solo se un vecchio data
      // pack ne porta ancora
      '${places > 0 ? ' · Luoghi: $places' : ''}'
      '${benefits > 0 ? ' · Vantaggi: $benefits' : ''}'
      '${modules > 0 ? ' · Moduli di studio: $modules' : ''} · '
      'Esclusi: $excluded';
}

/// Importa un data pack (vedi docs/datapack_format.md) in un'unica
/// transazione. I campi personali già presenti non vengono sovrascritti.
class DataPackImporter {
  DataPackImporter(this._db);
  final AppDatabase _db;

  static const supportedVersion = 1;

  static const _retiredSourcesKey = 'retired_event_sources';

  Future<ImportReport> importJson(
    String json, {
    required List<String> exclusionPatterns,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      throw DataPackException('File non valido (JSON): ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw DataPackException('File non valido: atteso un oggetto JSON.');
    }
    return importMap(decoded, exclusionPatterns: exclusionPatterns);
  }

  /// Insegnamenti per cui lo studente ha scelto la versione in inglese.
  final Set<String> _englishCourses = {};

  Future<ImportReport> importMap(
    Map<String, Object?> pack, {
    required List<String> exclusionPatterns,
  }) async {
    _englishCourses.clear();
    if (pack['format'] != 'university-manager-datapack') {
      throw DataPackException('Il file non è un data pack di UniNotes.');
    }
    final version = asInt(pack['version']) ?? 0;
    if (version < 1 || version > supportedVersion) {
      throw DataPackException('Versione data pack $version non supportata.');
    }
    final filter = ExclusionFilter(exclusionPatterns);
    final report = ImportReport();
    final packSource = asString(pack['source']);

    await _db.db.transaction((txn) async {
      await _universities(txn, _list(pack['universities']));
      await _degrees(txn, _list(pack['degrees']));
      final courseIds = await _courses(
        txn,
        _list(pack['courses']),
        filter,
        report,
      );
      await _events(
        txn,
        _list(pack['events']),
        courseIds,
        filter,
        report,
        packSource,
        replace: asBool(pack['replaceEventsOfSameSource']) ?? false,
        removeSources: [
          for (final v in (pack['removeEventsOfSources'] as List? ?? const []))
            if (asString(v) != null) asString(v)!,
        ],
      );
      await _exams(txn, _list(pack['exams']), courseIds, filter, report);
      await _books(txn, _list(pack['books']), courseIds, filter, report);
      // Libri non più necessari (es. sostituiti da un'altra edizione): si
      // tolgono solo se l'utente non li ha segnati come posseduti.
      for (final v in (pack['removeBooks'] as List? ?? const [])) {
        final ext = asString(v);
        if (ext == null) continue;
        await txn.delete(
          'books',
          where:
              "external_id = ? AND ownership_status = 'wanted' "
              'AND stored_file IS NULL',
          whereArgs: [ext],
        );
      }
      await _materials(txn, _list(pack['materials']), courseIds, report);
      await _studyModules(txn, _list(pack['studyModules']), courseIds, report);
      await _categories(txn, _list(pack['placeCategories']));
      await _places(txn, _list(pack['places']), report);
      await _benefits(txn, _list(pack['benefits']), report);
      final now = isoLocal(DateTime.now());
      await txn.insert('app_settings', {
        'key': 'last_data_update',
        'value': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('app_settings', {
        'key': 'last_data_source',
        'value': packSource,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return report;
  }

  static List<Map<String, Object?>> _list(Object? v) =>
      v is List ? v.whereType<Map<String, Object?>>().toList() : const [];

  Future<int?> _idByExternal(
    Transaction txn,
    String table,
    String externalId,
  ) async {
    final rows = await txn.query(
      table,
      columns: ['id'],
      where: 'external_id = ?',
      whereArgs: [externalId],
      limit: 1,
    );
    return rows.isEmpty ? null : asInt(rows.first['id']);
  }

  Future<void> _universities(
    Transaction txn,
    List<Map<String, Object?>> items,
  ) async {
    for (final u in items) {
      final id = asString(u['id']);
      final name = asString(u['name']);
      if (id == null || name == null) continue;
      final data = {
        'name': name,
        'short_name': asString(u['shortName']) ?? name,
        'website': asString(u['website']),
        'source': asString(u['source']),
        'updated_at': asString(u['updatedAt']),
      };
      final exists = (await txn.query(
        'universities',
        where: 'id = ?',
        whereArgs: [id],
      )).isNotEmpty;
      if (exists) {
        // Il colore resta quello scelto dall'utente.
        await txn.update(
          'universities',
          data,
          where: 'id = ?',
          whereArgs: [id],
        );
      } else {
        await txn.insert('universities', {
          'id': id,
          ...data,
          'color':
              parseColor(u['color']) ?? UniversityColors.forId(id).toARGB32(),
        });
      }
    }
  }

  Future<void> _degrees(
    Transaction txn,
    List<Map<String, Object?>> items,
  ) async {
    for (final d in items) {
      final id = asString(d['id']);
      final name = asString(d['name']);
      final uni = asString(d['universityId']);
      if (id == null || name == null || uni == null) continue;
      await txn.insert('degrees', {
        'id': id,
        'university_id': uni,
        'name': name,
        'class_code': asString(d['classCode']),
        'min_entry_score': asString(d['minEntryScore']),
        'max_graduation_score': asString(d['maxGraduationScore']),
        'reference_averages': asString(d['referenceAverages']),
        'notes': asString(d['notes']),
        'source': asString(d['source']),
        'updated_at': asString(d['updatedAt']),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Ritorna externalId -> id locale per i corsi importati o già presenti.
  Future<Map<String, int>> _courses(
    Transaction txn,
    List<Map<String, Object?>> items,
    ExclusionFilter filter,
    ImportReport report,
  ) async {
    final ids = <String, int>{};
    for (final r in await txn.query(
      'courses',
      columns: ['id', 'external_id'],
    )) {
      final ext = asString(r['external_id']);
      if (ext != null) ids[ext] = asInt(r['id'])!;
    }
    for (final c in items) {
      final ext = asString(c['externalId']);
      final name = asString(c['name']);
      if (ext == null || name == null) continue;
      if (filter.isExcluded([name])) {
        report.excluded++;
        report.excludedTitles.add(name);
        ids.remove(ext);
        continue;
      }
      final data = <String, Object?>{
        'university_id': asString(c['universityId']),
        'degree_id': asString(c['degreeId']),
        'name': name,
        'code': asString(c['code']),
        'teacher': asString(c['teacher']),
        'year': asInt(c['year']),
        'semester': asString(c['semester']),
        'cfu': asDouble(c['cfu']),
        'description': asString(c['description']),
        'lecture_hours': asDouble(c['lectureHours']),
        'difficulty': asDouble(c['difficulty']),
        'study_hours_estimate': asDouble(c['studyHoursEstimate']),
        'exam_mode': asString(c['examMode']),
        'exam_structure': asString(c['examStructure']),
        'optional_oral_info': asString(c['optionalOralInfo']),
        'materials_found': c['materialsFound'] == null
            ? null
            : (asBool(c['materialsFound'])! ? 1 : 0),
        'materials_note': asString(c['materialsNote']),
        'source': asString(c['source']),
        'updated_at': asString(c['updatedAt']),
        // Dati del catalogo pubblico (database/corsi/<ateneo>.json).
        'books_status': asString(c['booksStatus']),
        'exams_status': asString(c['examsStatus']),
        'syllabus_url': asString(c['syllabusUrl']),
        'ssd': asString(c['ssd']),
        'mandatory': c['mandatory'] == null
            ? null
            : (asBool(c['mandatory'])! ? 1 : 0),
        'curriculum': asString(c['curriculum']),
      };
      final existing = await _idByExternal(txn, 'courses', ext);
      if (existing != null) {
        // status e color sono personali: non vengono toccati. I campi null nel
        // pack non cancellano valori già presenti (es. dati del seed).
        data.removeWhere((_, v) => v == null);
        final row = (await txn.query(
          'courses',
          columns: ['user_edited', 'exam_language'],
          where: 'id = ?',
          whereArgs: [existing],
        )).first;
        final english = asString(row['exam_language']) == 'en';
        if (english) _englishCourses.add(ext);
        if (english || (asInt(row['user_edited']) ?? 0) == 1) {
          // scelte dello studente (modifiche a mano o versione in inglese)
          for (final k in const [
            'name',
            'code',
            'teacher',
            'year',
            'semester',
            'cfu',
            'exam_mode',
            'syllabus_url',
          ]) {
            data.remove(k);
          }
        }
        await txn.update(
          'courses',
          data,
          where: 'id = ?',
          whereArgs: [existing],
        );
        ids[ext] = existing;
      } else {
        ids[ext] = await txn.insert('courses', {
          ...data,
          'external_id': ext,
          'status': 'active',
        });
      }
      report.courses++;
    }
    return ids;
  }

  Future<void> _events(
    Transaction txn,
    List<Map<String, Object?>> items,
    Map<String, int> courseIds,
    ExclusionFilter filter,
    ImportReport report,
    String? packSource, {
    required bool replace,
    List<String> removeSources = const [],
  }) async {
    final seen = <String>{};
    // Fonti già sostituite in passato (es. orario da PDF dopo l'orario
    // ufficiale): i loro eventi non vengono più reimportati dal seed.
    final retiredRows = await txn.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [_retiredSourcesKey],
    );
    final retired = <String>{
      if (retiredRows.isNotEmpty && retiredRows.first['value'] != null)
        ...(jsonDecode(retiredRows.first['value'] as String) as List).map(
          (e) => e.toString(),
        ),
    };
    for (final e in items) {
      final ext = asString(e['externalId']);
      final title = asString(e['title']);
      final start = asDateTime(e['start']);
      if (ext == null || title == null || start == null) continue;
      final courseExt = asString(e['courseExternalId']);
      final courseId = courseExt == null ? null : courseIds[courseExt];
      if (filter.isExcluded([title]) ||
          (courseExt != null && courseId == null)) {
        report.excluded++;
        report.excludedTitles.add(title);
        continue;
      }
      final eventSource = asString(e['source']) ?? packSource;
      if (retired.contains(eventSource) &&
          !removeSources.contains(eventSource)) {
        continue;
      }
      final end = asDateTime(e['end']);
      final data = <String, Object?>{
        'course_id': courseId,
        'university_id': asString(e['universityId']),
        'type': asString(e['type']) ?? 'event',
        'title': title,
        'start_at': isoLocal(start),
        'end_at': end == null ? null : isoLocal(end),
        'all_day': (asBool(e['allDay']) ?? false) ? 1 : 0,
        'room': asString(e['room']),
        'building': asString(e['building']),
        'site': asString(e['site']),
        'teacher': asString(e['teacher']),
        'source': asString(e['source']) ?? packSource,
      };
      final existing = await txn.query(
        'events',
        columns: ['id', 'notes'],
        where: 'external_id = ?',
        whereArgs: [ext],
      );
      if (existing.isNotEmpty) {
        if (existing.first['notes'] == null) {
          data['notes'] = asString(e['notes']);
        }
        await txn.update(
          'events',
          data,
          where: 'external_id = ?',
          whereArgs: [ext],
        );
      } else {
        await txn.insert('events', {
          ...data,
          'external_id': ext,
          'notes': asString(e['notes']),
        });
      }
      seen.add(ext);
      report.events++;
    }
    // Fonti da "pulire": la propria (se replace) più quelle sostituite da
    // dati migliori (es. orario ricostruito dai PDF, rimpiazzato dall'orario
    // ufficiale).
    final sources = {
      if (replace && packSource != null) packSource,
      ...removeSources,
    };
    if (removeSources.isNotEmpty) {
      await txn.insert('app_settings', {
        'key': _retiredSourcesKey,
        'value': jsonEncode(({...retired, ...removeSources}.toList()..sort())),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    for (final source in sources) {
      final stale = await txn.query(
        'events',
        columns: ['external_id'],
        where: 'source = ? AND external_id IS NOT NULL',
        whereArgs: [source],
      );
      for (final r in stale) {
        final ext = r['external_id'] as String;
        if (!seen.contains(ext)) {
          await txn.delete(
            'events',
            where: 'external_id = ?',
            whereArgs: [ext],
          );
          report.eventsRemoved++;
        }
      }
    }
  }

  /// Stato di una prova nuova del database dei corsi: «Da prenotare», ma
  /// «Da completare» per gli insegnamenti degli anni prima dell'anno di
  /// partenza del profilo (`profile.start_year`): lo studente è arrivato
  /// nell'app dopo, non sono arretrati finché non lo dice lui.
  Future<String> _newExamStatus(
    Transaction txn,
    int courseId,
    int? start,
  ) async {
    if (start == null || start <= 1) return ExamStatus.planned.key;
    final rows = await txn.query(
      'courses',
      columns: ['year'],
      where: 'id = ?',
      whereArgs: [courseId],
    );
    final year = rows.isEmpty ? null : asInt(rows.first['year']);
    return year != null && year < start
        ? ExamStatus.toComplete.key
        : ExamStatus.planned.key;
  }

  Future<int?> _startYear(Transaction txn) async {
    try {
      final rows = await txn.query(
        'profile',
        columns: ['start_year'],
        where: 'id = 1',
      );
      return rows.isEmpty ? null : asInt(rows.first['start_year']);
    } catch (_) {
      return null;
    }
  }

  Future<void> _exams(
    Transaction txn,
    List<Map<String, Object?>> items,
    Map<String, int> courseIds,
    ExclusionFilter filter,
    ImportReport report,
  ) async {
    final start = await _startYear(txn);
    for (final x in items) {
      final ext = asString(x['externalId']);
      final courseExt = asString(x['courseExternalId']);
      final courseId = courseExt == null ? null : courseIds[courseExt];
      if (ext == null) continue;
      final title = asString(x['title']);
      if (courseId == null || filter.isExcluded([title])) {
        report.excluded++;
        if (title != null) report.excludedTitles.add(title);
        continue;
      }
      final materials = x['studyMaterials'];
      final newTopics = asString(x['topics']);
      final newMaterials = materials is List && materials.isNotEmpty
          ? jsonEncode(materials.map((e) => e.toString()).toList())
          : null;
      final date = asDateTime(x['date']);
      final data = <String, Object?>{
        'course_id': courseId,
        'kind': asString(x['kind']) == 'midterm' ? 'midterm' : 'final',
        'title': title,
        'date': date == null ? null : isoDate(date),
        'time': asString(x['time']),
        'location': asString(x['location']),
        'exam_type': asString(x['examType']),
        'cfu': asDouble(x['cfu']),
        'source': asString(x['source']),
      };
      final existing = await txn.query(
        'exams',
        columns: [
          'id',
          'notes',
          'imported_notes',
          'topics',
          'imported_topics',
          'study_materials',
          'imported_study_materials',
        ],
        where: 'external_id = ?',
        whereArgs: [ext],
      );
      final newNotes = asString(x['notes']);
      data['imported_notes'] = newNotes;
      // Argomenti e materiali: il valore importato resta accanto al campo
      // (imported_*), così si riconosce se lo studente l'ha cambiato. Solo i
      // pack che li indicano (anche vuoti) li toccano.
      final hasTopics = x.containsKey('topics');
      final hasMaterials = x.containsKey('studyMaterials');
      if (existing.isEmpty) {
        if (hasTopics) {
          data['topics'] = newTopics;
          data['imported_topics'] = newTopics;
        }
        if (hasMaterials) {
          data['study_materials'] = newMaterials;
          data['imported_study_materials'] = newMaterials;
        }
      }
      if (existing.isNotEmpty) {
        // status, grade, laude restano quelli dell'utente; le note si
        // aggiornano solo se l'utente non le ha modificate. Un campo
        // sconosciuto nel pack (null) non cancella quello già presente (es.
        // data scelta dallo studente, CFU corretti a mano).
        final row = existing.first;
        final cur = row['notes'];
        if (cur == null || cur == row['imported_notes']) {
          data['notes'] = newNotes;
        }
        // Argomenti e materiali si aggiornano solo se il campo è ancora
        // quello messo dall'import (o vuoto e mai riempito): se lo studente
        // li ha scritti, cambiati o svuotati restano i suoi.
        final keep = {'notes', 'imported_notes'};
        if (hasTopics) {
          if (row['topics'] == row['imported_topics']) {
            data['topics'] = newTopics;
            keep.add('topics');
          }
          data['imported_topics'] = newTopics;
          keep.add('imported_topics');
        }
        if (hasMaterials) {
          if (row['study_materials'] == row['imported_study_materials']) {
            data['study_materials'] = newMaterials;
            keep.add('study_materials');
          }
          data['imported_study_materials'] = newMaterials;
          keep.add('imported_study_materials');
        }
        data.removeWhere((k, v) => v == null && !keep.contains(k));
        await txn.update(
          'exams',
          data,
          where: 'external_id = ?',
          whereArgs: [ext],
        );
      } else {
        await txn.insert('exams', {
          ...data,
          'external_id': ext,
          'status': await _newExamStatus(txn, courseId, start),
          'notes': asString(x['notes']),
        });
      }
      report.exams++;
    }
  }

  Future<void> _books(
    Transaction txn,
    List<Map<String, Object?>> items,
    Map<String, int> courseIds,
    ExclusionFilter filter,
    ImportReport report,
  ) async {
    for (final b in items) {
      final ext = asString(b['externalId']);
      final title = asString(b['title']);
      if (ext == null || title == null) continue;
      final courseExt = asString(b['courseExternalId']);
      final courseId = courseExt == null ? null : courseIds[courseExt];
      if (courseExt != null && courseId == null) {
        report.excluded++;
        continue;
      }
      // versione in inglese scelta: i libri della versione italiana no
      if (_englishCourses.contains(courseExt) &&
          await _idByExternal(txn, 'books', ext) == null) {
        continue;
      }
      final filePath = asString(b['filePath']);
      final downloaded = asBool(b['downloaded']) ?? (filePath != null);
      final data = <String, Object?>{
        'course_id': courseId,
        'title': title,
        'author': asString(b['author']),
        'isbn': asString(b['isbn']),
        'edition': asString(b['edition']),
        'publisher': asString(b['publisher']),
        'year': asInt(b['year']),
        'expected_file_name': asString(b['expectedFileName']),
        'language': asString(b['language']),
        'required': b['required'] == null
            ? null
            : (asBool(b['required'])! ? 1 : 0),
      };
      if (filePath != null) data['file_path'] = filePath;
      final existingRows = await txn.query(
        'books',
        columns: ['id', 'user_edited'],
        where: 'external_id = ?',
        whereArgs: [ext],
        limit: 1,
      );
      final existing = existingRows.isEmpty
          ? null
          : asInt(existingRows.first['id']);
      if (existing != null) {
        // catalog_choice (Tieni/Rimuovi) non viene mai toccata: un libro
        // rimosso dallo studente resta nascosto. I dati modificati a mano
        // (user_edited) non vengono sovrascritti.
        if (asInt(existingRows.first['user_edited']) != 1) {
          await txn.update(
            'books',
            data,
            where: 'id = ?',
            whereArgs: [existing],
          );
        }
        // Libro segnato come posseduto dal data pack: «da procurare» diventa
        // «posseduto» (le altre scelte dell'utente non si toccano).
        if (asBool(b['downloaded']) == true) {
          await txn.update(
            'books',
            {'ownership_status': 'owned'},
            where: "id = ? AND ownership_status = 'wanted'",
            whereArgs: [existing],
          );
        }
      } else {
        final fmt = asString(b['format']);
        await txn.insert('books', {
          ...data,
          'external_id': ext,
          'format': fmt == null
              ? (filePath != null ? 'pdf' : 'other')
              : _bookFormat(fmt),
          'ownership_status': downloaded ? 'owned' : 'wanted',
        });
      }
      report.books++;
    }
  }

  static String _bookFormat(String f) => switch (f.toLowerCase()) {
    'cartaceo' || 'paper' => 'paper',
    'ebook' || 'epub' => 'ebook',
    'pdf' => 'pdf',
    _ => 'other',
  };

  Future<void> _materials(
    Transaction txn,
    List<Map<String, Object?>> items,
    Map<String, int> courseIds,
    ImportReport report,
  ) async {
    for (final m in items) {
      final ext = asString(m['externalId']);
      final title = asString(m['title']);
      if (ext == null || title == null) continue;
      final courseExt = asString(m['courseExternalId']);
      final courseId = courseExt == null ? null : courseIds[courseExt];
      if (courseExt != null && courseId == null) continue;
      final data = <String, Object?>{
        'course_id': courseId,
        'title': title,
        'local_path': asString(m['localPath']),
        'kind': asString(m['kind']) ?? 'other',
        'academic_year': asString(m['academicYear']),
        'author': asString(m['author']),
        'source': asString(m['source']),
      };
      // Aggiornamento in place: copia nell'app e pagina letta restano.
      final updated = await txn.update(
        'materials',
        data,
        where: 'external_id = ?',
        whereArgs: [ext],
      );
      if (updated == 0) {
        await txn.insert('materials', {...data, 'external_id': ext});
      }
      report.materials++;
    }
  }

  /// Struttura di Studio già pronta (moduli dai capitoli dei libri e dagli
  /// argomenti delle slide): si importa solo nei corsi che non hanno ancora
  /// moduli, così non tocca mai quella creata o modificata dallo studente.
  Future<void> _studyModules(
    Transaction txn,
    List<Map<String, Object?>> items,
    Map<String, int> courseIds,
    ImportReport report,
  ) async {
    final byCourse = <String, List<Map<String, Object?>>>{};
    for (final m in items) {
      final c = asString(m['courseExternalId']);
      if (c == null || asString(m['name']) == null) continue;
      byCourse.putIfAbsent(c, () => []).add(m);
    }
    for (final e in byCourse.entries) {
      final courseId =
          courseIds[e.key] ?? await _idByExternal(txn, 'courses', e.key);
      if (courseId == null) continue;
      final existing = Sqflite.firstIntValue(
        await txn.rawQuery('SELECT COUNT(*) FROM modules WHERE course_id = ?', [
          courseId,
        ]),
      );
      if ((existing ?? 0) > 0) continue;
      final list = [...e.value]
        ..sort(
          (a, b) => (asInt(a['sort']) ?? 0).compareTo(asInt(b['sort']) ?? 0),
        );
      for (final (i, m) in list.indexed) {
        final moduleId = await txn.insert('modules', {
          'course_id': courseId,
          'name': asString(m['name']),
          'sort': i,
        });
        final topics = m['topics'] is List ? m['topics'] as List : const [];
        for (final (j, t) in topics.indexed) {
          final name = t is Map ? asString(t['name']) : asString(t);
          if (name == null) continue;
          await txn.insert('topics', {
            'module_id': moduleId,
            'name': name,
            'notes': t is Map ? asString(t['notes']) : null,
            'sort': j,
          });
        }
        report.modules++;
      }
    }
  }

  Future<void> _categories(
    Transaction txn,
    List<Map<String, Object?>> items,
  ) async {
    for (final c in items) {
      final id = asString(c['id']);
      final name = asString(c['name']);
      if (id == null || name == null) continue;
      await txn.insert('place_categories', {
        'id': id,
        'name': name,
        'icon': asString(c['icon']),
        'sort': asInt(c['sort']) ?? 50,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> _places(
    Transaction txn,
    List<Map<String, Object?>> items,
    ImportReport report,
  ) async {
    for (final p in items) {
      final ext = asString(p['externalId']);
      final name = asString(p['name']);
      final lat = asDouble(p['lat']);
      final lon = asDouble(p['lon']);
      if (ext == null || name == null || lat == null || lon == null) continue;
      final data = {
        'category_id': asString(p['categoryId']) ?? 'other',
        'name': name,
        'lat': lat,
        'lon': lon,
        'address': asString(p['address']),
        'city': asString(p['city']),
        'description': asString(p['description']),
        'phone': asString(p['phone']),
        'website': asString(p['website']),
        'opening_hours': asString(p['openingHours']),
        'source': asString(p['source']),
        'updated_at': asString(p['updatedAt']),
      };
      final updated = await txn.update(
        'places',
        data,
        where: 'external_id = ?',
        whereArgs: [ext],
      );
      if (updated == 0) {
        await txn.insert('places', {...data, 'external_id': ext});
      }
      report.places++;
    }
  }

  Future<void> _benefits(
    Transaction txn,
    List<Map<String, Object?>> items,
    ImportReport report,
  ) async {
    for (final b in items) {
      final ext = asString(b['externalId']);
      final title = asString(b['title']);
      if (ext == null || title == null) continue;
      final data = {
        'university_id': asString(b['universityId']),
        'category': asString(b['category']) ?? 'service',
        'title': title,
        'description': asString(b['description']),
        'url': asString(b['url']),
        'source': asString(b['source']),
        'updated_at': asString(b['updatedAt']),
      };
      final updated = await txn.update(
        'benefits',
        data,
        where: 'external_id = ?',
        whereArgs: [ext],
      );
      if (updated == 0) {
        await txn.insert('benefits', {...data, 'external_id': ext});
      }
      report.benefits++;
    }
  }
}
