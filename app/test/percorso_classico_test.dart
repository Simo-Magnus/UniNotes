import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/curricula.dart';

CorsoDettaglio _corso(
  Map<String, Object?>? classico,
) => CorsoDettaglio.fromJson({
  'id': 'polito-l-8',
  'nome': 'Ingegneria informatica',
  'tipo': 'L',
  'percorso_classico': ?classico,
  'insegnamenti': [
    // il percorso speciale ha più insegnamenti di quello classico
    for (var i = 0; i < 5; i++)
      {'id': 'g$i', 'nome': 'Talento $i', 'curriculum': 'Grow Your Talents'},
    {'id': 'a', 'nome': 'Analisi', 'curriculum': 'Percorso, Grow Your Talents'},
    {'id': 'b', 'nome': 'Reti', 'curriculum': 'Percorso'},
  ],
})!;

void main() {
  test('percorso classico dal database: per primo e già scelto', () {
    final ps = PercorsiCorso.di(
      _corso({'nome': 'Percorso', 'criterio': 'nome'}),
    );
    expect(ps.scelte, ['Percorso', 'Grow Your Talents']);
    expect(ps.predefinito, 'Percorso');
    expect(ps.valido(null), 'Percorso');
    expect(ps.etichetta('Percorso'), 'Percorso classico');
    expect(ps.etichetta('Grow Your Talents'), 'Grow Your Talents');
    final nomi = [
      for (final i in soloPercorso(
        _corso({'nome': 'Percorso', 'criterio': 'nome'}),
        null,
      ).insegnamenti)
        i.nome,
    ];
    expect(nomi, ['Analisi', 'Reti']);
  });

  test('altri nomi: «(percorso classico)» accanto al nome', () {
    final ps = PercorsiCorso.di(
      _corso({'nome': 'Percorso', 'criterio': 'unico_ordinario'}),
    );
    expect(ps.classico, isTrue);
    expect(
      const PercorsiCorso([
        'GENERALE',
        'APPLICATIVO',
      ], classico: true).etichetta('GENERALE'),
      'GENERALE (percorso classico)',
    );
  });

  test('percorsi tematici o senza indicazione: il principale', () {
    final tematico = PercorsiCorso.di(
      _corso({'nome': 'Percorso', 'criterio': 'piu_insegnamenti'}),
    );
    expect(tematico.predefinito, 'Percorso');
    expect(tematico.etichetta('Percorso'), 'Percorso (principale)');
    // senza indicazione (o con un nome che non c'è): quello con più
    // insegnamenti, come prima
    for (final c in [
      _corso(null),
      _corso({'nome': 'Altro', 'criterio': 'nome'}),
    ]) {
      final ps = PercorsiCorso.di(c);
      expect(ps.predefinito, 'Grow Your Talents');
      expect(ps.classico, isFalse);
    }
  });
}
