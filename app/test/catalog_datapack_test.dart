import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/catalog/catalog_datapack.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/catalog_service.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/constants/text_limits.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/theme/university_colors.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/catalog_fixtures.dart';

final _universita = UniversitaCatalog.fromJson(kUniversitaFixture);
final _indice = IndiceCorsi.fromJson(kIndiceFixture);

Future<AppServices> _services({Map<String, String> remote = const {}}) async {
  final db = await AppDatabase.openInMemory();
  final settings = SettingsRepository(db);
  return AppServices(db, catalog: fakeCatalog(settings, remote: remote));
}

Map<String, String> _remote({
  List<Map<String, Object?>> extraBooks = const [],
  Map<String, Object?>? moduli,
}) => {
  'corsi/polito.json': jsonEncode(corsiPolitoFixture(extraBooks: extraBooks)),
  if (moduli != null) 'moduli/polito.json': jsonEncode(moduli),
};

const _analisi = 'polito-l8-ingegneria-informatica-01rkcpl';
const _fisica = 'polito-l8-ingegneria-informatica-02fisica';
const _algo = 'polito-l8-ingegneria-informatica-03algo';

/// `moduli/polito.json`: Analisi con indice del libro e programma ufficiale,
/// Fisica con il solo programma, Algoritmi con il solo indice del libro.
Map<String, Object?> _moduli({String limiti = 'Limiti di funzioni'}) => {
  'schema': 1,
  'universita_id': 'polito',
  'insegnamenti': {
    _analisi: {
      'origine': 'indice',
      'fonte': 'Indice di «Analisi Matematica 1»',
      'moduli': [
        {
          'nome': 'Cap. 1 Numeri reali',
          'argomenti': ['1.1 Assiomi'],
        },
      ],
      'programma': [
        {
          'nome': 'Limiti',
          'argomenti': [limiti, 'Successioni'],
        },
        {'nome': 'Derivate', 'argomenti': <String>[]},
      ],
      'fonte_programma': 'https://didattica.polito.it/01RKCPL',
    },
    _fisica: {
      'origine': 'programma',
      'fonte': "Programma ufficiale dell'insegnamento",
      'moduli': [
        {'nome': 'Cinematica', 'argomenti': <String>[]},
      ],
    },
    _algo: {
      'origine': 'indice',
      'moduli': [
        {
          'nome': 'Cap. 1 Ricorsione',
          'argomenti': ['1.1 Esempi'],
        },
      ],
    },
  },
};

PathSelection _selection({int year = 1}) => PathSelection(
  ateneo: _universita.byId('polito')!,
  tipo: TipoCorso.l,
  corso: _indice.corsi.first,
  year: year,
);

void main() {
  test('conversione catalogo → data pack', () {
    final corso = CorsiAteneo.fromJson(corsiPolitoFixture()).corsi.single;
    final pack = catalogToDataPack(
      ateneo: _universita.byId('polito')!,
      corso: corso,
      now: DateTime(2026, 10, 4),
    );
    expect(pack['format'], 'university-manager-datapack');
    final courses = pack['courses'] as List;
    expect(courses, hasLength(4));
    final analisi = courses.first as Map;
    expect(
      analisi['externalId'],
      'polito:course:polito-l8-ingegneria-informatica-01rkcpl',
    );
    expect(analisi['year'], 1);
    expect(analisi['cfu'], 10);
    expect(analisi['teacher'], 'Mario Rossi');
    expect(analisi['degreeId'], 'polito-l8-ingegneria-informatica');
    expect((courses[1] as Map)['booksStatus'], 'da_aggiungere');
    // Un esame finale per insegnamento + la prova in itinere.
    final exams = pack['exams'] as List;
    expect(exams.where((e) => (e as Map)['kind'] == 'final'), hasLength(4));
    final midterm =
        exams.singleWhere((e) => (e as Map)['kind'] == 'midterm') as Map;
    expect(midterm['date'], '2026-11-12');
    // L'appello diventa una finestra d'esame nel calendario.
    final events = pack['events'] as List;
    expect((events.single as Map)['start'], '2027-01-20T09:00:00');
    expect((events.single as Map)['type'], 'exam_window');
    final books = pack['books'] as List;
    expect(books, hasLength(2));
    expect(
      (books.first as Map)['externalId'],
      'polito:book:polito-l8-ingegneria-informatica-01rkcpl:9788808062543',
    );
    expect((books.first as Map)['required'], isTrue);
    // Colore deterministico per qualunque ateneo.
    final uni = (pack['universities'] as List).single as Map;
    expect(
      uni['color'],
      '#${(UniversityColors.deterministic('polito').toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
    );
  });

  test(
    'onboarding: profilo, anni del piano e import di tutti gli anni',
    () async {
      final s = await _services(remote: _remote());
      addTearDown(s.database.close);
      final r = await PathSetupService(s)
          .apply(_selection(year: 2), now: DateTime(2026, 10, 4));
      expect(r.imported, isTrue);
      expect(r.courses, 4);
      final p = (await s.profiles.load())!;
      expect(p.degreeId, 'polito-l8-ingegneria-informatica');
      expect(p.currentYear, 2);
      expect(p.referenceAa.label, '2026/27');
      expect(
        [for (final y in await s.profiles.planYears()) y.status],
        [PlanYearStatus.inCorso, PlanYearStatus.inCorso, PlanYearStatus.futuro],
      );

      final courses = await s.courses.all();
      expect(courses, hasLength(4));
      final fisica = courses.singleWhere((c) => c.name == 'Fisica I');
      expect(fisica.booksToAdd, isTrue);
      expect(fisica.examsToAdd, isTrue);
      final unis = await s.courses.universities();
      expect(unis.single.id, 'polito');
      expect(
        unis.single.color,
        UniversityColors.deterministic('polito').toARGB32(),
      );
      final exams = await s.exams.all();
      expect(exams.where((e) => e.kind == ExamKind.finalExam), hasLength(4));
      expect(exams.where((e) => e.kind == ExamKind.midterm), hasLength(1));
      expect(await s.books.all(), hasLength(2));
    },
  );

  test(
    'offline al primo avvio: profilo salvato, piano da scaricare dopo',
    () async {
      final s = await _services();
      addTearDown(s.database.close);
      final r = await PathSetupService(s).apply(_selection());
      expect(r.imported, isFalse);
      expect(r.senzaRete, isTrue);
      expect(r.message, PathSetupService.offlineMessage);
      expect(await s.profiles.load(), isNotNull);
      expect(await s.courses.all(), isEmpty);
      expect(
        (await s.courses.degrees()).single.id,
        'polito-l8-ingegneria-informatica',
      );
    },
  );

  test('scelta del corso: scarica i dati dell\'ateneo; cambio d\'ateneo: '
      'quelli del precedente si eliminano', () async {
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    final cache = Directory.systemTemp.createTempSync('datapack_cache');
    addTearDown(() => cache.deleteSync(recursive: true));
    final requests = <Uri>[];
    final s = AppServices(
      db,
      catalog: fakeCatalog(
        SettingsRepository(db),
        cacheDir: cache,
        requests: requests,
        remote: {
          ..._remote(),
          'sessioni/polito.json': jsonEncode({
            'schema': 1,
            'universita_id': 'polito',
          }),
        },
      ),
    );
    final r = await PathSetupService(s).apply(_selection());
    expect(r.imported, isTrue);
    expect(r.senzaRete, isFalse);
    expect(File('${cache.path}/corsi/polito.json').existsSync(), isTrue);
    expect(File('${cache.path}/sessioni/polito.json').existsSync(), isTrue);
    // solo i file di PoliTO (più meta.json)
    expect(
      requests.every(
        (u) => u.path.endsWith('/polito.json') || u.path.endsWith('meta.json'),
      ),
      isTrue,
    );

    // nuovo ateneo (corso a mano): i dati di PoliTO escono dalla cache
    await PathSetupService(s).apply(
      PathSelection(
        ateneo: _universita.byId('unimib')!,
        tipo: TipoCorso.l,
        manualName: 'Psicologia',
        year: 1,
      ),
    );
    expect(File('${cache.path}/corsi/polito.json').existsSync(), isFalse);
    expect(File('${cache.path}/sessioni/polito.json').existsSync(), isFalse);
  });

  test(
    'offline dopo il download: il piano si reimporta dalla copia salvata',
    () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final cache = Directory.systemTemp.createTempSync('datapack_cache');
      addTearDown(() => cache.deleteSync(recursive: true));
      final settings = SettingsRepository(db);
      final online = AppServices(
        db,
        catalog: fakeCatalog(settings, cacheDir: cache, remote: _remote()),
      );
      await PathSetupService(online).apply(_selection());
      final offline = AppServices(
        db,
        catalog: fakeCatalog(settings, cacheDir: cache),
      );
      offline.profile.value = await offline.profiles.load();
      final r = await PathSetupService(offline).refresh();
      expect(r.imported, isTrue);
      expect(r.senzaRete, isFalse);
      expect(r.source, CatalogSource.cache);
      expect(await offline.courses.all(), hasLength(4));
    },
  );

  test('corso inserito a mano: funziona con qualunque ateneo', () async {
    final s = await _services();
    addTearDown(s.database.close);
    final r = await PathSetupService(s).apply(
      PathSelection(
        ateneo: _universita.byId('unipegaso')!,
        tipo: TipoCorso.lm,
        manualName: 'Management dello sport',
        manualClass: 'LM-47',
        manualDuration: 2,
        year: 1,
      ),
    );
    expect(r.imported, isFalse);
    final p = (await s.profiles.load())!;
    expect(p.manual, isTrue);
    expect(p.degreeId, 'manuale:unipegaso:management-dello-sport');
    expect(p.durationYears, 2);
    expect((await s.courses.universities()).single.id, 'unipegaso');
  });

  test(
    'reimport: libri rimossi restano nascosti, modifiche preservate',
    () async {
      final s = await _services(remote: _remote());
      addTearDown(s.database.close);
      await PathSetupService(s).apply(_selection());
      s.profile.value = await s.profiles.load();

      final books = await s.books.all();
      final required = books.singleWhere(
        (b) => b.title == 'Analisi Matematica 1',
      );
      final suggested = books.singleWhere(
        (b) => b.title == 'Esercizi di Analisi',
      );
      expect(required.awaitingChoice, isTrue);
      // Rimuovi il consigliato, tieni e modifica l'obbligatorio.
      await s.books.update(
        suggested.withChoice(catalogChoice: () => CatalogChoice.removed),
      );
      await s.books.update(
        Book(
          id: required.id,
          externalId: required.externalId,
          courseId: required.courseId,
          title: 'Analisi 1 (mia edizione)',
          ownership: BookOwnership.owned,
          catalogChoice: CatalogChoice.kept,
          userEdited: true,
        ),
      );
      // Data e voto dell'esame scelti dallo studente.
      final analisi = (await s.courses.all()).singleWhere(
        (c) => c.name == 'Analisi matematica I',
      );
      final exam = (await s.exams.byCourse(analisi.id!))
          .singleWhere((e) => e.kind == ExamKind.finalExam);
      await s.exams.update(
        exam.copyWith(date: DateTime(2027, 2, 3), status: ExamStatus.booked),
      );

      // "Aggiorna database" con un libro nuovo nel catalogo.
      final s2 = AppServices(
        s.database,
        catalog: fakeCatalog(
          s.settings,
          remote: _remote(
            extraBooks: [
              {'titolo': 'Nuovo eserciziario', 'tipo': 'consigliato'},
            ],
          ),
        ),
      )..profile.value = s.profile.value;
      final r = await PathSetupService(s2).refresh();
      expect(r.imported, isTrue);

      final after = await s.books.all();
      expect(after, hasLength(3));
      final removed = after.singleWhere(
        (b) => b.title == 'Esercizi di Analisi',
      );
      expect(removed.isRemoved, isTrue);
      final kept = after.singleWhere((b) => b.id == required.id);
      expect(kept.title, 'Analisi 1 (mia edizione)');
      expect(kept.ownership, BookOwnership.owned);
      expect(kept.catalogChoice, CatalogChoice.kept);
      expect(
        after
            .singleWhere((b) => b.title == 'Nuovo eserciziario')
            .awaitingChoice,
        isTrue,
      );
      final examAfter = (await s.exams.byId(exam.id!))!;
      expect(examAfter.date, DateTime(2027, 2, 3));
      expect(examAfter.status, ExamStatus.booked);
      // Nessun doppione di corsi o esami.
      expect(await s.courses.all(), hasLength(4));
      expect(
        (await s.exams.all()).where((e) => e.kind == ExamKind.finalExam),
        hasLength(4),
      );
    },
  );

  test('moduli: origine, programma e fonte_programma facoltativi', () {
    final m = ModuliAteneo.fromJson(_moduli());
    final analisi = m.insegnamenti[_analisi]!;
    expect(analisi.origine, OrigineModuli.indice);
    expect(analisi.moduli.single.nome, 'Cap. 1 Numeri reali');
    expect(analisi.programma.map((x) => x.nome), ['Limiti', 'Derivate']);
    expect(analisi.fonteProgramma, 'https://didattica.polito.it/01RKCPL');
    expect(analisi.argomentiEsame, same(analisi.programma));
    final fisica = m.insegnamenti[_fisica]!;
    expect(fisica.programma, isEmpty);
    expect(fisica.argomentiEsame.single.nome, 'Cinematica');
    // l'indice di un libro non è mai argomento d'esame
    expect(m.insegnamenti[_algo]!.argomentiEsame, isEmpty);
    // file precedenti: senza origine = libreria, senza programma
    final vecchio = ModuliAteneo.fromJson({
      'universita_id': 'polito',
      'insegnamenti': {
        'x': {
          'moduli': [
            {'nome': 'A'},
          ],
        },
        'vuoto': {'moduli': <Object>[]},
      },
    });
    expect(vecchio.insegnamenti.keys, ['x']);
    expect(vecchio.insegnamenti['x']!.origine, OrigineModuli.libreria);
    expect(vecchio.insegnamenti['x']!.programma, isEmpty);
    expect(vecchio.insegnamenti['x']!.fonteProgramma, isNull);
    expect(vecchio.insegnamenti['x']!.argomentiEsame, isEmpty);
  });

  test('esame finale: argomenti dal programma, materiali dai libri', () {
    final corso = CorsiAteneo.fromJson(
      corsiPolitoFixture(
        extraBooks: [
          {
            'titolo': 'Analisi Matematica 1',
            'citazione': 'M. Bramanti, Esercitazioni di Analisi 1, Esculapio',
          },
          {
            'titolo': 'Calcolo',
            'autori': 'Adams',
            'editore': 'CEA',
            'tipo': 'obbligatorio',
          },
        ],
      ),
    ).corsi.single;
    final pack = catalogToDataPack(
      ateneo: _universita.byId('polito')!,
      corso: corso,
      moduli: ModuliAteneo.fromJson(_moduli()),
    );
    final exams = [for (final e in pack['exams'] as List) e as Map];
    Map finale(String id) => exams.singleWhere(
      (e) => e['externalId'] == CatalogIds.finalExam('polito', id),
    );
    final analisi = finale(_analisi);
    // il programma, non l'indice del libro
    expect(
      analisi['topics'],
      '• Limiti: Limiti di funzioni, Successioni\n• Derivate',
    );
    // prima gli obbligatori, poi i consigliati, poi gli altri
    expect(analisi['studyMaterials'], [
      'Bramanti, Pagani, Salsa — Analisi Matematica 1 (Zanichelli, 2014)',
      'Adams — Calcolo (CEA)',
      'Esercizi di Analisi',
      'M. Bramanti, Esercitazioni di Analisi 1, Esculapio',
    ]);
    expect(finale(_fisica)['topics'], '• Cinematica');
    expect(finale(_fisica)['studyMaterials'], isEmpty);
    // solo l'indice del libro: nessun argomento d'esame
    expect(finale(_algo)['topics'], isNull);
    // le prove in itinere restano vuote
    final midterm = exams.singleWhere((e) => e['kind'] == 'midterm');
    expect(midterm.containsKey('topics'), isFalse);
    expect(midterm.containsKey('studyMaterials'), isFalse);
    // senza file dei moduli: argomenti vuoti, materiali comunque
    final senza = catalogToDataPack(
      ateneo: _universita.byId('polito')!,
      corso: corso,
    );
    final a2 = (senza['exams'] as List).first as Map;
    expect(a2['topics'], isNull);
    expect(a2['studyMaterials'], hasLength(4));
  });

  test('argomenti troppo lunghi: si tolgono le ultime righe', () {
    final lungo = ModuliInsegnamento(
      moduli: const [],
      origine: OrigineModuli.programma,
      programma: [
        for (var i = 0; i < 400; i++)
          ModuloCatalogo(nome: 'Modulo $i', argomenti: const ['uno', 'due']),
      ],
    );
    final t = argomentiEsame(lungo)!;
    expect(t.length, lessThanOrEqualTo(TextLimits.examTopics));
    expect(t.startsWith('• Modulo 0: uno, due\n'), isTrue);
    expect(t.endsWith('\n…'), isTrue);
    expect(argomentiEsame(null), isNull);
  });

  test(
    "import e «Aggiorna database»: argomenti e materiali dell'esame si "
    'riempiono e si aggiornano solo se lo studente non li ha toccati',
    () async {
      final s = await _services(remote: _remote(moduli: _moduli()));
      addTearDown(s.database.close);
      await PathSetupService(s).apply(_selection());
      s.profile.value = await s.profiles.load();
      Future<Exam> finale(String id) async => (await s.exams.all()).singleWhere(
        (e) => e.externalId == CatalogIds.finalExam('polito', id),
      );
      final analisi = await finale(_analisi);
      expect(analisi.topics, startsWith('• Limiti: Limiti di funzioni'));
      expect(analisi.studyMaterials, hasLength(2));
      final fisica = await finale(_fisica);
      expect(fisica.topics, '• Cinematica');
      expect((await finale(_algo)).topics, isNull);
      // la prova in itinere resta vuota
      final midterm = (await s.exams.all()).singleWhere(
        (e) => e.kind == ExamKind.midterm,
      );
      expect(midterm.topics, isNull);
      expect(midterm.studyMaterials, isEmpty);

      // lo studente riscrive gli argomenti di Analisi e i materiali di Fisica
      await s.exams.update(analisi.copyWith(topics: 'I miei argomenti'));
      await s.exams.update(fisica.copyWith(studyMaterials: ['Mie slide']));

      // «Aggiorna database» con programma e libri cambiati
      final s2 = AppServices(
        s.database,
        catalog: fakeCatalog(
          s.settings,
          remote: _remote(
            moduli: _moduli(limiti: 'Limiti notevoli'),
            extraBooks: [
              {'titolo': 'Nuovo eserciziario', 'tipo': 'consigliato'},
            ],
          ),
        ),
      )..profile.value = s.profile.value;
      expect((await PathSetupService(s2).refresh()).imported, isTrue);

      final a2 = await finale(_analisi);
      expect(a2.topics, 'I miei argomenti');
      // materiali non toccati: aggiornati con il libro nuovo
      expect(a2.studyMaterials, [
        'Bramanti, Pagani, Salsa — Analisi Matematica 1 (Zanichelli, 2014)',
        'Esercizi di Analisi',
        'Nuovo eserciziario',
      ]);
      final f2 = await finale(_fisica);
      expect(f2.studyMaterials, ['Mie slide']);
      expect(f2.topics, '• Cinematica');
    },
  );

  test('il file reale degli atenei produce data pack validi', () async {
    final real = UniversitaCatalog.fromJson(
      jsonDecode(File('../database/universita.json').readAsStringSync()),
    );
    final s = await _services();
    addTearDown(s.database.close);
    for (final a in real.universita.take(10)) {
      await s.importer.importMap(
        manualDegreeDataPack(ateneo: a, degreeId: 'x:${a.id}', nome: 'Corso'),
        exclusionPatterns: const [],
      );
    }
    expect(await s.courses.universities(), hasLength(10));
  });

  test('Exam.copyWith mantiene i dati (sanity)', () {
    const e = Exam(courseId: 1, cfu: 6);
    expect(e.copyWith(grade: 28).cfu, 6);
  });

  test(
    'aggiornamento: doppioni ed eliminati spariscono, con dati si archiviano',
    () async {
      final s = await _services(remote: _remote());
      addTearDown(s.database.close);
      await PathSetupService(s).apply(_selection(), now: DateTime(2026, 10, 4));
      final courses = await s.courses.all();
      expect(courses, hasLength(4));
      final db = s.database.db;
      // un vecchio doppione (canale di un'altra sede) non più nel catalogo
      await db.insert('courses', {
        'external_id': 'polito:course:doppione-mondovi',
        'university_id': 'polito',
        'degree_id': 'polito-l8-ingegneria-informatica',
        'name': 'Analisi matematica I',
        'status': 'active',
      });
      // un altro doppione con un voto: si archivia, non si perde
      final conVoto = await db.insert('courses', {
        'external_id': 'polito:course:doppione-con-voto',
        'university_id': 'polito',
        'degree_id': 'polito-l8-ingegneria-informatica',
        'name': 'Fisica I',
        'status': 'active',
      });
      await db.insert('exams', {
        'course_id': conVoto,
        'status': 'passed',
        'grade': 28,
      });
      // un insegnamento eliminato dallo studente non torna
      final eliminato = courses.first;
      await s.courses.delete(eliminato.id!);
      await PathSetupService(s).rememberRemoved(eliminato.externalId);

      final corso = CorsiAteneo.fromJson(corsiPolitoFixture()).corsi.single;
      await PathSetupService(s)
          .importPlan((await s.profiles.load())!, now: DateTime(2026, 10, 5));
      final dopo = await s.courses.all();
      final ext = {for (final c in dopo) c.externalId};
      expect(ext, isNot(contains('polito:course:doppione-mondovi')));
      expect(ext, isNot(contains(eliminato.externalId)));
      final archiviato = dopo.firstWhere(
        (c) => c.externalId == 'polito:course:doppione-con-voto',
      );
      expect(archiviato.status, CourseStatus.archived);
      expect(corso.insegnamenti, hasLength(4));
    },
  );

  test(
    'aggiornamento: le modifiche a mano e la lingua inglese restano',
    () async {
      final s = await _services(remote: _remote());
      addTearDown(s.database.close);
      await PathSetupService(s).apply(_selection(), now: DateTime(2026, 10, 4));
      final c = (await s.courses.all()).first;
      await s.courses.update(
        c.copyWith(name: 'Analisi 1 (mio nome)').withUserEdited(),
      );
      await PathSetupService(s)
          .importPlan((await s.profiles.load())!, now: DateTime(2026, 10, 5));
      final dopo = (await s.courses.all()).firstWhere((x) => x.id == c.id);
      expect(dopo.name, 'Analisi 1 (mio nome)');
      expect(dopo.userEdited, isTrue);
    },
  );
}
