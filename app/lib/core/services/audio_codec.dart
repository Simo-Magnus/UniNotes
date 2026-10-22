import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Conversioni dell'audio delle registrazioni, con gli strumenti già
/// presenti su ogni sistema (nessun programma da scaricare):
///
/// - **Android, iOS**: ffmpeg incluso nell'app (`ffmpeg_kit_flutter_new_min`);
/// - **macOS**: `/usr/bin/afconvert` (Core Audio, di sistema), con ffmpeg
///   dell'app come riserva;
/// - **Windows**: Media Foundation, con un piccolo metodo nativo nel runner
///   (`windows/runner/audio_transcoder.cpp`, canale
///   `io.github.simomagnus.universitynotes/audio`).
///
/// Ogni metodo restituisce false se la conversione non riesce: chi chiama
/// tiene il file originale (mai perdere una registrazione).
class AudioCodec {
  AudioCodec._();
  static final instance = AudioCodec._();

  static const channel = MethodChannel(
    'io.github.simomagnus.universitynotes/audio',
  );

  /// Bitrate del formato finale (AAC mono): ~21 MB per ora di lezione.
  static const bitRate = 48000;

  static const _afconvert = '/usr/bin/afconvert';

  /// Il sistema sa comprimere e convertire.
  bool get supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  /// WAV → `.m4a` AAC mono (~48 kbit/s).
  Future<bool> compress(File wav, File m4a) async {
    var ok = false;
    try {
      // file vecchio bloccato (Windows): la compressione non riesce e si
      // tiene il WAV, senza eccezioni
      if (await m4a.exists()) await m4a.delete();
      if (Platform.isWindows) {
        ok =
            await channel.invokeMethod<bool>('toM4a', {
              'input': wav.path,
              'output': m4a.path,
              'bitRate': bitRate,
            }) ??
            false;
      } else if (Platform.isMacOS) {
        ok = await _run(_afconvert, [
          '-f',
          'm4af',
          '-d',
          'aac',
          '-b',
          '$bitRate',
          '-c',
          '1',
          wav.path,
          m4a.path,
        ]);
        if (!ok) ok = await _ffmpeg(_aacArgs(wav.path, m4a.path));
      } else if (Platform.isAndroid || Platform.isIOS) {
        ok = await _ffmpeg(_aacArgs(wav.path, m4a.path));
      }
    } catch (e) {
      debugPrint('Compressione non riuscita: $e');
      ok = false;
    }
    if (ok && await m4a.exists() && await m4a.length() > 0) return true;
    try {
      if (await m4a.exists()) await m4a.delete();
    } catch (_) {}
    return false;
  }

  static List<String> _aacArgs(String input, String output) => [
    '-y',
    '-i',
    input,
    '-ac',
    '1',
    '-c:a',
    'aac',
    '-b:a',
    '${bitRate ~/ 1000}k',
    '-movflags',
    '+faststart',
    output,
  ];

  /// Qualsiasi audio leggibile dal sistema (.m4a, .flac, .wav, .mp3…) →
  /// WAV PCM 16 bit mono a [sampleRate] Hz (16000 per Whisper).
  Future<bool> toWav(File input, File wav, {int sampleRate = 16000}) async {
    var ok = false;
    try {
      if (await wav.exists()) await wav.delete();
      if (Platform.isWindows) {
        ok =
            await channel.invokeMethod<bool>('toWav', {
              'input': input.path,
              'output': wav.path,
              'sampleRate': sampleRate,
              'channels': 1,
            }) ??
            false;
      } else if (Platform.isMacOS) {
        ok = await _run(_afconvert, [
          '-f',
          'WAVE',
          '-d',
          'LEI16@$sampleRate',
          '-c',
          '1',
          input.path,
          wav.path,
        ]);
        if (!ok) ok = await _ffmpeg(_wavArgs(input.path, wav.path, sampleRate));
      } else if (Platform.isAndroid || Platform.isIOS) {
        ok = await _ffmpeg(_wavArgs(input.path, wav.path, sampleRate));
      }
    } catch (e) {
      debugPrint('Conversione in WAV non riuscita: $e');
      ok = false;
    }
    return ok && await wav.exists() && await wav.length() > 44;
  }

  static List<String> _wavArgs(String input, String output, int rate) => [
    '-y',
    '-i',
    input,
    '-ar',
    '$rate',
    '-ac',
    '1',
    '-c:a',
    'pcm_s16le',
    output,
  ];

  static Future<bool> _run(String exe, List<String> args) async {
    try {
      final r = await Process.run(exe, args);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  static Future<bool> _ffmpeg(List<String> args) async {
    try {
      final session = await FFmpegKit.executeWithArguments(args);
      return ReturnCode.isSuccess(await session.getReturnCode());
    } catch (_) {
      // ffmpeg_kit non disponibile su questo sistema
      return false;
    }
  }
}
