import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/catalog/nome_insegnamento.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/datapack_importer.dart';

/// Nomi degli insegnamenti nel database: solo il nome, senza i CFU e senza il
/// codice dell'insegnamento (`nome_insegnamento_pulito` e `nomi_insegnamenti`
/// in tools/db_builder/pulizia.py, ultimo passo della build), e la stessa
/// regola nell'app per gli insegnamenti importati prima che «Aggiorna
/// database» non rinomina (versione in inglese, insegnamenti modificati). Le
/// prove che eseguono Python si saltano se `python` non c'è.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  Future<ProcessResult?> python(List<String> args) async {
    for (final exe in ['python', 'python3']) {
      try {
        return await Process.run(
          exe,
          ['-X', 'utf8', '-I', ...args],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
      } on ProcessException {
        continue;
      }
    }
    return null;
  }

  // (nome, codici, ssd, atteso): gli stessi casi per Python e per l'app
  // (l'app non toglie il settore: ssd solo per Python)
  const casi = <(String, List<String>, String?, String)>[
    ('Core Abroad (6 CFU)', ['ECO1'], null, 'Core Abroad'),
    ('Analisi matematica I (10 CFU) (16ACFYO)', ['16ACFYO'], null, 'Analisi matematica I'),
    ('Analisi (6 cfu)', [], null, 'Analisi'),
    ('Analisi (CFU 6)', [], null, 'Analisi'),
    ('Analisi (6 crediti)', [], null, 'Analisi'),
    ('Computer Architecture (7.5 CFU)', [], null, 'Computer Architecture'),
    ('Storia Dell Industria ( 5 Cfu )', [], null, 'Storia Dell Industria'),
    ('Analisi - 6 CFU', [], null, 'Analisi'),
    ('Attivita a Scelta - Idoneita 9 Cfu', [], null, 'Attivita a Scelta - Idoneita'),
    ('Architettura dei Calcolatori CFU12', [], null, 'Architettura dei Calcolatori'),
    ('(6 Cfu) - Demografia', [], null, 'Demografia'),
    ('Analisi (1001234)', ['1001234'], null, 'Analisi'),
    ('Analisi (A000123)', ['A000123'], null, 'Analisi'),
    ('Analisi (cod. 12345)', [], null, 'Analisi'),
    ('Analisi [GIU0123]', ['GIU0123'], null, 'Analisi'),
    ('12345 - Analisi', ['12345'], null, 'Analisi'),
    ('Analisi - 12345', ['12345'], null, 'Analisi'),
    ('A422439 - Economics', ['A422439'], null, 'Economics'),
    ('Am110 - Analisi Matematica 1', ['20410405'], null, 'Analisi Matematica 1'),
    ('Al110-algebra 1', ['20402075'], null, 'Algebra 1'),
    ('Arabo (IARA)', ['IARA'], null, 'Arabo'),
    ('Demografia(1° Modulo) (6 CFU) (60172)', ['60172'], null, 'Demografia(1° Modulo)'),
    ('Thesis (gruppo a scelta, 20 CFU)', [], null, 'Thesis (gruppo a scelta)'),
    ('Prova Finale (1 Cfu - Discussione)', [], null, 'Prova Finale (Discussione)'),
    // restano: parti con un significato, CFU che descrivono una regola,
    // numeri senza unità, parole uguali a un codice senza cifre
    ('Fisica (modulo A)', [], null, 'Fisica (modulo A)'),
    ('Fisica (mod. 1)', [], null, 'Fisica (mod. 1)'),
    ('Diritto privato (A-L)', [], null, 'Diritto privato (A-L)'),
    ('Lingua Inglese (corso avanzato)', [], null, 'Lingua Inglese (corso avanzato)'),
    ('Inglese (B2)', [], null, 'Inglese (B2)'),
    ('Storia romana (I)', [], null, 'Storia romana (I)'),
    ('Radioprotezione (c.i.)', [], null, 'Radioprotezione (c.i.)'),
    ('Storia dell\'arte (integrato)', [], null, 'Storia dell\'arte (integrato)'),
    ('Economia (in inglese)', [], null, 'Economia (in inglese)'),
    ('Tirocinio (2° anno)', [], null, 'Tirocinio (2° anno)'),
    ('Laboratorio (2)', ['MC/0983'], null, 'Laboratorio (2)'),
    ('Insegnamenti a scelta libera (fra 6 e 12 CFU)', [], null,
        'Insegnamenti a scelta libera (fra 6 e 12 CFU)'),
    ('Gruppo OPZIONALI DA 8 CFU', [], null, 'Gruppo OPZIONALI DA 8 CFU'),
    ('Free ECTS Credits 1', [], null, 'Free ECTS Credits 1'),
    ('Tirocinio - Stage', ['STAGE'], null, 'Tirocinio - Stage'),
    ('Mod.1 - Linguistica Generale', ['SCF004_F1'], null, 'Mod.1 - Linguistica Generale'),
    ('Lingua Greca Moderna - A2', [], null, 'Lingua Greca Moderna - A2'),
    ('1 CFU a Libera Scelta (SM) - II Anno', [], null, '1 CFU a Libera Scelta (SM) - II Anno'),
    ('(6 CFU)', [], null, '(6 CFU)'),
  ];

  group('regola dei nomi nell\'app', () {
    for (final (nome, codici, _, atteso) in casi) {
      test('«$nome»', () {
        final r = nomeInsegnamentoPulito(nome, codici: codici);
        expect(r, atteso);
        expect(nomeInsegnamentoPulito(r, codici: codici), r, reason: 'idempotente');
      });
    }
  });

  group('regola dei nomi nella build (Python)', () {
    const carica =
        'import sys, json; sys.path.insert(0, "../tools/db_builder"); import pulizia as p; ';

    test('stessi casi dell\'app, e il settore uguale al campo si toglie', () async {
      final tutti = [
        for (final (n, c, s, a) in casi) [n, c, s, a],
        ['Storia Contemporanea B (m-sto/04)', <String>[], 'M-STO/04', 'Storia Contemporanea B'],
        ['Analisi (MAT/05)', <String>[], 'MAT/05 (MATH-03/A)', 'Analisi'],
        ['Prova Finale (iat-icar/02)', <String>[], null, 'Prova Finale (iat-icar/02)'],
      ];
      final r = await python([
        '-c',
        '${carica}casi = json.loads(sys.argv[1]); '
            'print(json.dumps([[p.nome_insegnamento_pulito(n, c, s), '
            'p.nome_insegnamento_pulito(p.nome_insegnamento_pulito(n, c, s), c, s)] '
            'for n, c, s, a in casi]))',
        jsonEncode(tutti),
      ]);
      if (r == null) {
        markTestSkipped('Python non disponibile');
        return;
      }
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = jsonDecode((r.stdout as String).trim()) as List;
      for (final (k, caso) in tutti.indexed) {
        expect((out[k] as List)[0], caso[3], reason: '${caso[0]}');
        expect((out[k] as List)[1], caso[3], reason: 'idempotente: ${caso[0]}');
      }
    });

    test('omonimi distinti, campi riempiti, id che non cambiano', () async {
      final corsi = [
        {
          'id': 'x',
          'insegnamenti': [
            // CFU diversi: «(N CFU)» dal campo, in un formato solo
            {'id': 'x-1', 'nome': 'Inglese (3 cfu) (ING01)', 'anno': 1, 'cfu': 3, 'codice': 'ING01'},
            {'id': 'x-2', 'nome': 'Inglese - 6 CFU', 'anno': 1, 'cfu': 6, 'codice': 'A2'},
            {'id': 'x-10', 'nome': 'Inglese', 'anno': 1, 'cfu': 7.5, 'codice': 'A3'},
            // CFU diversi ma percorsi diversi: lo studente ne vede uno, niente CFU
            {'id': 'x-11', 'nome': 'Tirocinio (3 CFU)', 'anno': 2, 'cfu': 3, 'curriculum': 'A'},
            {'id': 'x-12', 'nome': 'Tirocinio (6 CFU)', 'anno': 2, 'cfu': 6, 'curriculum': 'B'},
            // stessi CFU e solo il codice a distinguerli: tengono il codice
            {'id': 'x-3', 'nome': 'Core Abroad (ECO1)', 'anno': 2, 'cfu': 6, 'codice': 'ECO1'},
            {'id': 'x-4', 'nome': 'Core Abroad (ECO2)', 'anno': 2, 'cfu': 6, 'codice': 'ECO2'},
            // percorsi diversi (Torino e Mondovì): lo studente ne vede uno
            {
              'id': 'x-5', 'nome': 'Fisica I (10 CFU) (17AXOXP)', 'anno': 1, 'cfu': 10,
              'codice': '17AXOXP', 'curriculum': 'Percorso',
            },
            {
              'id': 'x-6', 'nome': 'Fisica I (10 CFU) (20AXOXP)', 'anno': 1, 'cfu': 10,
              'codice': '20AXOXP', 'curriculum': 'Primo anno sede di Mondovì',
            },
            // campi vuoti riempiti dal nome
            {'id': 'x-7', 'nome': 'Informatica (8 CFU)', 'anno': 1, 'cfu': null, 'codice': 'B1'},
            {'id': 'x-8', 'nome': 'Storia (cod. 120851)', 'anno': 3, 'cfu': 9, 'codice': null},
            // CFU del nome diversi dal campo: resta il campo
            {'id': 'x-9', 'nome': 'Chimica (12 CFU)', 'anno': 3, 'cfu': 9, 'codice': 'C1'},
          ],
        },
      ];
      final r = await python([
        '-c',
        '${carica}corsi = json.loads(sys.argv[1]); es = []; '
            'p.nomi_insegnamenti(corsi, es); '
            'print(json.dumps({"ins": corsi[0]["insegnamenti"], "tipi": sorted({e[0] for e in es})}))',
        jsonEncode(corsi),
      ]);
      if (r == null) {
        markTestSkipped('Python non disponibile');
        return;
      }
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = jsonDecode((r.stdout as String).trim()) as Map;
      final ins = [for (final i in out['ins'] as List) i as Map];
      expect([for (final i in ins) i['id']], [
        'x-1', 'x-2', 'x-10', 'x-11', 'x-12', //
        for (var k = 3; k <= 9; k++) 'x-$k',
      ]);
      expect([for (final i in ins) i['nome']], [
        'Inglese (3 CFU)',
        'Inglese (6 CFU)',
        'Inglese (7.5 CFU)',
        'Tirocinio',
        'Tirocinio',
        'Core Abroad (ECO1)',
        'Core Abroad (ECO2)',
        'Fisica I',
        'Fisica I',
        'Informatica',
        'Storia',
        'Chimica',
      ]);
      expect(ins[9]['cfu'], 8);
      expect(ins[10]['codice'], '120851');
      expect(ins[11]['cfu'], 9);
      expect(out['tipi'], containsAll(['omonimo', 'cfu_riempito', 'codice_riempito', 'cfu_diverso']));
      // una seconda pulizia non cambia nulla (anche «Inglese (3 CFU)» resta)
      final r2 = await python([
        '-c',
        '${carica}corsi = json.loads(sys.argv[1]); print(p.nomi_insegnamenti(corsi))',
        jsonEncode([
          {'id': 'x', 'insegnamenti': out['ins']},
        ]),
      ]);
      expect((r2!.stdout as String).trim(), '0');
    });

    test('versione del database: un numero in più se la data è già usata', () async {
      final r = await python([
        '-c',
        'import sys, json; sys.path.insert(0, "../tools/db_builder"); '
            'from ricostruisci import versione_nuova as v; '
            'print(json.dumps([v("2026.10.25", "2026.10.26"), v("2026.10.26", "2026.10.26"), '
            'v("2026.10.26.2", "2026.10.26"), v(None, "2026.10.26")]))',
      ]);
      if (r == null) {
        markTestSkipped('Python non disponibile');
        return;
      }
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(jsonDecode((r.stdout as String).trim()), [
        '2026.10.26',
        '2026.10.26.2',
        '2026.10.26.3',
        '2026.10.26',
      ]);
      // l'app confronta per uguaglianza e mostra la data
      final meta = jsonDecode(read('../database/meta.json')) as Map;
      expect(meta['versione'], matches(RegExp(r'^\d{4}\.\d{2}\.\d{2}(\.\d+)?$')));
    });

    test('la build non unisce insegnamenti già distinti nel database', () async {
      final corsi = [
        {
          'id': 'x',
          'insegnamenti': [
            {'id': 'x-a', 'nome': 'Fisica I', 'anno': 1, 'cfu': 10, 'codice': 'A', 'curriculum': 'Percorso'},
            {'id': 'x-b', 'nome': 'Fisica I', 'anno': 1, 'cfu': 10, 'codice': 'B', 'curriculum': 'Mondovì'},
            {'id': 'x-c', 'nome': 'Fisica I', 'anno': 1, 'cfu': 10, 'codice': 'C', 'curriculum': 'Altro'},
          ],
        },
      ];
      final r = await python([
        '-c',
        '${carica}corsi = json.loads(sys.argv[1]); '
            'p.unisci_omonimi(corsi, {"x-a", "x-b"}); '
            'print(json.dumps([i["id"] for i in corsi[0]["insegnamenti"]]))',
        jsonEncode(corsi),
      ]);
      if (r == null) {
        markTestSkipped('Python non disponibile');
        return;
      }
      expect(r.exitCode, 0, reason: '${r.stderr}');
      // x-c (nuovo) si unisce a x-a, x-b resta
      expect(jsonDecode((r.stdout as String).trim()), ['x-a', 'x-b']);
    });

    test('la pulizia è in tutti i punti in cui i nomi entrano nel database', () {
      final pulizia = read('../tools/db_builder/pulizia.py');
      expect(pulizia, contains('def nome_insegnamento_pulito('));
      expect(pulizia, contains('def nomi_insegnamenti('));
      expect(pulizia, contains('for g2 in _gia_distinti(g, esistenti):'));
      final build = read('../tools/db_builder/build_db.py');
      final repliche = build.indexOf('pulizia.repliche(corsi)');
      final nomi = build.indexOf('pulizia.nomi_insegnamenti(corsi)');
      expect(repliche, greaterThan(0));
      expect(nomi, greaterThan(repliche), reason: 'ultimo passo, dopo id e unioni');
      expect(nomi, lessThan(build.indexOf('write_json(path, doc)')));
      final dividi = read('../tools/db_builder/dividi_per_corso.py');
      expect(dividi, contains('nomi_insegnamenti(doc.get("corsi") or [])'));
      final strumento = read('../tools/db_builder/nomi_insegnamenti.py');
      expect(strumento, contains('from ricostruisci import LOCK, _blocca'));
      expect(strumento, contains('id o ordine degli insegnamenti cambiati'));
    });

    test(
      'il database non ha nomi con CFU o codice (controllo dello strumento)',
      () async {
        if (!Directory('../database/corsi').existsSync()) {
          markTestSkipped('database non disponibile');
          return;
        }
        final r = await python([
          '../tools/db_builder/nomi_insegnamenti.py',
          '--verifica',
        ]);
        if (r == null) {
          markTestSkipped('Python non disponibile');
          return;
        }
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });

  group('insegnamenti importati prima della pulizia', () {
    late AppDatabase db;
    late DataPackImporter importer;

    Map<String, Object?> pack(String name, {String code = '01AAA'}) => {
      'format': 'university-manager-datapack',
      'version': 1,
      'generatedAt': '2026-10-26T10:00:00',
      'source': 'test',
      'universities': [
        {'id': 'polito', 'name': 'Politecnico di Torino', 'shortName': 'PoliTo'},
      ],
      'courses': [
        {
          'externalId': 'polito:course:X',
          'universityId': 'polito',
          'name': name,
          'code': code,
          'cfu': 8,
        },
      ],
    };

    Future<Map<String, Object?>> riga() async =>
        (await db.db.query('courses')).single;

    setUp(() async {
      db = await AppDatabase.openInMemory();
      importer = DataPackImporter(db);
    });
    tearDown(() => db.close());

    test('un insegnamento non modificato prende il nome nuovo', () async {
      await importer.importMap(pack('Analisi I (10 CFU) (01AAA)'), exclusionPatterns: const []);
      await importer.importMap(pack('Analisi I'), exclusionPatterns: const []);
      expect((await riga())['name'], 'Analisi I');
    });

    test('modificato dallo studente: il nome ufficiale perde CFU e codice, '
        'il nome scelto resta', () async {
      await importer.importMap(pack('Analisi I (10 CFU) (01AAA)'), exclusionPatterns: const []);
      await db.db.update('courses', {
        'user_edited': 1,
        'teacher': 'Docente scelto',
        'custom_name': 'Analisi uno',
      });
      await importer.importMap(pack('Analisi I'), exclusionPatterns: const []);
      final c = await riga();
      expect(c['name'], 'Analisi I');
      expect(c['custom_name'], 'Analisi uno');
      expect(c['teacher'], 'Docente scelto');
    });

    test('modificato dallo studente con un nome suo nella colonna del nome: '
        'non si tocca', () async {
      await importer.importMap(pack('Analisi I'), exclusionPatterns: const []);
      await db.db.update('courses', {'user_edited': 1, 'name': 'Analisi (6 CFU) mia'});
      await importer.importMap(pack('Analisi I'), exclusionPatterns: const []);
      expect((await riga())['name'], 'Analisi (6 CFU) mia');
    });

    test('modificato dallo studente, omonimo nel database: tiene «(N CFU)»', () async {
      await importer.importMap(pack('Inglese (6 CFU) (01AAA)'), exclusionPatterns: const []);
      await db.db.update('courses', {'user_edited': 1});
      await importer.importMap(pack('Inglese (6 CFU)'), exclusionPatterns: const []);
      expect((await riga())['name'], 'Inglese (6 CFU)');
    });

    test('versione in inglese: il nome della variante perde CFU e codice', () async {
      await importer.importMap(pack('Diritto commerciale'), exclusionPatterns: const []);
      await db.db.update('courses', {
        'exam_language': 'en',
        'name': 'Business law (8 CFU) (03KYJYC)',
        'code': '03KYJYC',
      });
      await importer.importMap(pack('Diritto commerciale'), exclusionPatterns: const []);
      final c = await riga();
      expect(c['name'], 'Business law');
      expect(c['code'], '03KYJYC');
    });
  });
}
