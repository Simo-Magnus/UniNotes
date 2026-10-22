import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:university_notes/core/catalog/catalog_datapack.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/datapack_importer.dart';

import 'support/catalog_fixtures.dart';

/// File dei corsi malformati, troncati o con valori di tipo inatteso: i
/// modelli e l'import danno un errore chiaro (o saltano la voce), mai
/// un'eccezione di tipo che chiude la schermata (CRASH-1).
void main() {
  const corsoId = 'polito-l8-ingegneria-informatica';
  final weird = <Object? Function(Random)>[
    (_) => null,
    (_) => 0,
    (_) => -1,
    (_) => 1.5,
    (_) => 1 << 53,
    (_) => '',
    (_) => 'x',
    (_) => '2026-13-45',
    (_) => true,
    (_) => <Object?>[],
    (_) => <String, Object?>{},
    (_) => <Object?>[null, 1, 'a'],
    (_) => <String, Object?>{'id': null, 'nome': 3},
  ];

  /// Copia di [json] con un nodo a caso sostituito da un valore strano.
  Object? mutate(Object? json, Random r) {
    final copy = jsonDecode(jsonEncode(json));
    final nodes = <(Object, Object)>[];
    void walk(Object? n) {
      if (n is Map) {
        for (final k in n.keys) {
          nodes.add((n, k));
          walk(n[k]);
        }
      } else if (n is List) {
        for (var i = 0; i < n.length; i++) {
          nodes.add((n, i));
          walk(n[i]);
        }
      }
    }

    walk(copy);
    if (nodes.isEmpty) return weird[r.nextInt(weird.length)](r);
    for (var k = 0; k < 1 + r.nextInt(3); k++) {
      final (parent, key) = nodes[r.nextInt(nodes.length)];
      final v = weird[r.nextInt(weird.length)](r);
      if (parent is Map) {
        parent[key] = v;
      } else if (parent is List) {
        parent[key as int] = v;
      }
    }
    return copy;
  }

  bool expected(Object e) =>
      e is CatalogFormatException ||
      e is FormatException ||
      e is DataPackException;

  void fuzz(String name, Object? sample, void Function(Object? json) parse) {
    test('$name: 400 varianti malformate', () {
      final r = Random(name.hashCode);
      for (var i = 0; i < 400; i++) {
        final json = mutate(sample, r);
        try {
          parse(json);
        } catch (e, st) {
          if (!expected(e)) {
            fail('Variante $i: ${e.runtimeType} $e\n$st\n${jsonEncode(json)}');
          }
        }
      }
    });
  }

  Object? asset(String name) =>
      jsonDecode(File('assets/database/$name').readAsStringSync());

  group('modelli del catalogo', () {
    fuzz('universita (test)', kUniversitaFixture, UniversitaCatalog.fromJson);
    fuzz('indice dei corsi (test)', kIndiceFixture, IndiceCorsi.fromJson);
    fuzz('corsi dell\'ateneo', corsiPolitoFixture(), (j) {
      final c = CorsiAteneo.fromJson(j);
      final corso = c.corso(corsoId);
      if (corso != null) corso.insegnamenti.length;
    });
    fuzz('moduli', {
      'universita_id': 'polito',
      'insegnamenti': corsiPolitoFixture()['moduli'],
    }, ModuliAteneo.fromJson);
    fuzz('sessioni', {
      'universita_id': 'polito',
      'calendari': [
        {
          'ambito': 'Ateneo',
          'corsi': [corsoId],
          'sessioni': [
            {'nome': 'Invernale', 'inizio': '2027-01-11', 'fine': '2027-02-20'},
          ],
        },
      ],
    }, (j) => SessioniAteneo.fromJson(j).per(corsoId));
    fuzz('meta.json incluso', asset('meta.json'), DatabaseMeta.fromJson);
    fuzz(
      'corsi_sostituiti.json incluso',
      asset('corsi_sostituiti.json'),
      CorsiSostituiti.fromJson,
    );

    test('file troncati a ogni lunghezza: solo errori di formato', () {
      final text = jsonEncode(corsiPolitoFixture());
      for (var n = 0; n < text.length; n += 37) {
        try {
          CorsiAteneo.fromJson(jsonDecode(text.substring(0, n)));
        } catch (e) {
          expect(expected(e), isTrue, reason: '$n: ${e.runtimeType} $e');
        }
      }
    });
  });

  group('import del piano', () {
    setUpAll(sqfliteFfiInit);

    test('data pack con valori di tipo inatteso: import o errore chiaro, '
        'database coerente', () async {
      final ateneo = UniversitaCatalog.fromJson(kUniversitaFixture)
          .byId('polito')!;
      final corso = CorsiAteneo.fromJson(corsiPolitoFixture()).corso(corsoId)!;
      final pack = catalogToDataPack(
        ateneo: ateneo,
        corso: corso,
        now: DateTime(2026, 10, 1),
      );
      pack['removeBooks'] = ['x'];
      pack['removeEventsOfSources'] = ['vecchia'];
      final db = await AppDatabase.openInMemory();
      final importer = DataPackImporter(db);
      final r = Random(42);
      for (var i = 0; i < 150; i++) {
        final json = mutate(pack, r);
        try {
          await importer.importMap(
            json is Map<String, Object?> ? json : {'format': json},
            exclusionPatterns: const [],
          );
        } catch (e, st) {
          if (!expected(e)) {
            fail('Variante $i: ${e.runtimeType} $e\n$st');
          }
        }
      }
      await db.close();
    });

    test('fonti sostituite salvate illeggibili: l\'import va avanti', () async {
      final db = await AppDatabase.openInMemory();
      await db.db.insert('app_settings', {
        'key': 'retired_event_sources',
        'value': '{non json',
      });
      final report = await DataPackImporter(db).importMap({
        'format': 'university-manager-datapack',
        'version': 1,
        'removeBooks': 'non una lista',
        'events': [
          {'externalId': 'e', 'title': 'Lezione', 'start': '2026-10-05T08:30'},
        ],
      }, exclusionPatterns: const []);
      expect(report.events, 1);
      await db.close();
    });
  });
}
