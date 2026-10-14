import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/datapack_importer.dart';
import 'package:university_notes/repositories/settings_repository.dart';

Map<String, Object?> _pack({
  String teacher = 'Prof. A',
  bool replace = false,
  List<Map<String, Object?>>? events,
}) => {
  'format': 'university-manager-datapack',
  'version': 1,
  'generatedAt': '2026-10-01T10:00:00',
  'source': 'test',
  'replaceEventsOfSameSource': replace,
  'universities': [
    {
      'id': 'polito',
      'name': 'Politecnico di Torino',
      'shortName': 'PoliTo',
      'color': '#1565C0',
    },
  ],
  'courses': [
    {
      'externalId': 'polito:course:A',
      'universityId': 'polito',
      'name': 'Analisi I',
      'cfu': 10,
      'teacher': teacher,
    },
    {
      'externalId': 'polito:course:OFA',
      'universityId': 'polito',
      'name': 'OFA Matematica',
      'cfu': 0,
    },
    {
      'externalId': 'polito:course:ENG',
      'universityId': 'polito',
      'name': 'Lingua inglese I',
      'cfu': 3,
    },
  ],
  'events':
      events ??
      [
        {
          'externalId': 'e1',
          'type': 'lecture',
          'courseExternalId': 'polito:course:A',
          'title': 'Analisi I',
          'start': '2026-10-05T08:30:00',
          'end': '2026-10-05T10:00:00',
        },
        {
          'externalId': 'e2',
          'type': 'lecture',
          'courseExternalId': 'polito:course:OFA',
          'title': 'Recupero',
          'start': '2026-10-05T10:00:00',
        },
        {
          'externalId': 'e3',
          'type': 'lecture',
          'title': 'English B2 lesson',
          'start': '2026-10-06T10:00:00',
        },
      ],
  'exams': [
    {
      'externalId': 'x1',
      'courseExternalId': 'polito:course:A',
      'kind': 'midterm',
      'title': 'Prima prova',
      'date': '2026-11-12',
      'studyMaterials': ['Lezioni 1-8'],
    },
  ],
};

void main() {
  late AppDatabase db;
  late DataPackImporter importer;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    importer = DataPackImporter(db);
  });
  tearDown(() => db.close());

  test('importa ed esclude OFA e inglese', () async {
    final r = await importer.importMap(
      _pack(),
      exclusionPatterns: kAllPresetPatterns,
    );
    expect(r.courses, 1);
    expect(r.events, 1);
    expect(r.exams, 1);
    final courses = await db.db.query('courses');
    expect(courses.map((c) => c['name']), ['Analisi I']);
  });

  test('il reimport non sovrascrive i dati personali', () async {
    await importer.importMap(_pack(), exclusionPatterns: kAllPresetPatterns);
    await db.db.update('courses', {'status': 'completed', 'color': 123});
    await db.db.update('exams', {
      'status': 'passed',
      'grade': 28,
      'notes': 'mia nota',
    });
    await importer.importMap(
      _pack(teacher: 'Prof. B'),
      exclusionPatterns: kAllPresetPatterns,
    );
    final c = (await db.db.query('courses')).single;
    expect(c['status'], 'completed');
    expect(c['color'], 123);
    expect(c['teacher'], 'Prof. B');
    final x = (await db.db.query('exams')).single;
    expect(x['status'], 'passed');
    expect(x['grade'], 28);
    expect(x['notes'], 'mia nota');
  });

  group('argomenti e materiali degli esami', () {
    Map<String, Object?> pack({
      Object? topics = 'Limiti',
      Object? materials = const ['Libro A'],
      bool withKeys = true,
    }) => {
      'format': 'university-manager-datapack',
      'version': 1,
      'universities': [
        {
          'id': 'polito',
          'name': 'Politecnico di Torino',
          'shortName': 'P',
          'color': '#1565C0',
        },
      ],
      'courses': [
        {
          'externalId': 'polito:course:A',
          'universityId': 'polito',
          'name': 'Analisi I',
        },
      ],
      'exams': [
        {
          'externalId': 'polito:exam:A',
          'courseExternalId': 'polito:course:A',
          'kind': 'final',
          if (withKeys) 'topics': topics,
          if (withKeys) 'studyMaterials': materials,
        },
      ],
    };

    Future<Map<String, Object?>> exam() async =>
        (await db.db.query('exams')).single;

    test('riempimento e aggiornamento dei campi non toccati', () async {
      await importer.importMap(pack(), exclusionPatterns: const []);
      var x = await exam();
      expect(x['topics'], 'Limiti');
      expect(x['study_materials'], '["Libro A"]');
      expect(x['imported_topics'], 'Limiti');
      expect(x['imported_study_materials'], '["Libro A"]');
      await importer.importMap(
        pack(topics: 'Limiti e derivate', materials: ['Libro A', 'Libro B']),
        exclusionPatterns: const [],
      );
      x = await exam();
      expect(x['topics'], 'Limiti e derivate');
      expect(x['study_materials'], '["Libro A","Libro B"]');
      // il database non ha più i dati: i campi non toccati si svuotano
      await importer.importMap(
        pack(topics: null, materials: const []),
        exclusionPatterns: const [],
      );
      x = await exam();
      expect(x['topics'], isNull);
      expect(x['study_materials'], isNull);
    });

    test('le modifiche dello studente non si sovrascrivono', () async {
      await importer.importMap(pack(), exclusionPatterns: const []);
      await db.db.update('exams', {
        'topics': 'I miei argomenti',
        'study_materials': '["Mie slide"]',
      });
      await importer.importMap(
        pack(topics: 'Nuovo programma', materials: ['Libro B']),
        exclusionPatterns: const [],
      );
      var x = await exam();
      expect(x['topics'], 'I miei argomenti');
      expect(x['study_materials'], '["Mie slide"]');
      expect(x['imported_topics'], 'Nuovo programma');
      // svuotati dallo studente: restano vuoti
      await db.db.update('exams', {'topics': null, 'study_materials': null});
      await importer.importMap(
        pack(topics: 'Altro programma', materials: ['Libro C']),
        exclusionPatterns: const [],
      );
      x = await exam();
      expect(x['topics'], isNull);
      expect(x['study_materials'], isNull);
      // un pack senza le chiavi non li tocca
      await db.db.update('exams', {'topics': 'Scritto a mano'});
      await importer.importMap(
        pack(withKeys: false),
        exclusionPatterns: const [],
      );
      x = await exam();
      expect(x['topics'], 'Scritto a mano');
      expect(x['imported_topics'], 'Altro programma');
    });

    test('esami già importati prima: i campi vuoti si riempiono, quelli '
        'scritti dallo studente restano', () async {
      // come un account esistente: esame senza argomenti, materiali scritti
      await importer.importMap(
        pack(withKeys: false),
        exclusionPatterns: const [],
      );
      await db.db.update('exams', {'study_materials': '["Mie slide"]'});
      var x = await exam();
      expect(x['topics'], isNull);
      expect(x['imported_topics'], isNull);
      await importer.importMap(pack(), exclusionPatterns: const []);
      x = await exam();
      expect(x['topics'], 'Limiti');
      expect(x['study_materials'], '["Mie slide"]');
    });
  });

  test('libro segnato come posseduto in un aggiornamento', () async {
    Map<String, Object?> book(String id, bool? downloaded) => {
      'externalId': id,
      'courseExternalId': 'polito:course:A',
      'title': 'Libro $id',
      'downloaded': ?downloaded,
    };
    final first = {
      ..._pack(),
      'books': [book('b1', false), book('b2', false), book('b3', false)],
    };
    await importer.importMap(first, exclusionPatterns: const []);
    // L'utente ha detto di non volere b3.
    await db.db.update('books', {
      'ownership_status': 'not_needed',
    }, where: "external_id = 'b3'");
    final second = {
      ..._pack(),
      'books': [book('b1', true), book('b2', null), book('b3', true)],
    };
    await importer.importMap(second, exclusionPatterns: const []);
    final rows = {
      for (final r in await db.db.query('books'))
        r['external_id']: r['ownership_status'],
    };
    expect(rows, {'b1': 'owned', 'b2': 'wanted', 'b3': 'not_needed'});

    // removeBooks: tolto solo se ancora «da procurare».
    await importer.importMap({
      ..._pack(),
      'removeBooks': ['b1', 'b2', 'b3', 'inesistente'],
    }, exclusionPatterns: const []);
    final left = (await db.db.query('books')).map((r) => r['external_id']);
    expect(left, unorderedEquals(['b1', 'b3']));
  });

  test('replaceEventsOfSameSource rimuove gli eventi spariti', () async {
    await importer.importMap(_pack(), exclusionPatterns: kAllPresetPatterns);
    final r = await importer.importMap(
      _pack(
        replace: true,
        events: [
          {
            'externalId': 'e9',
            'type': 'lecture',
            'courseExternalId': 'polito:course:A',
            'title': 'Analisi I',
            'start': '2026-10-07T08:30:00',
          },
        ],
      ),
      exclusionPatterns: kAllPresetPatterns,
    );
    expect(r.eventsRemoved, 1);
    final ids = (await db.db.query('events')).map((e) => e['external_id']);
    expect(ids, ['e9']);
  });

  test('un pack non valido non modifica il database', () async {
    await importer.importMap(_pack(), exclusionPatterns: const []);
    final before = (await db.db.query('courses')).length;
    final bad = _pack()
      ..['courses'] = [
        {'externalId': 'z', 'name': 'Z'},
        {'externalId': 'polito:course:A', 'name': null},
      ];
    // Forza un errore a metà transazione con un evento senza tabella valida.
    bad['events'] = [
      {'externalId': 'e1', 'title': 'x', 'start': 'non-una-data'},
    ];
    await importer.importMap(bad, exclusionPatterns: const []);
    expect((await db.db.query('courses')).length, greaterThanOrEqualTo(before));
    await expectLater(
      importer.importJson('{"format":"altro"}', exclusionPatterns: const []),
      throwsA(isA<DataPackException>()),
    );
  });

  test('removeEventsOfSources elimina l\'orario provvisorio da PDF', () async {
    await importer.importMap(
      _pack(
        events: [
          {
            'externalId': 'pdf1',
            'type': 'lecture',
            'courseExternalId': 'polito:course:A',
            'title': 'Analisi I',
            'start': '2026-10-05T14:30:00',
            'source': 'orario-pdf:polito',
          },
        ],
      ),
      exclusionPatterns: kAllPresetPatterns,
    );
    final pack = _pack()..['removeEventsOfSources'] = ['orario-pdf:polito'];
    final r = await importer.importMap(
      pack,
      exclusionPatterns: kAllPresetPatterns,
    );
    expect(r.eventsRemoved, 1);
    final ids = (await db.db.query('events')).map((e) => e['external_id']);
    expect(ids, isNot(contains('pdf1')));
    expect(ids, contains('e1'));

    // Un successivo import del seed non deve far ricomparire l'orario da PDF.
    await importer.importMap(
      _pack(
        events: [
          {
            'externalId': 'pdf1',
            'type': 'lecture',
            'courseExternalId': 'polito:course:A',
            'title': 'Analisi I',
            'start': '2026-10-05T14:30:00',
            'source': 'orario-pdf:polito',
          },
        ],
      ),
      exclusionPatterns: kAllPresetPatterns,
    );
    final after = (await db.db.query('events')).map((e) => e['external_id']);
    expect(after, isNot(contains('pdf1')));
  });

  test('studyModules: struttura pronta solo nei corsi senza moduli', () async {
    await importer.importMap(_pack(), exclusionPatterns: kAllPresetPatterns);
    Map<String, Object?> modulesPack() => {
      'format': 'university-manager-datapack',
      'version': 1,
      'source': 'struttura-studio',
      'studyModules': [
        {
          'externalId': 'polito:study:A:2',
          'courseExternalId': 'polito:course:A',
          'name': 'Cap. 2 – Limiti',
          'sort': 2,
          'topics': [
            {'name': '2.1 Definizione', 'notes': 'Libro: pp. 40–52'},
            '2.2 Limiti notevoli',
          ],
        },
        {
          'externalId': 'polito:study:A:1',
          'courseExternalId': 'polito:course:A',
          'name': 'Cap. 1 – Numeri reali',
          'sort': 1,
          'topics': [],
        },
        {
          'externalId': 'x',
          'courseExternalId': 'polito:course:SCONOSCIUTO',
          'name': 'Ignorato',
        },
      ],
    };
    final r = await importer.importMap(
      modulesPack(),
      exclusionPatterns: kAllPresetPatterns,
    );
    expect(r.modules, 2);
    final mods = await db.db.query('modules', orderBy: 'sort');
    expect(mods.map((m) => m['name']), [
      'Cap. 1 – Numeri reali',
      'Cap. 2 – Limiti',
    ]);
    final topics = await db.db.query('topics', orderBy: 'sort');
    expect(topics.map((t) => t['name']), [
      '2.1 Definizione',
      '2.2 Limiti notevoli',
    ]);
    expect(topics.first['notes'], 'Libro: pp. 40–52');

    // Il corso ha già moduli (magari modificati): il reimport non li tocca.
    await db.db.update('modules', {'name': 'Mio nome'}, where: 'sort = 0');
    final again = await importer.importMap(
      modulesPack(),
      exclusionPatterns: kAllPresetPatterns,
    );
    expect(again.modules, 0);
    expect(await db.db.query('modules'), hasLength(2));
    expect(
      (await db.db.query('modules', where: 'sort = 0')).single['name'],
      'Mio nome',
    );
  });
}
