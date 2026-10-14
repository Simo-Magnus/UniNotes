import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/catalog_search.dart';

import 'support/catalog_fixtures.dart';

Object? _real(String name) =>
    jsonDecode(File('../database/$name').readAsStringSync());

void main() {
  group('universita.json', () {
    test('parsing della fixture', () {
      final u = UniversitaCatalog.fromJson(kUniversitaFixture);
      expect(u.universita, hasLength(5));
      final link = u.byId('unilink')!;
      expect(link.tipo, TipoAteneo.nonStatale);
      expect(link.regioni, ['Campania', 'Lazio']);
      expect(link.citta, ['Napoli', 'Roma']);
      expect(link.cittaIn('Lazio'), ['Roma']);
      expect(u.byId('unipegaso')!.regioni, isEmpty);
      expect(u.byId('polito')!.nomeBreve, 'PoliTO');
    });

    test('il file reale del MUR: 102 atenei', () {
      final u = UniversitaCatalog.fromJson(_real('universita.json'));
      expect(u.universita, hasLength(102));
      int count(TipoAteneo t) => u.universita.where((a) => a.tipo == t).length;
      expect(count(TipoAteneo.statale), 61);
      expect(count(TipoAteneo.nonStatale), 21);
      expect(count(TipoAteneo.ordinamentoSpeciale), 9);
      expect(count(TipoAteneo.telematica), 11);
      expect(u.conteggi['statale'], 61);
      expect(u.regioni, hasLength(20));
      // Id univoci, ogni ateneo non telematico ha almeno una regione.
      expect({for (final a in u.universita) a.id}, hasLength(102));
      for (final a in u.universita) {
        if (a.tipo == TipoAteneo.telematica) {
          expect(a.regioni, isEmpty, reason: a.id);
        } else {
          expect(a.regioni, isNotEmpty, reason: a.id);
        }
      }
      // Cattolica compare in tre regioni.
      expect(u.byId('unicatt')!.regioni, hasLength(3));
      expect(regioniPerTipo(u.universita, TipoAteneo.telematica), isEmpty);
      // Statali in 19 regioni: in Valle d'Aosta c'è solo un ateneo non statale.
      expect(regioniPerTipo(u.universita, TipoAteneo.statale), hasLength(19));
      expect(
        regioniPerTipo(u.universita, TipoAteneo.nonStatale),
        contains("Valle d'Aosta"),
      );
    });

    test('la copia negli asset è uguale a database/universita.json', () {
      expect(
        File('assets/database/universita.json').readAsStringSync(),
        File('../database/universita.json').readAsStringSync(),
      );
      // L'indice incluso è sempre valido (anche vuoto).
      IndiceCorsi.fromJson(
        jsonDecode(
          File('assets/database/indice_corsi.json').readAsStringSync(),
        ),
      );
    });

    test('formato più recente rifiutato con un messaggio', () {
      expect(
        () => UniversitaCatalog.fromJson({'schema': 2, 'universita': []}),
        throwsA(isA<CatalogFormatException>()),
      );
    });
  });

  test('indice_corsi.json: righe compatte e oggetti', () {
    final i = IndiceCorsi.fromJson({
      ...kIndiceFixture,
      'corsi': [
        ...kIndiceFixture['corsi'] as List,
        {
          'universita_id': 'unina',
          'id': 'unina-lmcu-medicina',
          'nome': 'Medicina e chirurgia',
          'tipo': 'LMCU',
          'classe': 'LM-41',
          'durata_anni': 6,
        },
        ['incompleto'],
      ],
    });
    expect(i.corsi, hasLength(5));
    final ing = i.corsi.first;
    expect(ing.ateneoId, 'polito');
    expect(ing.tipo, TipoCorso.l);
    expect(ing.classe, 'L-8');
    expect(ing.durataAnni, 3);
    expect(ing.lingua, 'it');
    expect(i.corsi.last.tipo, TipoCorso.lmcu);
    expect(i.corsi.last.durataAnni, 6);
    expect(i.ofAteneo('polito'), hasLength(2));
  });

  test('corsi/<id>.json: insegnamenti, libri, esami, stati', () {
    final f = CorsiAteneo.fromJson(corsiPolitoFixture());
    expect(f.universitaId, 'polito');
    final c = f.corso('polito-l8-ingegneria-informatica')!;
    expect(c.tipo, TipoCorso.l);
    expect(c.insegnamenti, hasLength(4));
    final analisi = c.insegnamenti.first;
    expect(analisi.cfu, 10);
    expect(analisi.docenti, ['Mario Rossi']);
    expect(analisi.libri.first.obbligatorio, isTrue);
    expect(analisi.libri.last.obbligatorio, isFalse);
    expect(analisi.esami.first.provaInItinere, isFalse);
    expect(analisi.esami.last.provaInItinere, isTrue);
    expect(analisi.esami.first.giorno, DateTime(2027, 1, 20));
    final fisica = c.insegnamenti[1];
    expect(fisica.statoLibri, StatoDati.daAggiungere);
    expect(fisica.libri, isEmpty);
    // Campi mancanti: stato "da_aggiungere", mai inventati.
    final algo = c.insegnamenti[2];
    expect(algo.periodo, isNull);
    expect(algo.esami, isEmpty);
    expect(algo.statoEsami, StatoDati.daAggiungere);
  });

  test('meta', () {
    final meta = DatabaseMeta.fromJson({
      'schema': 1,
      'anno_accademico': '2026/27',
      'versione': '2026.10.04',
      'atenei': {
        'polito': {
          'corsi': 120,
          'insegnamenti': 3400,
          'file': 'corsi/polito.json',
        },
      },
    });
    expect(meta.versione, '2026.10.04');
    expect(meta.atenei['polito']!.insegnamenti, 3400);
  });
}
