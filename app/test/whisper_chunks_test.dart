import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/services/whisper_chunks.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';

/// WAV 16 kHz mono: tratti di «parlato» (rumore forte) e pause (silenzio
/// con un po' di fondo), in secondi.
Future<File> _wav(Directory dir, List<(bool, double)> parts) =>
    _wavAmp(dir, [for (final (loud, s) in parts) (loud ? 8000 : 30, s)]);

/// Come [_wav], con l'ampiezza di ogni tratto.
Future<File> _wavAmp(Directory dir, List<(int, double)> parts) async {
  final rnd = math.Random(1);
  final out = <int>[];
  for (final (amp, s) in parts) {
    for (var i = 0; i < (s * 16000).round(); i++) {
      out.add(((rnd.nextDouble() * 2 - 1) * amp).round());
    }
  }
  return writeWav16k(File(p.join(dir.path, 'a.wav')), Int16List.fromList(out));
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('chunks_'));
  tearDown(() async => tmp.delete(recursive: true));

  group('pezzi alle pause', () {
    test('tagli al centro delle pause, mai oltre 25 s', () async {
      // 12 frasi da 6 s con pause da 1 s: 90 s in tutto
      final f = await _wav(tmp, [
        for (var i = 0; i < 12; i++) ...[(true, 6.0), (false, 1.0)],
        (true, 6.0),
      ]);
      final info = (await readWavInfo(f))!;
      final plan = planChunks(await frameLevels(f, info), info.duration);
      expect(plan.first.start, Duration.zero);
      expect(plan.last.end, info.duration);
      for (var i = 0; i < plan.length; i++) {
        final c = plan[i];
        expect(c.end - c.start, lessThanOrEqualTo(kWhisperChunkMax));
        expect(c.speech, isTrue);
        if (i > 0) expect(c.start, plan[i - 1].end);
        if (i < plan.length - 1) {
          // il taglio cade in una pausa: 6 s di frase + 0,5 s di pausa
          final s = c.end.inMilliseconds / 1000;
          expect((s - 6.5) % 7, closeTo(0, 0.1), reason: 'taglio a $s s');
        }
      }
    });

    test('senza pause il taglio cade fra 15 e 25 s; il silenzio non va a '
        'Whisper', () async {
      final f = await _wav(tmp, [(true, 60.0), (false, 30.0)]);
      final info = (await readWavInfo(f))!;
      final plan = planChunks(await frameLevels(f, info), info.duration);
      for (var i = 0; i < plan.length; i++) {
        final c = plan[i];
        expect(c.end - c.start, lessThanOrEqualTo(kWhisperChunkMax));
        if (i > 0) expect(c.start, plan[i - 1].end);
      }
      expect(
        plan[0].end.inMilliseconds,
        inInclusiveRange(15000, kWhisperChunkMax.inMilliseconds),
      );
      // il parlato finisce a 60 s: taglio a 60,3 s, poi solo silenzio
      final talk = [
        for (final c in plan)
          if (c.speech) c,
      ];
      expect(talk.last.end, const Duration(milliseconds: 60300));
      expect(plan.last.end, info.duration);
      expect(plan.last.speech, isFalse);
      expect(planChunks(Float64List(0), Duration.zero), isEmpty);
    });

    test(
      'senza pause il taglio cade fra due parole (punto più basso)',
      () async {
        // 40 s di parlato con un attimo più basso (0,2 s: non una pausa) a 20 s
        final f = await _wav(tmp, [(true, 20.0), (false, 0.2), (true, 20.0)]);
        final info = (await readWavInfo(f))!;
        final plan = planChunks(await frameLevels(f, info), info.duration);
        expect(plan, hasLength(2));
        expect(plan[0].end.inMilliseconds, closeTo(20100, 100));
      },
    );

    test('pause lunghe: sempre tagliate, ai due lati, e saltate se sono '
        'silenzio', () async {
      // 9 s di silenzio all'inizio, due frasi separate da 5 s di silenzio
      final f = await _wav(tmp, [
        (false, 9.0),
        (true, 4.0),
        (false, 0.5),
        (true, 4.0),
        (false, 5.0),
        (true, 8.0),
      ]);
      final info = (await readWavInfo(f))!;
      final plan = planChunks(await frameLevels(f, info), info.duration);
      String ms(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(1);
      expect(
        [for (final c in plan) '${ms(c.start)}-${ms(c.end)} ${c.speech}'],
        [
          '0.0-8.7 false',
          // la pausa breve (0,5 s) resta dentro il pezzo
          '8.7-17.8 true',
          '17.8-22.2 false',
          '22.2-30.5 true',
        ],
      );
      // una domanda dal fondo dell'aula (15 dB sotto) è una «pausa» lunga,
      // ma va a Whisper, da sola
      final q = await _wavAmp(tmp, [(8000, 8.0), (1400, 5.0), (8000, 8.0)]);
      final qi = (await readWavInfo(q))!;
      final qp = planChunks(await frameLevels(q, qi), qi.duration);
      expect(
        [for (final c in qp) '${ms(c.start)}-${ms(c.end)} ${c.speech}'],
        ['0.0-8.3 true', '8.3-12.7 true', '12.7-21.0 true'],
      );
    });
  });

  test('parlato quasi senza pause: nessun pezzo saltato', () async {
    // il fondo del file (10% delle finestre) qui è il parlato stesso
    final f = await _wav(tmp, [
      for (var i = 0; i < 10; i++) ...[(true, 20.0), (false, 0.4)],
    ]);
    final info = (await readWavInfo(f))!;
    final plan = planChunks(await frameLevels(f, info), info.duration);
    expect(plan.length, greaterThan(5));
    expect(plan.every((c) => c.speech), isTrue);
  });

  group('cicli e frasi del silenzio', () {
    test('testo a ciclo riconosciuto e ripulito', () {
      final loop =
          'Come ci sono? Non è un costo. ${List.filled(20, 'Non è un\'imposte.').join(' ')}';
      expect(looksLooped(loop), isTrue);
      expect(
        withoutLoops(loop),
        'Come ci sono? Non è un costo. Non è un\'imposte.',
      );
      const commas =
          'Iniziamo a vedere la sua vita, la sua vita è stata un\'occhiata, e '
          'la sua vita è stata un\'occhiata, e la sua vita è stata '
          'un\'occhiata, e la sua vita è stata un\'occhiata.';
      expect(looksLooped(commas), isTrue);
      expect(
        withoutLoops(commas).split('occhiata').length - 1,
        lessThanOrEqualTo(2),
      );
    });

    test('il testo normale di una lezione non è a ciclo', () {
      for (final t in [
        'Il limite di una funzione esiste se il limite destro e il limite '
            'sinistro esistono e sono uguali. Vediamo un esempio con il limite '
            'di x che tende a zero.',
        'Allora, ragazzi, oggi vediamo la derivata. La derivata è il limite '
            'del rapporto incrementale, cioè il limite per h che tende a zero.',
        'Corto.',
      ]) {
        expect(looksLooped(t), isFalse, reason: t);
        expect(withoutLoops(t), t);
      }
    });

    test('frasi del silenzio tolte solo come frasi intere', () {
      expect(withoutFillers('Grazie. Grazie. Grazie a tutti.'), isEmpty);
      expect(withoutFillers('...'), isEmpty);
      expect(
        withoutFillers('Grazie. Allora, oggi vediamo i limiti.'),
        'Allora, oggi vediamo i limiti.',
      );
      expect(
        withoutFillers('Grazie a Newton abbiamo il calcolo.'),
        'Grazie a Newton abbiamo il calcolo.',
      );
    });
  });

  group('segmenti lunghi divisi', () {
    // token come li scrive whisper-cli con -ojf (tempi in ms)
    List<WhisperToken> toks(List<(String, int, int)> t) => [
      for (final (s, a, b) in t)
        WhisperToken(s, Duration(milliseconds: a), Duration(milliseconds: b)),
    ];

    test('alle fine delle frasi, con i tempi dei token', () {
      final seg = WhisperSegment(
        const Duration(seconds: 47),
        'Io so bene chi è stato. Apple ha rilasciato la roba? Sì.',
        end: const Duration(seconds: 65),
        tokens: toks([
          ('[_BEG_]', 47000, 47000),
          (' Io', 47000, 47200),
          (' so', 47200, 47400),
          (' bene', 47400, 47800),
          (' chi', 47800, 48000),
          (' è', 48000, 48100),
          (' st', 48100, 48300),
          ('ato', 48300, 48600),
          ('.', 48600, 48700),
          (' Apple', 54300, 54800),
          (' ha', 54800, 55000),
          (' rilasciato', 55000, 56000),
          (' la', 56000, 56100),
          (' roba', 56100, 56500),
          ('?', 56500, 56600),
          (' Sì', 64000, 64500),
          ('.', 64500, 64900),
          ('[_TT_900]', 65000, 65000),
        ]),
      );
      final out = splitSentences([seg]);
      expect(
        [
          for (final s in out)
            '${s.start.inMilliseconds}-${s.end!.inMilliseconds} ${s.text}',
        ],
        [
          '47000-48700 Io so bene chi è stato.',
          '48700-56600 Apple ha rilasciato la roba?',
          '56600-65000 Sì.',
        ],
      );
      expect(out[1].tokens.first.text, ' Apple');
      // un segmento con una frase sola resta com'è
      final one = WhisperSegment(
        Duration.zero,
        'Bene, tutto bene.',
        end: const Duration(seconds: 2),
      );
      expect(splitSentences([one]).single, same(one));
    });

    test('senza token i tempi sono stimati dai caratteri', () {
      final out = splitSentences([
        const WhisperSegment(
          Duration(seconds: 10),
          'Prima frase. Seconda frase.',
          end: Duration(seconds: 20),
        ),
      ]);
      expect([for (final s in out) s.text], ['Prima frase.', 'Seconda frase.']);
      expect(out[0].start, const Duration(seconds: 10));
      // «Prima frase.» sono 12 caratteri su 27
      expect(out[0].end!.inMilliseconds, closeTo(14444, 5));
      expect(out[1].start, out[0].end);
      expect(out[1].end, const Duration(seconds: 20));
      // i numeri con il punto non sono fine di frase
      expect(
        splitSentences([
          const WhisperSegment(
            Duration.zero,
            'Costa 2.5 euro al chilo.',
            end: Duration(seconds: 3),
          ),
        ]),
        hasLength(1),
      );
    });

    test('una frase oltre 10 s si divide alle virgole, poi fra le parole', () {
      final words = [
        for (var i = 0; i < 30; i++) 'parola$i${i % 10 == 9 ? ',' : ''}',
      ];
      final out = splitSentences([
        WhisperSegment(
          Duration.zero,
          '${words.join(' ')}.',
          end: const Duration(seconds: 24),
        ),
      ]);
      expect(out.length, greaterThan(1));
      for (final s in out) {
        expect(s.end! - s.start, lessThanOrEqualTo(kWhisperSentenceMax));
      }
      expect(out.first.text, endsWith('parola9,'));
      expect(out.map((s) => s.text).join(' '), '${words.join(' ')}.');
      // senza virgole né punti: fra le parole, oltre 15 s
      final flat = splitSentences([
        WhisperSegment(
          Duration.zero,
          List.filled(40, 'bla').join(' '),
          end: const Duration(seconds: 20),
        ),
      ]);
      expect(flat.length, greaterThan(1));
      for (final s in flat) {
        expect(s.end! - s.start, lessThanOrEqualTo(kWhisperSentenceMax));
      }
      expect(
        flat.map((s) => s.text).join(' '),
        List.filled(40, 'bla').join(' '),
      );
    });

    test('parseSegments legge i token di -ojf', () {
      final segs = WhisperService.parseSegments(
        '{"transcription":[{"offsets":{"from":0,"to":2000},'
        '"text":" Ciao. Oggi.","tokens":['
        '{"text":"[_BEG_]","offsets":{"from":0,"to":0}},'
        '{"text":" Ciao","offsets":{"from":0,"to":500}},'
        '{"text":".","offsets":{"from":500,"to":600}},'
        '{"text":" Oggi","offsets":{"from":1200,"to":1800}},'
        '{"text":".","offsets":{"from":1800,"to":2000}}]}]}',
      );
      expect(segs.single.tokens, hasLength(5));
      expect(segs.single.tokens.first.special, isTrue);
      final out = splitSentences(segs);
      expect([for (final s in out) s.end!.inMilliseconds], [600, 2000]);
    });
  });

  group('transcribeInChunks', () {
    test('tempi della registrazione, pezzo a ciclo ritrascritto a metà, '
        'silenzio saltato', () async {
      final f = await _wav(tmp, [
        (true, 10.0),
        (false, 1.0),
        (true, 10.0),
        (false, 1.0),
        (true, 10.0),
        (false, 30.0),
      ]);
      final info = (await readWavInfo(f))!;
      final calls = <int>[];
      var call = 0;
      Future<List<List<WhisperSegment>>> run(
        List<File> parts,
        void Function(double) report,
      ) async {
        calls.add(parts.length);
        call++;
        report(1);
        return [
          for (var i = 0; i < parts.length; i++)
            if (call == 1 && i == 1)
              // il secondo pezzo esce a ciclo
              [
                WhisperSegment(
                  const Duration(seconds: 1),
                  List.filled(10, 'Non è un\'imposte.').join(' '),
                ),
              ]
            else
              [
                WhisperSegment(
                  const Duration(seconds: 1),
                  'Frase $call.$i. Grazie.',
                  end: const Duration(seconds: 4),
                ),
              ],
        ];
      }

      final progress = <double?>[];
      final segs = await transcribeInChunks(
        f,
        info,
        tmp,
        run,
        onProgress: (w) => progress.add(w.fraction),
      );
      // 2 pezzi con parlato (il silenzio finale no), poi le due metà
      expect(calls, [2, 2]);
      expect(
        [for (final s in segs) s.text],
        ['Frase 1.0.', 'Frase 2.0.', 'Frase 2.1.'],
      );
      expect(segs.first.start, const Duration(seconds: 1));
      // seconda metà del pezzo a ciclo: tempo spostato di metà pezzo
      expect(segs[2].start, greaterThan(segs[1].start));
      for (final s in segs) {
        expect(s.end!, lessThanOrEqualTo(info.duration));
      }
      expect(progress.whereType<double>().last, 1.0);
      // i WAV dei pezzi non restano
      expect(tmp.listSync().whereType<File>().map((e) => p.basename(e.path)), [
        'a.wav',
      ]);
    });

    test('pezzo corto fra due pause lunghe allungato a 1,5 s; frasi divise '
        'e tempi della registrazione', () async {
      final f = await _wav(tmp, [
        (false, 5.0),
        (true, 0.6),
        (false, 5.0),
        (true, 8.0),
      ]);
      final info = (await readWavInfo(f))!;
      final lengths = <Duration>[];
      final segs = await transcribeInChunks(f, info, tmp, (parts, _) async {
        for (final part in parts) {
          lengths.add((await readWavInfo(part))!.duration);
        }
        return [
          for (final _ in parts)
            [
              WhisperSegment(
                Duration.zero,
                'Sì. Allora, vediamo.',
                end: const Duration(seconds: 1),
              ),
            ],
        ];
      });
      // il «Sì» (0,6 s + i margini) e la frase di 8 s
      expect(lengths, hasLength(2));
      expect(lengths[0], const Duration(milliseconds: 1500));
      expect(lengths[1].inMilliseconds, closeTo(8300, 50));
      expect(
        [for (final s in segs) s.text],
        ['Sì.', 'Allora, vediamo.', 'Sì.', 'Allora, vediamo.'],
      );
      // il secondo pezzo comincia a 10,6 − 0,3 s
      expect(segs[2].start.inMilliseconds, closeTo(10300, 30));
    });

    test('annullata fra un gruppo e l\'altro', () async {
      final f = await _wav(tmp, [
        for (var i = 0; i < 30; i++) ...[(true, 20.0), (false, 1.0)],
      ]);
      final info = (await readWavInfo(f))!;
      final cancel = CancelToken();
      await expectLater(
        transcribeInChunks(f, info, tmp, (parts, _) async {
          cancel.cancel();
          return [for (final _ in parts) const <WhisperSegment>[]];
        }, cancel: cancel),
        throwsA(isA<DownloadCancelled>()),
      );
    });
  });
}
