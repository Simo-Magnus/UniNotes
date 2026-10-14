import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/catalog_search.dart';

import 'support/catalog_fixtures.dart';

void main() {
  final real = UniversitaCatalog.fromJson(
    jsonDecode(File('../database/universita.json').readAsStringSync()),
  ).universita;
  final fixture = UniversitaCatalog.fromJson(kUniversitaFixture).universita;
  final indice = IndiceCorsi.fromJson(kIndiceFixture);

  List<String> ids(String q) => [for (final a in searchAtenei(real, q)) a.id];

  test('normalizzazione: accenti, virgolette, maiuscole', () {
    expect(normalizeText('Università “Ca’ Foscari”'), 'universita ca foscari');
    expect(normalizeText('  L\'Aquila  '), 'l aquila');
  });

  group('ricerca degli atenei (dati reali)', () {
    test('sigla e id: "polito"', () {
      expect(ids('polito').first, 'polito');
      expect(ids('PoliTO').first, 'polito');
      expect(ids('unito').first, 'unito');
    });

    test('nome: "bicocca" (anche con un errore)', () {
      expect(ids('bicocca').first, 'unimib');
      expect(ids('Bicoca').first, 'unimib');
    });

    test('città: "Napoli" trova tutti gli atenei di Napoli', () {
      final r = ids('Napoli');
      for (final id in ['unina', 'unior', 'uniparthenope', 'unisob', 'ssm']) {
        expect(r, contains(id));
      }
      expect(r, isNot(contains('polito')));
    });

    test('senza accenti e con parole comuni', () {
      expect(ids('universita di torino').first, 'unito');
      expect(ids('ca foscari').first, 'unive');
      expect(ids('cà foscàri'), contains('unive'));
      expect(ids('sapienza').first, 'uniroma1');
    });

    test('nessun risultato per testo senza senso', () {
      expect(ids('zzqqxx'), isEmpty);
      expect(ids(''), isEmpty);
    });
  });

  group('filtri dell\'onboarding', () {
    test('regioni per tipo: ateneo in più regioni compare in ciascuna', () {
      expect(regioniPerTipo(fixture, TipoAteneo.nonStatale), [
        'Campania',
        'Lazio',
      ]);
      expect(
        ateneiPer(fixture, TipoAteneo.nonStatale, regione: 'Lazio').single.id,
        'unilink',
      );
      expect(
        ateneiPer(
          fixture,
          TipoAteneo.nonStatale,
          regione: 'Campania',
        ).single.id,
        'unilink',
      );
    });

    test('telematiche senza regione', () {
      expect(tipoSenzaRegione(TipoAteneo.telematica), isTrue);
      expect(tipoSenzaRegione(TipoAteneo.statale), isFalse);
      expect(regioniPerTipo(fixture, TipoAteneo.telematica), isEmpty);
      expect(ateneiPer(fixture, TipoAteneo.telematica).single.id, 'unipegaso');
    });

    test('atenei statali per regione, in ordine alfabetico', () {
      expect(
        [for (final a in ateneiPer(fixture, TipoAteneo.statale)) a.id],
        ['polito', 'unimib', 'unina'],
      );
      expect(
        ateneiPer(fixture, TipoAteneo.statale, regione: 'Piemonte').single.id,
        'polito',
      );
    });

    test('tipi di laurea: solo quelli presenti, sempre "Altro"', () {
      expect(tipiCorsoDisponibili(indice, 'polito'), [
        TipoCorso.l,
        TipoCorso.lm,
        TipoCorso.altro,
      ]);
      // Ateneo senza corsi nell'indice: resta l'inserimento a mano.
      expect(tipiCorsoDisponibili(indice, 'unina'), [TipoCorso.altro]);
    });

    test('corsi per ateneo e tipo, con ricerca', () {
      expect(
        corsiPer(indice, 'polito', TipoCorso.l).single.nome,
        'Ingegneria Informatica',
      );
      expect(
        corsiPer(indice, 'polito', TipoCorso.lm, query: 'LM-32'),
        hasLength(1),
      );
      expect(
        corsiPer(indice, 'polito', TipoCorso.l, query: 'informatica'),
        hasLength(1),
      );
      expect(
        corsiPer(indice, 'polito', TipoCorso.l, query: 'medicina'),
        isEmpty,
      );
    });
  });
}
