import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_ggml/whisper_ggml.dart' as wg;

import '../../features/notes/recorder/wav.dart';
import 'audio_codec.dart';
import 'whisper_service.dart';

/// Whisper dentro l'app (pacchetto `whisper_ggml`, whisper.cpp v1.9 incluso,
/// licenza MIT) per Android, iOS e, se manca `whisper-cli`, macOS; su tutti
/// i sistemi (anche Windows) per il modello integrato.
///
/// Le lezioni durano ore: whisper.cpp tiene in memoria tutto l'audio
/// (3 h a 16 kHz ≈ 700 MB), troppo per un telefono. Per questo l'audio viene
/// prima convertito e diviso con ffmpeg in pezzi WAV da [chunk] e trascritto
/// un pezzo alla volta, tenendo il modello caricato tra un pezzo e l'altro;
/// gli orari dei segmenti vengono riportati alla registrazione intera. Su
/// Windows e Linux (niente ffmpeg nell'app) l'audio si converte in WAV con
/// gli strumenti del sistema (Media Foundation) e si divide in Dart.
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
    WhisperOptions options = WhisperOptions.none,
  }) async {
    final tmp = await Directory.systemTemp.createTemp('whisper_chunks_');
    try {
      onProgress?.call(const WhisperProgress('Preparo l\'audio…', null));
      final parts = Platform.isWindows || Platform.isLinux
          ? await _splitWav(audio, tmp)
          : await _splitFfmpeg(audio, tmp);
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
              language: options.whisperLanguage,
              threads: threads,
              isNoTimestamps: false,
              keepModelLoaded: i < parts.length - 1,
              initialPrompt: options.prompt,
              suppressNonSpeechTokens: true,
              vadModelPath: options.vad?.path,
            ),
            modelPath: model.path,
            onProgress: report,
          );
          for (final s
              in res.segments ?? const <wg.WhisperTranscribeSegment>[]) {
            final text = s.text.trim();
            if (text.isEmpty || isPromptEcho(text, options.prompt)) continue;
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
      // un pezzo ancora bloccato non deve nascondere il risultato
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Pezzi WAV 16 kHz mono da [chunk] con ffmpeg dell'app (telefono, Mac).
  Future<List<File>> _splitFfmpeg(File audio, Directory tmp) async {
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
    return tmp
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('parte_'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  /// Pezzi WAV 16 kHz mono da [chunk] senza ffmpeg (Windows, Linux): i WAV
  /// si leggono direttamente, gli altri formati (.m4a, .flac…) si
  /// convertono prima con gli strumenti del sistema.
  Future<List<File>> _splitWav(File audio, Directory tmp) async {
    var wav = audio;
    var info = p.extension(audio.path).toLowerCase() == '.wav'
        ? await readWavInfo(audio)
        : null;
    if (info == null) {
      wav = File(p.join(tmp.path, 'audio.wav'));
      if (!await AudioCodec.instance.toWav(audio, wav)) {
        throw WhisperException(
          'Conversione dell\'audio non riuscita: prova a trascrivere con '
          'Gemini.',
        );
      }
      info = await readWavInfo(wav);
      if (info == null) throw WhisperException('Audio vuoto o non leggibile.');
    }
    final parts = <File>[];
    final total = info.duration;
    for (var k = 0; chunk * k < total; k++) {
      final start = chunk * k;
      final end = start + chunk < total ? start + chunk : total;
      final raw = await readWavRange(wav, info, start, end);
      if (raw.isEmpty) break;
      final mono = toMono16k(raw, info.sampleRate, info.channels);
      parts.add(
        await writeWav16k(
          File(p.join(tmp.path, 'parte_${'$k'.padLeft(3, '0')}.wav')),
          mono,
        ),
      );
    }
    if (!p.equals(wav.path, audio.path)) await wav.delete();
    return parts;
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
///
/// Con le [options]: vocabolario del corso come `initialPrompt`, Silero VAD
/// di whisper.cpp (i silenzi della finestra non vanno al modello: niente
/// frasi inventate) e soppressione dei token non verbali.
class PluginLiveWhisper extends LiveWhisper {
  PluginLiveWhisper(this._model, this.modelId);
  final File _model;
  @override
  final String modelId;
  final _whisper = const wg.Whisper(model: wg.WhisperModel.base);

  /// Modello tenuto in memoria fra un pezzo e l'altro (whisper.cpp ne tiene
  /// uno solo: la seconda passata con small non lo tiene, così il modello
  /// del testo istantaneo resta caricato).
  bool keepLoaded = true;

  /// Thread di calcolo (meno per la seconda passata).
  int? threads;

  @override
  Future<List<WhisperSegment>> transcribeWav(File wav16k) async {
    try {
      final res = await _whisper.transcribe(
        transcribeRequest: wg.TranscribeRequest(
          audio: wav16k.path,
          language: options.whisperLanguage,
          threads:
              threads ??
              math.max(
                1,
                math.min(Platform.numberOfProcessors ~/ 2, quick ? 4 : 3),
              ),
          isNoTimestamps: false,
          // ogni finestra si trascrive da sola: il testo della precedente
          // non deve condizionarla (si ripeterebbe)
          noContext: true,
          keepModelLoaded: keepLoaded,
          initialPrompt: options.prompt,
          suppressNonSpeechTokens: true,
          vadModelPath: options.vad?.path,
          // poco margine intorno al parlato: le finestre sono corte
          vadSpeechPadMs: options.vad == null ? null : 100,
        ),
        modelPath: _model.path,
      );
      return [
        for (final s in res.segments ?? const <wg.WhisperTranscribeSegment>[])
          if (s.text.trim().isNotEmpty && !isPromptEcho(s.text, options.prompt))
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
    // senza modello in memoria non c'è niente da liberare (e il modello
    // tenuto da whisper.cpp è quello di un altro, il testo istantaneo)
    if (!keepLoaded) return;
    try {
      await _whisper.releaseModel();
    } catch (_) {
      // nessun modello in memoria
    }
  }
}
