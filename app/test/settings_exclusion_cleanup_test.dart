import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/features/settings/logic/exclusion_cleanup.dart';
import 'package:university_notes/repositories/settings_repository.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    final d = db.db;
    final analisi = await d.insert('courses', {'name': 'Analisi I'});
    final ofa = await d.insert('courses', {'name': 'OFA Matematica'});
    final m = await d.insert('modules', {'course_id': ofa, 'name': 'Recupero'});
    await d.insert('topics', {'module_id': m, 'name': 'Frazioni'});
    for (var i = 0; i < 3; i++) {
      await d.insert('events', {
        'course_id': ofa,
        'type': 'lecture',
        'title': 'Recupero OFA',
        'start_at': '2026-10-0${i + 1}T10:00:00',
      });
    }
    await d.insert('events', {
      'type': 'lecture',
      'title': 'Lingua inglese B2',
      'start_at': '2026-10-06T10:00:00',
    });
    await d.insert('events', {
      'course_id': analisi,
      'type': 'lecture',
      'title': 'Analisi I',
      'start_at': '2026-10-06T08:30:00',
    });
    await d.insert('exams', {'course_id': ofa, 'title': 'Test OFA'});
    await d.insert('exams', {
      'course_id': analisi,
      'title': 'Prova di inglese tecnico',
    });
    await d.insert('exams', {'course_id': analisi, 'title': 'Appello'});
  });
  tearDown(() => db.close());

  test('trova corsi, eventi ed esami esclusi', () async {
    final m = await ExclusionCleanup(db).find(kAllPresetPatterns);
    expect(m.courses.map((c) => c.label), ['OFA Matematica']);
    expect(m.eventTitleCounts, {'Lingua inglese B2': 1, 'Recupero OFA': 3});
    expect(m.exams.length, 2);
    expect(m.total, 7);
  });

  test('applica la pulizia in una transazione e lascia il resto', () async {
    final cleanup = ExclusionCleanup(db);
    await cleanup.apply(await cleanup.find(kAllPresetPatterns));
    expect((await db.db.query('courses')).map((c) => c['name']), ['Analisi I']);
    expect((await db.db.query('events')).map((e) => e['title']), ['Analisi I']);
    expect((await db.db.query('exams')).map((e) => e['title']), ['Appello']);
    expect(await db.db.query('modules'), isEmpty);
    expect(await db.db.query('topics'), isEmpty);
    expect((await cleanup.find(kAllPresetPatterns)).isEmpty, isTrue);
  });

  test('nessun filtro: nessuna corrispondenza', () async {
    final m = await ExclusionCleanup(db).find(const []);
    expect(m.isEmpty, isTrue);
  });
}
