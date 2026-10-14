import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/academic/academic_year.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/catalog/catalog_datapack.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/course_replacements.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/catalog_fixtures.dart';

const _base = 'polito-l8-ingegneria-informatica';
const _old1 = 'polito-l8-corso-di-laurea-in-ingegneria-informatica';
const _old2 = 'polito-l8-ingegneria-informatica-vecchio';
const _new = _base;

Map<String, Object?> _map(Map<String, String> pairs) => {
  'schema': 1,
  'corsi': {
    for (final e in pairs.entries)
      e.key: {
        'nuovo': e.value,
        'universita_id': 'polito',
        'motivo': 'doppione',
        'dal': '2026-10-13',
      },
  },
};

void main() {
  group('CorsiSostituiti', () {
    test('catene: A→B→C porta a C', () {
      final m = CorsiSostituiti.fromJson(_map({'a': 'b', 'b': 'c'}));
      expect(m.risolvi('a'), 'c');
      expect(m.risolvi('b'), 'c');
    });

    test('id assente dalla mappa: null', () {
      final m = CorsiSostituiti.fromJson(_map({'a': 'b'}));
      expect(m.risolvi('x'), isNull);
      // il corso nuovo non è a sua volta sostituito
      expect(m.risolvi('b'), isNull);
      expect(CorsiSostituiti.empty.risolvi('a'), isNull);
    });

    test('cicli ignorati (anche con coda)', () {
      final m = CorsiSostituiti.fromJson(
        _map({'a': 'b', 'b': 'a', 'x': 'a', 's': 's'}),
      );
      expect(m.risolvi('a'), isNull);
      expect(m.risolvi('b'), isNull);
      expect(m.risolvi('x'), isNull);
      // voce che punta a sé stessa: scartata già alla lettura
      expect(m.corsi.containsKey('s'), isFalse);
      expect(m.risolvi('s'), isNull);
    });

    test('ateneo diverso da quello della voce: ignorata', () {
      final m = CorsiSostituiti.fromJson(_map({'a': 'b'}));
      expect(m.risolvi('a', universitaId: 'polito'), 'b');
      expect(m.risolvi('a', universitaId: 'unimib'), isNull);
    });

    test('voci malformate saltate, schema futuro rifiutato', () {
      final m = CorsiSostituiti.fromJson({
        'schema': 1,
        'corsi': {
          'a': {'nuovo': 'b'},
          'senza': {'motivo': 'x'},
          'testo': 'b',
        },
      });
      expect(m.corsi.keys, ['a']);
      expect(m.corsi['a']!.universitaId, isNull);
      expect(CorsiSostituiti.fromJson({'schema': 1}).isEmpty, isTrue);
      expect(
        () => CorsiSostituiti.fromJson({'schema': 99, 'corsi': {}}),
        throwsA(isA<CatalogFormatException>()),
      );
    });
  });

  test('id esterni: cambia solo il prefisso del corso di laurea', () {
    String? r(String ext) => CourseReplacements.remapExternalId(ext, 'a', 'b');
    expect(r('polito:course:a-01rk'), 'polito:course:b-01rk');
    expect(r('polito:exam:a-01rk'), 'polito:exam:b-01rk');
    expect(
      r('polito:appello:a-01rk:2027-01-20'),
      'polito:appello:b-01rk:2027-01-20',
    );
    expect(r('polito:book:a-01rk:9788808062543'), isNotNull);
    expect(r('polito:course:ab-01rk'), isNull);
    expect(r('polito:course:other-a-01'), isNull);
    expect(r('manuale:polito:a'), isNull);
    expect(r('qualcosa'), isNull);
  });

  group('CatalogService.corsiSostituiti', () {
    late AppDatabase db;
    late Directory cache;
    setUp(() async {
      db = await AppDatabase.openInMemory();
      cache = Directory.systemTemp.createTempSync('sostituiti_test');
    });
    tearDown(() async {
      await db.close();
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });

    test('file mancante: mappa vuota, nessun errore', () async {
      final c = fakeCatalog(SettingsRepository(db), cacheDir: cache);
      expect((await c.corsiSostituiti()).isEmpty, isTrue);
      expect(await c.refreshIndexes(), isFalse);
      expect((await c.corsiSostituiti()).isEmpty, isTrue);
    });

    test('asset incluso, poi rete → cache', () async {
      final bundled = {
        'assets/database/universita.json': jsonEncode(kUniversitaFixture),
        'assets/database/indice_corsi.json': jsonEncode(kIndiceFixture),
        'assets/database/corsi_sostituiti.json': jsonEncode(_map({'a': 'b'})),
      };
      final c = fakeCatalog(
        SettingsRepository(db),
        cacheDir: cache,
        assets: bundled,
        remote: {
          'corsi_sostituiti.json': jsonEncode(_map({'a': 'c'})),
        },
      );
      expect((await c.corsiSostituiti()).risolvi('a'), 'b');
      await c.refreshIndexes();
      expect((await c.corsiSostituiti()).risolvi('a'), 'c');
      expect(File('${cache.path}/corsi_sostituiti.json').existsSync(), isTrue);

      // offline: resta la copia scaricata
      final offline = fakeCatalog(
        SettingsRepository(db),
        cacheDir: cache,
        assets: bundled,
      );
      expect((await offline.corsiSostituiti()).risolvi('a'), 'c');
    });

    test('file scaricato non valido: resta la copia precedente', () async {
      final c = fakeCatalog(
        SettingsRepository(db),
        cacheDir: cache,
        assets: {
          'assets/database/universita.json': jsonEncode(kUniversitaFixture),
          'assets/database/indice_corsi.json': jsonEncode(kIndiceFixture),
          'assets/database/corsi_sostituiti.json': jsonEncode(_map({'a': 'b'})),
        },
        remote: {'corsi_sostituiti.json': '[1, 2]'},
      );
      await c.refreshIndexes();
      expect((await c.corsiSostituiti()).risolvi('a'), 'b');
    });
  });

  group('migrazione del profilo', () {
    late AppDatabase db;
    late AppServices s;

    String withBase(String id) =>
        jsonEncode(corsiPolitoFixture()).replaceAll('"$_base', '"$id');

    /// Asset comuni dell'app (indice con il corso nuovo, quello eliminato
    /// assente): i corsi dell'ateneo non sono inclusi, si scaricano.
    Map<String, String> assets({Map<String, Object?>? sostituiti}) => {
      'assets/database/universita.json': jsonEncode(kUniversitaFixture),
      'assets/database/indice_corsi.json': jsonEncode(kIndiceFixture),
      if (sostituiti != null)
        'assets/database/corsi_sostituiti.json': jsonEncode(sostituiti),
    };

    /// Database online: i corsi dell'ateneo con il corso nuovo.
    Map<String, String> online() => {'corsi/polito.json': withBase(_new)};

    StudentProfile profile(String degreeId, {bool manual = false}) =>
        StudentProfile(
          manual: manual,
          universityId: 'polito',
          universityName: 'Politecnico di Torino',
          universityShort: 'PoliTO',
          universityType: 'statale',
          degreeId: degreeId,
          degreeName: 'Corso di laurea in Ingegneria Informatica',
          degreeType: 'L',
          classCode: 'L-8',
          durationYears: 3,
          currentYear: 2,
          referenceAa: const AcademicYear(2026),
        );

    /// Studente con il piano importato dal corso con id [degreeId], un voto
    /// registrato e gli elenchi di id nelle impostazioni.
    Future<void> studente(String degreeId) async {
      await s.profiles.replace(profile(degreeId));
      final corso = CorsiAteneo.fromJson(jsonDecode(withBase(degreeId)))
          .corso(degreeId)!;
      final ateneo = UniversitaCatalog.fromJson(kUniversitaFixture)
          .byId('polito')!;
      await s.importer.importMap(
        catalogToDataPack(
          ateneo: ateneo,
          corso: corso,
          aggiornatoIl: '2026-10-04',
        ),
        exclusionPatterns: const [],
      );
      await s.loadProfile();
      await db.db.update(
        'exams',
        {'status': 'passed', 'grade': 28, 'laude': 0, 'notes': 'ottimo'},
        where: 'external_id = ?',
        whereArgs: ['polito:exam:$degreeId-01rkcpl'],
      );
      await s.settings.set(
        PathSetupService.removedKey,
        'polito:course:$degreeId-04reti\nunimib:course:altro',
      );
      await s.settings.set(
        PathSetupService.prefilledKey,
        'polito:course:$degreeId-01rkcpl',
      );
    }

    Future<Map<String, Object?>> esame(String ext) async => (await db.db.query(
      'exams',
      where: 'external_id = ?',
      whereArgs: [ext],
    )).single;

    setUp(() async {
      db = await AppDatabase.openInMemory();
    });
    tearDown(() async => db.close());

    AppServices services(
      Map<String, String> bundled, {
      Map<String, String>? remote,
    }) {
      final settings = SettingsRepository(db);
      return s = AppServices(
        db,
        catalog: fakeCatalog(
          settings,
          assets: bundled,
          remote: remote ?? online(),
        ),
      );
    }

    test('corso sostituito: profilo e dati passano al nuovo id', () async {
      services(assets(sostituiti: _map({_old1: _old2, _old2: _new})));
      await studente(_old1);
      final examBefore = await esame('polito:exam:$_old1-01rkcpl');
      final coursesBefore = await db.db.query('courses');
      expect(coursesBefore, hasLength(4));

      final r = await PathSetupService(s).migrateReplacedCourses();
      expect(r, isNotNull);
      expect(r!.oldId, _old1);
      expect(r.newId, _new); // catena seguita fino in fondo
      expect(r.newName, 'Ingegneria Informatica');

      final p = (await s.profiles.load())!;
      expect(p.degreeId, _new);
      expect(p.degreeName, 'Ingegneria Informatica');
      expect(p.classCode, 'L-8');
      expect(p.currentYear, 2); // anno invariato
      expect(s.profile.value!.degreeId, _new);

      // nessun duplicato: stesse righe, nuovi id (l'insegnamento che lo
      // studente aveva eliminato resta eliminato)
      final courses = await db.db.query('courses');
      expect(courses, hasLength(3));
      expect(courses.map((c) => c['degree_id']).toSet(), {_new});
      expect(
        courses.map((c) => c['external_id']).toSet(),
        containsAll([
          'polito:course:$_new-01rkcpl',
          'polito:course:$_new-03algo',
        ]),
      );

      // esame con voto e note: stessa riga, dati intatti
      final exam = await esame('polito:exam:$_new-01rkcpl');
      expect(exam['id'], examBefore['id']);
      expect(exam['grade'], 28);
      expect(exam['status'], 'passed');
      expect(exam['notes'], 'ottimo');
      expect(
        await db.db.query(
          'exams',
          where: 'external_id LIKE ?',
          whereArgs: ['%$_old1%'],
        ),
        isEmpty,
      );

      // elenchi nelle impostazioni
      expect(
        await s.settings.get(PathSetupService.removedKey),
        'polito:course:$_new-04reti\nunimib:course:altro',
      );
      expect(
        await s.settings.get(PathSetupService.prefilledKey),
        'polito:course:$_new-01rkcpl',
      );

      // il piano del nuovo corso è stato importato senza perdere nulla
      expect((await db.db.query('degrees')).map((d) => d['id']).toList(), [
        _new,
      ]);
      expect((await esame('polito:exam:$_new-01rkcpl'))['grade'], 28);
    });

    test('avviso una sola volta, migrazione una sola volta', () async {
      services(assets(sostituiti: _map({_old1: _new})));
      await studente(_old1);
      expect(await PathSetupService(s).migrateReplacedCourses(), isNotNull);

      expect(await takeCourseReplacedNotice(s), 'Ingegneria Informatica');
      expect(await takeCourseReplacedNotice(s), isNull);

      // di nuovo: nulla da fare, nessun nuovo avviso
      expect(await PathSetupService(s).migrateReplacedCourses(), isNull);
      expect(await takeCourseReplacedNotice(s), isNull);
      expect((await s.profiles.load())!.degreeId, _new);
    });

    test('curriculum non più valido: si riparte dal predefinito', () async {
      services(assets(sostituiti: _map({_old1: _new})));
      await studente(_old1);
      await s.profiles.save(
        (await s.profiles.load())!.copyWith(curriculum: () => 'Percorso X'),
      );
      await PathSetupService(s).migrateReplacedCourses();
      // il nuovo corso non ha percorsi tra cui scegliere
      expect((await s.profiles.load())!.curriculum, isNull);
    });

    test('mappa assente: tutto invariato', () async {
      services(assets());
      await studente(_old1);
      expect(await PathSetupService(s).migrateReplacedCourses(), isNull);
      expect((await s.profiles.load())!.degreeId, _old1);
      expect(await takeCourseReplacedNotice(s), isNull);
    });

    test('id non nella mappa: comportamento attuale invariato', () async {
      services(assets(sostituiti: _map({'altro-corso': _new})));
      await studente(_old1);
      expect(await PathSetupService(s).migrateReplacedCourses(), isNull);
      expect((await s.profiles.load())!.degreeId, _old1);
      final courses = await db.db.query('courses');
      expect(courses.map((c) => c['degree_id']).toSet(), {_old1});
      expect((await esame('polito:exam:$_old1-01rkcpl'))['grade'], 28);
    });

    test('cicli nella mappa: ignorati', () async {
      services(assets(sostituiti: _map({_old1: _old2, _old2: _old1})));
      await studente(_old1);
      expect(await PathSetupService(s).migrateReplacedCourses(), isNull);
      expect((await s.profiles.load())!.degreeId, _old1);
    });

    test('corso nuovo non ancora nel catalogo: si riprova più tardi', () async {
      // né nell'indice né nel file dell'ateneo
      services(assets(sostituiti: _map({_old1: 'polito-inesistente'})));
      await studente(_old1);
      expect(await PathSetupService(s).migrateReplacedCourses(), isNull);
      expect((await s.profiles.load())!.degreeId, _old1);
    });

    test('corso manuale: non toccato', () async {
      services(assets(sostituiti: _map({'manuale:polito:x': _new})));
      await s.profiles.replace(profile('manuale:polito:x', manual: true));
      await s.loadProfile();
      expect(await PathSetupService(s).migrateReplacedCourses(), isNull);
      expect((await s.profiles.load())!.degreeId, 'manuale:polito:x');
    });

    test('«Aggiorna database» scarica la mappa e migra il profilo', () async {
      final settings = SettingsRepository(db);
      s = AppServices(
        db,
        catalog: fakeCatalog(
          settings,
          assets: assets(),
          remote: {
            'universita.json': jsonEncode(kUniversitaFixture),
            'indice_corsi.json': jsonEncode(kIndiceFixture),
            'corsi_sostituiti.json': jsonEncode(_map({_old1: _new})),
            'corsi/polito.json': withBase(_new),
          },
        ),
      );
      await studente(_old1);

      final r = await PathSetupService(s).refresh();
      expect(r.imported, isTrue);
      expect((await s.profiles.load())!.degreeId, _new);
      expect(s.profile.value!.degreeId, _new);
      expect(await db.db.query('courses'), hasLength(3));
      expect((await esame('polito:exam:$_new-01rkcpl'))['grade'], 28);
      expect(await takeCourseReplacedNotice(s), 'Ingegneria Informatica');
    });

    test(
      'insegnamento sparito dal corso nuovo ma con voti: archiviato',
      () async {
        services(assets(sostituiti: _map({_old1: _new})));
        await studente(_old1);
        final id = await s.courses.insert(
          const Course(
            name: 'Solo nel vecchio',
            externalId: 'polito:course:$_old1-soloold',
            universityId: 'polito',
            degreeId: _old1,
          ),
        );
        await db.db.insert('exams', {
          'course_id': id,
          'kind': 'final',
          'status': 'passed',
          'grade': 25,
          'external_id': 'polito:exam:$_old1-soloold',
        });
        await PathSetupService(s).migrateReplacedCourses();
        final c = (await db.db.query(
          'courses',
          where: 'id = ?',
          whereArgs: [id],
        )).single;
        expect(c['degree_id'], _new);
        expect(c['external_id'], 'polito:course:$_new-soloold');
        expect(c['status'], 'archived');
        expect((await esame('polito:exam:$_new-soloold'))['grade'], 25);
      },
    );
  });
}
