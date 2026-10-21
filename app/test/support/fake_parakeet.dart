import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/recorder/vad_segmenter.dart';

/// Parakeet finto per i test: niente FFI né download veri.
class FakeParakeet extends ParakeetService {
  FakeParakeet(
    Directory dir, {
    this.isInstalled = true,
    this.reason,
    this.engine,
    super.host = WhisperHost.windows,
  }) : super(baseDir: () async => dir);

  bool isInstalled;
  String? reason;
  VadLiveEngine? engine;

  /// Download in corso: si completa con [finishDownload] (o [failDownload]).
  Completer<void>? _download;
  final transcribed = <String>[];

  @override
  Future<bool> installed() async => platformSupported && isInstalled;

  @override
  Future<String?> unavailableReason() async =>
      platformSupported ? reason : 'Parakeet si usa solo su PC e Mac.';

  @override
  Future<VadLiveEngine> liveEngine() async {
    final e = engine;
    if (e == null) throw StateError('nessun motore');
    return e;
  }

  @override
  Stream<WhisperProgress> download({CancelToken? cancel}) async* {
    final c = _download ??= Completer<void>();
    cancel?.addListener(() {
      if (!c.isCompleted) c.completeError(DownloadCancelled());
    });
    yield const WhisperProgress('Scarico Parakeet', 0.1);
    await c.future;
    isInstalled = true;
    yield const WhisperProgress('Pronto', 1);
  }

  void finishDownload() => _download?.complete();
  void failDownload() => _download?.completeError(WhisperException('rete'));
  bool get downloadStarted => _download != null;

  @override
  Future<List<WhisperSegment>> transcribeFile(
    File audio, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
  }) async {
    transcribed.add(audio.path);
    return const [WhisperSegment(Duration.zero, 'Buongiorno da Parakeet')];
  }
}

/// Motore dal vivo finto: ogni pezzo di audio diventa una frase confermata
/// («frase» con l'inizio in ms), fino alla fine del pezzo il testo è definitivo.
class FakeVadEngine implements VadLiveEngine {
  final feeds = <(int, int)>[];
  final ranges = <(Duration, Duration)>[];
  bool closed = false;

  /// Se impostato, [feed] lancia questo errore (motore rotto).
  Object? failWith;

  @override
  String get modelId => kParakeetId;

  @override
  Future<LiveStep> feed(
    int start,
    Float32List samples, {
    bool partial = true,
  }) async {
    final f = failWith;
    if (f != null) throw f;
    feeds.add((start, samples.length));
    final s = samplesToDuration(start);
    final e = samplesToDuration(start + samples.length);
    return LiveStep(
      committed: [TranscriptSegment(s, e, 'frase ${s.inMilliseconds}')],
      partial: '',
      stableUntil: e,
    );
  }

  @override
  Future<List<TranscriptSegment>> transcribeRange(
    File wav,
    Duration start,
    Duration end,
  ) async {
    ranges.add((start, end));
    return [TranscriptSegment(start, end, 'recupero ${start.inMilliseconds}')];
  }

  @override
  Future<void> close() async => closed = true;
}
