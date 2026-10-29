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
Future<File> _wav(Directory dir, List<(bool, double)> parts) async {
  final rnd = math.Random(1);
  final out = <int>[];
  for (final (loud, s) in parts) {
    for (var i = 0; i < (s * 16000).round(); i++) {
      out.add(((rnd.nextDouble() * 2 - 1) * (loud ? 8000 : 30)).round());
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

    test(
      'senza pause il taglio cade a 25 s; il silenzio non va a Whisper',
      () async {
        final f = await _wav(tmp, [(true, 60.0), (false, 30.0)]);
        final info = (await readWavInfo(f))!;
        final plan = planChunks(await frameLevels(f, info), info.duration);
        expect(plan[0].end, kWhisperChunkMax);
        expect(plan[1].end, kWhisperChunkMax * 2);
        expect([for (final c in plan) c.speech], [true, true, true, false]);
        expect(planChunks(Float64List(0), Duration.zero), isEmpty);
      },
    );
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
