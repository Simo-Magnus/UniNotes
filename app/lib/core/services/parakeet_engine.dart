import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../../features/notes/recorder/vad_segmenter.dart';

/// Parakeet (sherpa-onnx) in un isolate tutto suo: il riconoscimento è una
/// chiamata FFI sincrona di qualche centinaio di millisecondi e non deve
/// fermare l'interfaccia né la registrazione.
///
/// Un solo modello in memoria (~1 GB) per tutta l'app; ogni utilizzo (testo
/// dal vivo, recupero dei tratti, trascrizione di un file) apre una
/// **sessione** con il suo VAD (Silero) e il suo [VadLiveSegmenter]. Le
/// richieste si eseguono una alla volta, nell'ordine di arrivo.
///
/// Pochi thread di calcolo ([threads], 2 di solito): misurato su un
/// portatile a 8 core, 2 thread decodificano una frase di ~6 s in ~0,3 s
/// (4 thread non vanno più veloci con la registrazione in corso).

/// Percorsi dei file del modello e del VAD.
class ParakeetPaths {
  const ParakeetPaths({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
    required this.vad,
    this.libDir,
  });
  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
  final String vad;

  /// Cartella delle librerie native di sherpa-onnx (null = quelle dell'app,
  /// accanto all'eseguibile; i test passano quella del pacchetto).
  final String? libDir;
}

class ParakeetWorker {
  ParakeetWorker._(this._send, this._isolate, this._replies);

  final SendPort _send;
  final Isolate _isolate;
  final ReceivePort _replies;
  final Map<int, Completer<Object?>> _pending = {};
  int _next = 0;
  bool _closed = false;

  /// Avvia l'isolate e carica il modello (~2 s). Errore se il modello non
  /// si carica (file danneggiati, libreria mancante).
  static Future<ParakeetWorker> start(
    ParakeetPaths paths, {
    int threads = 2,
  }) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(
      _main,
      (ready.sendPort, paths, threads),
      debugName: 'parakeet',
      onError: ready.sendPort,
    );
    final first = Completer<Object?>();
    final replies = ReceivePort();
    ready.listen((m) {
      if (!first.isCompleted) first.complete(m);
    });
    final m = await first.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () => 'Parakeet non risponde.',
    );
    ready.close();
    if (m is! SendPort) {
      isolate.kill(priority: Isolate.immediate);
      replies.close();
      throw ParakeetException('$m');
    }
    final w = ParakeetWorker._(m, isolate, replies);
    replies.listen(w._onReply);
    return w;
  }

  void _onReply(Object? m) {
    if (m is! List || m.length != 3) return;
    final c = _pending.remove(m[0]);
    if (c == null) return;
    if (m[1] == true) {
      c.complete(m[2]);
    } else {
      c.completeError(ParakeetException('${m[2]}'));
    }
  }

  Future<Object?> _call(String op, List<Object?> args) {
    if (_closed) return Future.error(ParakeetException('Parakeet chiuso.'));
    final id = _next++;
    final c = _pending[id] = Completer<Object?>();
    _send.send([id, op, args, _replies.sendPort]);
    return c.future;
  }

  /// Nuova sessione (VAD e testo provvisorio suoi).
  Future<void> open(int session) => _call('open', [session]);

  Future<LiveStep> feed(
    int session,
    int start,
    Float32List samples, {
    bool partial = true,
  }) async => await _call('feed', [
    session,
    start,
    TransferableTypedData.fromList([samples]),
    partial,
  ]) as LiveStep;

  Future<LiveStep> flush(int session) async =>
      await _call('flush', [session]) as LiveStep;

  Future<void> closeSession(int session) => _call('close', [session]);

  /// Libera il modello e chiude l'isolate.
  Future<void> dispose() async {
    if (_closed) return;
    try {
      await _call('dispose', const []).timeout(const Duration(seconds: 5));
    } catch (_) {}
    _closed = true;
    _replies.close();
    _isolate.kill();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(ParakeetException('Parakeet chiuso.'));
      }
    }
    _pending.clear();
  }
}

class ParakeetException implements Exception {
  ParakeetException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ------------------------------------------------------------- isolate

void _main((SendPort, ParakeetPaths, int) args) {
  final (ready, paths, threads) = args;
  final so.OfflineRecognizer rec;
  try {
    _loadNative(paths.libDir);
    rec = so.OfflineRecognizer(
      so.OfflineRecognizerConfig(
        model: so.OfflineModelConfig(
          transducer: so.OfflineTransducerModelConfig(
            encoder: paths.encoder,
            decoder: paths.decoder,
            joiner: paths.joiner,
          ),
          tokens: paths.tokens,
          modelType: 'nemo_transducer',
          numThreads: threads,
          debug: false,
        ),
        // modified_beam_search con gli hotwords non cambia il testo di
        // Parakeet TDT (misurato, vedi docs/registratore.md): greedy
        decodingMethod: 'greedy_search',
      ),
    );
  } catch (e) {
    ready.send('Parakeet non si avvia: $e');
    return;
  }
  final decoder = _SherpaDecoder(rec);
  final sessions = <int, VadLiveSegmenter>{};
  final port = ReceivePort();
  ready.send(port.sendPort);
  port.listen((m) {
    if (m is! List || m.length != 4) return;
    final id = m[0] as int;
    final op = m[1] as String;
    final a = m[2] as List;
    final reply = m[3] as SendPort;
    try {
      Object? out;
      switch (op) {
        case 'open':
          (sessions.remove(a[0])?.vad as _SherpaVad?)?.free();
          final vad = _SherpaVad(paths.vad);
          sessions[a[0] as int] = VadLiveSegmenter(vad, decoder);
        case 'feed':
          final s = sessions[a[0]];
          if (s == null) throw StateError('sessione chiusa');
          final data = (a[2] as TransferableTypedData)
              .materialize()
              .asFloat32List();
          out = s.feed(a[1] as int, data, partial: a[3] as bool);
        case 'flush':
          final s = sessions[a[0]];
          out = s?.flush() ?? const LiveStep();
        case 'close':
          final s = sessions.remove(a[0]);
          (s?.vad as _SherpaVad?)?.free();
        case 'dispose':
          for (final s in sessions.values) {
            (s.vad as _SherpaVad).free();
          }
          sessions.clear();
          rec.free();
          reply.send([id, true, null]);
          port.close();
          return;
      }
      reply.send([id, true, out]);
    } catch (e) {
      reply.send([id, false, '$e']);
    }
  });
}

/// Librerie native: su Windows l'onnxruntime.dll accanto a uninotes.exe va
/// caricato per primo, altrimenti Windows 11 può dare quello di System32
/// (ONNX Runtime 1.17, troppo vecchio per sherpa-onnx: l'app si chiude).
void _loadNative(String? libDir) {
  if (Platform.isWindows) {
    final dir = libDir ?? p.dirname(Platform.resolvedExecutable);
    final ort = File(p.join(dir, 'onnxruntime.dll'));
    if (ort.existsSync()) DynamicLibrary.open(ort.path);
  }
  so.initBindings(libDir);
}

class _SherpaDecoder implements SpeechDecoder {
  _SherpaDecoder(this.rec);
  final so.OfflineRecognizer rec;

  @override
  DecodedText decode(Float32List samples) {
    // meno di 0,1 s: niente da riconoscere
    if (samples.length < 1600) return const DecodedText('');
    final st = rec.createStream();
    try {
      st.acceptWaveform(samples: samples, sampleRate: 16000);
      rec.decode(st);
      final r = rec.getResult(st);
      return DecodedText(r.text, tokens: r.tokens, timestamps: r.timestamps);
    } finally {
      st.free();
    }
  }
}

/// Silero VAD di sherpa-onnx: pausa di 0,5 s per chiudere una frase,
/// parlato minimo 0,25 s, taglio forzato oltre 18 s di parlato continuo.
class _SherpaVad implements SpeechVad {
  _SherpaVad(this.model) : _v = _make(model);
  final String model;
  so.VoiceActivityDetector _v;

  static so.VoiceActivityDetector _make(String model) =>
      so.VoiceActivityDetector(
        config: so.VadModelConfig(
          sileroVad: so.SileroVadModelConfig(
            model: model,
            threshold: 0.5,
            minSilenceDuration: 0.5,
            minSpeechDuration: 0.25,
            maxSpeechDuration: 18,
          ),
          numThreads: 1,
          debug: false,
        ),
        bufferSizeInSeconds: 60,
      );

  @override
  void accept(Float32List samples) => _v.acceptWaveform(samples);

  @override
  bool get speaking => _v.isDetected();

  @override
  bool get hasSegment => !_v.isEmpty();

  @override
  VadSegment pop() {
    final s = _v.front();
    _v.pop();
    return VadSegment(s.start, s.samples);
  }

  @override
  void flush() => _v.flush();

  /// Un VAD nuovo: i campioni ripartono da zero.
  @override
  void reset() {
    _v.free();
    _v = _make(model);
  }

  void free() => _v.free();
}
