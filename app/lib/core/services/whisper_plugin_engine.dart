import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_ggml/whisper_ggml.dart' as wg;

import 'whisper_service.dart';

/// Whisper dentro l'app (pacchetto `whisper_ggml`, whisper.cpp v1.9 incluso,
/// licenza MIT) per Android, iOS e, se manca `whisper-cli`, macOS.
///
/// Le lezioni durano ore: whisper.cpp tiene in memoria tutto l'audio
/// (3 h a 16 kHz ≈ 700 MB), troppo per un telefono. Per questo l'audio viene
/// prima convertito e diviso con ffmpeg in pezzi WAV da [chunk] e trascritto
/// un pezzo alla volta, tenendo il modello caricato tra un pezzo e l'altro;
/// gli orari dei segmenti vengono riportati alla registrazione intera.
class WhisperPluginEngine implements WhisperEngine {
  WhisperPluginEngine({this.chunk = const Duration(minutes: 10)});

  final Duration chunk;

  @override
  String get name => 'whisper.cpp nell\'app';

  @override
  Future<List<WhisperSegment>> transcribe(
    File audio,
    File model, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
  }) async {
    final tmp = await Directory.systemTemp.createTemp('whisper_chunks_');
    try {
      onProgress?.call(const WhisperProgress('Preparo l\'audio…', null));
      final pattern = p.join(tmp.path, 'parte_%03d.wav');
      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-i',
        audio.path,
        '-ar',
        '16000',
        '-ac',
        '1',
        '-c:a',
        'pcm_s16le',
        '-f',
        'segment',
        '-segment_time',
        '${chunk.inSeconds}',
        pattern,
      ]);
      if (!ReturnCode.isSuccess(await session.getReturnCode())) {
        final log = (await session.getOutput())?.trim() ?? '';
        throw WhisperException(
          'Conversione dell\'audio non riuscita'
          '${log.isEmpty ? '' : ': ${log.split('\n').last}'}',
        );
      }
      final parts =
          tmp
              .listSync()
              .whereType<File>()
              .where((f) => p.basename(f.path).startsWith('parte_'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (parts.isEmpty) {
        throw WhisperException('Audio vuoto o non leggibile.');
      }
      final whisper = const wg.Whisper(model: wg.WhisperModel.base);
      final out = <WhisperSegment>[];
      final threads = math.max(1, math.min(Platform.numberOfProcessors - 1, 8));
      try {
        for (var i = 0; i < parts.length; i++) {
          if (cancel?.isCancelled ?? false) throw DownloadCancelled();
          final offset = chunk * i;
          void report(int pct) {
            final overall = (i + pct / 100) / parts.length;
            onProgress?.call(
              WhisperProgress(
                'Trascrizione con Whisper: ${(overall * 100).round()}% '
                '(parte ${i + 1} di ${parts.length})',
                overall,
              ),
            );
          }

          report(0);
          final res = await whisper.transcribe(
            transcribeRequest: wg.TranscribeRequest(
              audio: parts[i].path,
              language: 'it',
              threads: threads,
              isNoTimestamps: false,
              keepModelLoaded: i < parts.length - 1,
            ),
            modelPath: model.path,
            onProgress: report,
          );
          for (final s
              in res.segments ?? const <wg.WhisperTranscribeSegment>[]) {
            final text = s.text.trim();
            if (text.isEmpty) continue;
            out.add(
              WhisperSegment(offset + s.fromTs, text, end: offset + s.toTs),
            );
          }
          await parts[i].delete();
        }
      } finally {
        try {
          await whisper.releaseModel();
        } catch (_) {
          // nessun modello in memoria
        }
      }
      return out;
    } on WhisperException {
      rethrow;
    } on DownloadCancelled {
      throw WhisperException('Trascrizione annullata.');
    } catch (e) {
      throw WhisperException('Whisper non è riuscito a trascrivere: $e');
    } finally {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    }
  }
}

/// Trascrizione dal vivo con whisper.cpp dentro l'app (il modello dal vivo
/// su tutti i sistemi, anche Windows; il modello dell'utente su telefono e
/// Mac senza `whisper-cli`): ogni pezzo gira in un isolate separato
/// (whisper_ggml) e il modello resta in memoria fra un pezzo e l'altro.
/// Pochi thread, per non togliere tempo di calcolo alla registrazione.
///
/// Su Windows e Linux whisper_ggml prova a convertire l'audio con un
/// `ffmpeg` nel PATH; se non c'è usa il file così com'è, che qui è già un
/// WAV mono a 16 kHz.
class PluginLiveWhisper extends LiveWhisper {
  PluginLiveWhisper(this._model, this.modelId);
  final File _model;
  @override
  final String modelId;
  final _whisper = const wg.Whisper(model: wg.WhisperModel.base);

  @override
  Future<List<WhisperSegment>> transcribeWav(File wav16k) async {
    try {
      final res = await _whisper.transcribe(
        transcribeRequest: wg.TranscribeRequest(
          audio: wav16k.path,
          language: 'it',
          threads: math.max(
            1,
            math.min(Platform.numberOfProcessors ~/ 2, quick ? 4 : 3),
          ),
          isNoTimestamps: false,
          // ogni finestra si trascrive da sola: il testo della precedente
          // non deve condizionarla (si ripeterebbe)
          noContext: true,
          keepModelLoaded: true,
        ),
        modelPath: _model.path,
      );
      return [
        for (final s in res.segments ?? const <wg.WhisperTranscribeSegment>[])
          if (s.text.trim().isNotEmpty)
            WhisperSegment(s.fromTs, s.text.trim(), end: s.toTs),
      ];
    } finally {
      // whisper_ggml converte il pezzo in «<nome>.wav» accanto all'originale
      final converted = File('${wav16k.path}.wav');
      try {
        if (await converted.exists()) await converted.delete();
      } catch (_) {}
    }
  }

  @override
  Future<void> close() async {
    try {
      await _whisper.releaseModel();
    } catch (_) {
      // nessun modello in memoria
    }
  }
}
