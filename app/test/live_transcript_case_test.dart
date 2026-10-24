import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/live_transcript.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';

TranscriptSegment _seg(int s, String t) =>
    TranscriptSegment(Duration(seconds: s), Duration(seconds: s + 2), t);

List<String> _texts(TranscriptMerger m) => [
  for (final s in m.segments) s.text,
];

void main() {
  group('maiuscole a inizio pezzo (riconoscitore del telefono)', () {
    test('senza punto prima, l\'iniziale torna minuscola', () {
      final m = TranscriptMerger()
        ..add([_seg(0, 'Oggi parliamo')])
        ..add([_seg(2, 'Di integrali definiti.')])
        ..add([_seg(4, 'Poi passiamo alle serie')]);
      expect(_texts(m), [
        'Oggi parliamo',
        'di integrali definiti.',
        'Poi passiamo alle serie',
      ]);
    });

    test('dopo punto esclamativo, domanda e puntini la maiuscola resta', () {
      final m = TranscriptMerger()
        ..add([_seg(0, 'Attenzione!')])
        ..add([_seg(2, 'Questo è importante?')])
        ..add([_seg(4, 'Vediamo…')])
        ..add([_seg(6, 'Allora «Ripartiamo».')])
        ..add([_seg(8, 'Bene')]);
      expect(_texts(m), [
        'Attenzione!',
        'Questo è importante?',
        'Vediamo…',
        'Allora «Ripartiamo».',
        'Bene',
      ]);
    });

    test('nomi propri, sigle e parole con maiuscole interne restano', () {
      final m = TranscriptMerger()
        ..add([_seg(0, 'la serie di Fourier converge')])
        ..add([_seg(2, 'Fourier la usava per il calore')])
        ..add([_seg(4, 'PDF caricato su')])
        ..add([_seg(6, 'UniNotes ieri')]);
      expect(_texts(m), [
        'la serie di Fourier converge',
        'Fourier la usava per il calore',
        'PDF caricato su',
        'UniNotes ieri',
      ]);
    });

    test('lettere singole: «E» diventa «e», «I» resta solo in inglese', () {
      final it = TranscriptMerger()
        ..add([_seg(0, 'prendiamo la derivata')])
        ..add([_seg(2, 'E poi')])
        ..add([_seg(4, 'I limiti')]);
      expect(_texts(it), ['prendiamo la derivata', 'e poi', 'i limiti']);
      final en = TranscriptMerger()..english = true;
      en
        ..add([_seg(0, 'and then')])
        ..add([_seg(2, 'I think')]);
      expect(_texts(en), ['and then', 'I think']);
    });

    test('il primo pezzo e i segni prima della parola', () {
      final m = TranscriptMerger()
        ..add([_seg(0, 'Inizio della lezione')])
        ..add([_seg(2, '«Come dicevo')]);
      expect(_texts(m), ['Inizio della lezione', '«come dicevo']);
    });

    test('il vocabolario dell\'insegnamento protegge i nomi propri', () {
      final lt = LiveTranscriber(
        null,
        vocabulary: const ['Teorema di Lagrange', 'Analisi'],
      );
      lt.merger
        ..add([_seg(0, 'come dice il teorema')])
        ..add([_seg(2, 'Lagrange dimostra che')])
        ..add([_seg(4, 'Analisi')]);
      expect(_texts(lt.merger), [
        'come dice il teorema',
        'Lagrange dimostra che',
        'analisi',
      ]);
      lt.dispose();
    });

    test('nomi propri visti a metà frase', () {
      expect(
        midSentenceNames('Oggi Mario e Luca. Poi Roma, «Napoli» e PDF').toList(),
        ['mario', 'luca', 'roma', 'napoli'],
      );
    });
  });
}
