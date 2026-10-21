import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/services/parakeet_engine.dart';
import 'package:university_notes/features/notes/recorder/vad_segmenter.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';

/// Prova con il modello vero (sherpa-onnx, FFI): solo se la variabile
/// d'ambiente PARAKEET_MODEL_DIR indica la cartella con i file del modello e
/// PARAKEET_TEST_WAV un WAV mono a 16 kHz con parlato italiano. Misura
/// anche i tempi (stampati). Su Windows SHERPA_ONNX_LIB_DIR indica la
/// cartella `windows` del pacchetto sherpa_onnx_windows nella cache di pub.
void main() {
  final dir = Platform.environment['PARAKEET_MODEL_DIR'];
  final wavPath = Platform.environment['PARAKEET_TEST_WAV'];
  final skip = dir == null || wavPath == null
      ? 'PARAKEET_MODEL_DIR e PARAKEET_TEST_WAV non impostate'
      : null;

  test('Parakeet vero: frasi dal vivo con il VAD', () async {
    final w = await ParakeetWorker.start(
      ParakeetPaths(
        encoder: p.join(dir!, 'encoder.int8.onnx'),
        decoder: p.join(dir, 'decoder.int8.onnx'),
        joiner: p.join(dir, 'joiner.int8.onnx'),
        tokens: p.join(dir, 'tokens.txt'),
        vad: p.join(Directory.current.path, 'assets', 'vad', 'silero_vad.onnx'),
        // DLL del pacchetto sherpa_onnx_windows (nell'app sono accanto
        // all'eseguibile)
        libDir: Platform.environment['SHERPA_ONNX_LIB_DIR'],
      ),
    );
    addTearDown(w.dispose);
    final f = File(wavPath!);
    final info = (await readWavInfo(f))!;
    final mono = toMono16k(
      await readWavRange(f, info, Duration.zero, info.duration),
      info.sampleRate,
      info.channels,
    );
    final audio = int16ToFloat(mono);
    await w.open(1);
    final out = <String>[];
    var partials = 0;
    final took = <int>[];
    final sw = Stopwatch()..start();
    for (var i = 0; i < audio.length; i += 1600) {
      final end = i + 1600 < audio.length ? i + 1600 : audio.length;
      final step = await w.feed(1, i, Float32List.sublistView(audio, i, end));
      if (step.partial?.isNotEmpty ?? false) partials++;
      if (step.committed.isNotEmpty || (step.partial?.isNotEmpty ?? false)) {
        took.add(step.took.inMilliseconds);
      }
      for (final s in step.committed) {
        out.add('[${s.start.inMilliseconds}-${s.end.inMilliseconds}] ${s.text}');
      }
    }
    for (final s in (await w.flush(1)).committed) {
      out.add('[${s.start.inMilliseconds}-${s.end.inMilliseconds}] ${s.text}');
    }
    final total = sw.elapsedMilliseconds;
    took.sort();
    // ignore: avoid_print
    print(
      'Parakeet: ${out.length} frasi, $partials provvisori, passo con testo '
      'mediano ${took.isEmpty ? 0 : took[took.length ~/ 2]} ms, massimo '
      '${took.isEmpty ? 0 : took.last} ms; ${info.duration.inSeconds} s di '
      'audio in $total ms (fattore ${(total / info.duration.inMilliseconds).toStringAsFixed(3)})',
    );
    // ignore: avoid_print
    out.forEach(print);
    expect(out, isNotEmpty);
    expect(partials, greaterThan(0));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
}
