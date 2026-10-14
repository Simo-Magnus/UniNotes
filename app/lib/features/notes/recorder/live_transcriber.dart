import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/services/whisper_service.dart';
import 'live_transcript.dart';
import 'recording_meta.dart';
import 'system_speech.dart';
import 'wav.dart';

/// Stato della trascrizione dal vivo (card «Trascrizione» del registratore).
enum LiveState {
  /// Non avviata.
  off,

  /// Né il sistema né Whisper sono disponibili: la registrazione va avanti
  /// senza testo.
  unavailable,

  /// Avvio del riconoscitore o caricamento del modello.
  starting,

  /// Al passo con il parlato.
  running,

  /// Whisper è indietro: alcuni pezzi si recuperano a fine registrazione.
  lagging,

  /// Errore del motore (la registrazione continua).
  failed,
}

/// Chi trascrive dal vivo.
enum LiveEngine {
  none,

  /// Riconoscimento vocale del sistema in streaming (testo istantaneo).
  system,

  /// Whisper a pezzi di ~10 s (ripiego).
  whisper,
}

/// Trascrizione dal vivo durante la registrazione.
///
/// 1. **Riconoscimento del sistema** (recorder/system_speech.dart), come Memo
///    Vocali o la digitazione vocale di Google Docs: riceve l'audio della
///    registrazione man mano ([onPcm]); il testo provvisorio ([partial]) si
///    aggiorna mentre si parla e diventa un segmento quando il sistema lo
///    stabilizza.
/// 2. **Whisper a pezzi** (ripiego, dove il sistema non offre nulla o il
///    riconoscitore si ferma): legge dal WAV di lavoro l'ultimo pezzo (~10 s
///    con 1 s di sovrapposizione), lo passa a Whisper fuori dal thread
///    dell'interfaccia e unisce il testo. Un pezzo alla volta: se Whisper
///    resta indietro, i pezzi saltati si recuperano alla fine ([recover]).
///
/// Non blocca mai la registrazione: ogni errore ferma solo la trascrizione
/// (o fa passare dal sistema a Whisper).
class LiveTranscriber extends ChangeNotifier {
  LiveTranscriber(
    this._whisper, {
    LiveChunkPlanner? planner,
    this.speech,
    this.locale = 'it-IT',
  }) : planner = planner ?? LiveChunkPlanner();

  final WhisperService? _whisper;

  /// Riconoscimento vocale del sistema (null = solo Whisper).
  final SystemSpeech? speech;
  final LiveChunkPlanner planner;
  final TranscriptMerger merger = TranscriptMerger();

  /// Lingua del riconoscimento (es. «it-IT»).
  final String locale;

  LiveState state = LiveState.off;
  LiveEngine engine = LiveEngine.none;
  String? modelId;
  String? error;

  /// Testo provvisorio del riconoscitore del sistema (la frase in corso).
  String partial = '';

  /// Il riconoscitore del sistema lavora sul dispositivo.
  bool onDevice = false;

  /// Perché il riconoscitore del sistema non è disponibile (codice di
  /// [SpeechSupport.reason]).
  String? systemUnavailable;

  LiveWhisper? _engine;
  File? _wav;
  int _sampleRate = 16000;
  int _channels = 1;
  Directory? _tmp;
  Future<void>? _inFlight;
  bool _closed = false;

  bool _feeds = false;
  StreamSubscription<SpeechEvent>? _sub;
  Duration _recorded = Duration.zero;
  Duration? _partialStart;
  Completer<void>? _ended;

  /// Chiamato a ogni nuovo segmento (salvataggio nel file di sessione).
  VoidCallback? onSegments;

  List<TranscriptSegment> get segments => merger.segments;
  String get text => merger.text;
  bool get active =>
      state == LiveState.running ||
      state == LiveState.lagging ||
      state == LiveState.starting;

  /// Fonte del testo, salvata con la trascrizione.
  String get sourceLabel => switch (engine) {
    LiveEngine.system =>
      'trascrizione dal vivo con il riconoscimento vocale del sistema',
    _ when modelId != null => 'trascrizione dal vivo con Whisper $modelId',
    _ => 'trascrizione dal vivo',
  };

  /// Avvia il riconoscitore del sistema; se non c'è, prepara Whisper. Se
  /// non c'è nemmeno Whisper lo stato diventa [LiveState.unavailable].
  Future<void> begin(
    File wav, {
    required int sampleRate,
    required int channels,
  }) async {
    _wav = wav;
    _sampleRate = sampleRate;
    _channels = channels;
    state = LiveState.starting;
    notifyListeners();
    if (await _beginSystem()) return;
    if (_closed) return;
    await _beginWhisper(Duration.zero);
  }

  Future<bool> _beginSystem() async {
    final sp = speech;
    if (sp == null) return false;
    try {
      final sup = await sp.support(locale);
      if (_closed) return false;
      if (!sup.available) {
        systemUnavailable = sup.reason;
        return false;
      }
      _sub ??= sp.events.listen(_onSpeech);
      final ok = await sp.start(locale: locale);
      if (_closed) {
        if (ok) unawaited(sp.stop());
        return false;
      }
      if (!ok) {
        systemUnavailable = sp.lastStartError;
        return false;
      }
      _feeds = sup.feedsAudio;
      onDevice = sup.onDevice;
      engine = LiveEngine.system;
      state = LiveState.running;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Riconoscimento vocale del sistema: $e');
      return false;
    }
  }

  /// Whisper dal punto [from] della registrazione in poi.
  Future<void> _beginWhisper(Duration from) async {
    try {
      _engine = await _whisper?.liveEngine();
    } catch (e) {
      _engine = null;
    }
    if (_closed) {
      unawaited(_engine?.close());
      return;
    }
    if (_engine == null) {
      engine = LiveEngine.none;
      state = LiveState.unavailable;
    } else {
      engine = LiveEngine.whisper;
      modelId = _engine!.modelId;
      planner.startAt(from);
      state = LiveState.running;
      _tmp ??= await Directory.systemTemp.createTemp('uninotes_live_');
    }
    notifyListeners();
  }

  void _onSpeech(SpeechEvent e) {
    if (_closed && e.kind != SpeechEventKind.ended) return;
    switch (e.kind) {
      case SpeechEventKind.partial:
        final t = e.text.trim();
        if (t.isEmpty || t == partial) return;
        // la frase è iniziata poco prima del primo testo provvisorio
        _partialStart ??= _startOfSpeech();
        partial = t;
        notifyListeners();
      case SpeechEventKind.result:
        _commit(e.text);
      case SpeechEventKind.error:
        if (!e.fatal) return;
        debugPrint('Riconoscimento vocale del sistema: ${e.text}');
        error = e.text;
        _commit(partial);
        _fallbackToWhisper();
      case SpeechEventKind.ended:
        final done = _ended;
        if (done != null && !done.isCompleted) done.complete();
    }
  }

  Duration _startOfSpeech() {
    final last = segments.isEmpty ? Duration.zero : segments.last.end;
    final guess = _recorded - const Duration(seconds: 1);
    return guess < last ? last : guess;
  }

  /// Testo stabilizzato dal sistema: diventa un segmento con i tempi della
  /// registrazione.
  void _commit(String raw) {
    final t = raw.trim();
    final start = _partialStart ?? _startOfSpeech();
    _partialStart = null;
    partial = '';
    if (t.isEmpty || isHallucination(t)) {
      notifyListeners();
      return;
    }
    final end = _recorded > start
        ? _recorded
        : start + const Duration(milliseconds: 500);
    merger.segments.add(TranscriptSegment(start, end, t));
    onSegments?.call();
    notifyListeners();
  }

  /// Il riconoscitore del sistema si è fermato: si continua con Whisper dal
  /// punto attuale (il testo già riconosciuto resta).
  void _fallbackToWhisper() {
    if (engine != LiveEngine.system) return;
    engine = LiveEngine.none;
    _feeds = false;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(speech?.stop());
    state = LiveState.starting;
    notifyListeners();
    unawaited(_beginWhisper(_recorded));
  }

  /// Il formato del WAV è cambiato prima dei dati (scelta del sistema).
  void setFormat(int sampleRate, int channels) {
    _sampleRate = sampleRate;
    _channels = channels;
  }

  /// Audio appena registrato (PCM 16 bit nel formato del WAV): al
  /// riconoscitore del sistema, mono a 16 kHz.
  void onPcm(Uint8List data) {
    if (!_feeds || _closed || engine != LiveEngine.system) return;
    try {
      final samples = pcm16(data);
      speech?.feed(
        _sampleRate == 16000 && _channels == 1
            ? samples
            : toMono16k(samples, _sampleRate, _channels),
      );
    } catch (_) {
      // un pezzo perso non ferma niente
    }
  }

  /// Nuovo audio registrato fino a [recorded].
  void onAudio(Duration recorded) {
    _recorded = recorded;
    if (_engine == null || _closed || state == LiveState.failed) return;
    planner.advance(recorded);
    final lag = planner.skipped.isNotEmpty;
    final next = lag ? LiveState.lagging : LiveState.running;
    if (next != state) {
      state = next;
      notifyListeners();
    }
    _pump();
  }

  /// Pausa e ripresa della registrazione.
  void pause() {
    if (engine == LiveEngine.system) unawaited(speech?.pause());
  }

  void resume() {
    if (engine == LiveEngine.system) unawaited(speech?.resume());
  }

  void _pump() {
    if (_inFlight != null || _closed) return;
    final c = planner.takeNext();
    if (c == null) return;
    _inFlight = _process(c).whenComplete(() {
      planner.done();
      _inFlight = null;
      if (!_closed) _pump();
    });
  }

  Future<void> _process(LiveChunk c, {File? source}) async {
    try {
      final segs = await transcribeChunk(c, source: source);
      if (segs.isNotEmpty) {
        merger.add(segs);
        onSegments?.call();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Trascrizione dal vivo: $e');
      error = '$e';
      state = LiveState.failed;
      notifyListeners();
    }
  }

  /// Trascrive il tratto [c] del WAV (tempi riferiti alla registrazione).
  /// I pezzi silenziosi non vanno a Whisper (eviterebbe frasi inventate).
  Future<List<TranscriptSegment>> transcribeChunk(
    LiveChunk c, {
    File? source,
  }) async {
    final engine = _engine;
    final wav = source ?? _wav;
    if (engine == null || wav == null) return const [];
    final info = source == null
        ? WavInfo(
            sampleRate: _sampleRate,
            channels: _channels,
            dataLength: 1 << 40,
          )
        : await readWavInfo(source);
    if (info == null) return const [];
    final raw = await readWavRange(wav, info, c.start, c.end);
    if (raw.isEmpty) return const [];
    final mono = toMono16k(raw, info.sampleRate, info.channels);
    if (pcmLevel(mono) < 0.12) return const [];
    final dir = _tmp ??= await Directory.systemTemp.createTemp(
      'uninotes_live_',
    );
    final file = File(p.join(dir.path, 'pezzo_${c.index}.wav'));
    await writeWav16k(file, mono);
    try {
      final out = await engine.transcribeWav(file);
      return [
        for (var i = 0; i < out.length; i++)
          TranscriptSegment(
            c.start + out[i].start,
            c.start +
                (out[i].end ??
                    (i + 1 < out.length ? out[i + 1].start : c.end - c.start)),
            out[i].text,
          ),
      ];
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  /// Fine dell'audio del riconoscitore del sistema: attende l'ultimo testo
  /// (al massimo [timeout]); quello ancora provvisorio diventa definitivo.
  Future<void> flush({Duration timeout = const Duration(seconds: 2)}) async {
    if (engine != LiveEngine.system) return;
    final sp = speech;
    if (sp == null) return;
    final done = _ended = Completer<void>();
    _feeds = false;
    await sp.stop();
    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      // il sistema non ha risposto: resta il testo provvisorio
    }
    if (partial.trim().isNotEmpty) _commit(partial);
  }

  /// Fine registrazione a [recorded]: pezzi ancora da trascrivere con
  /// Whisper (ultimo, saltati e in attesa).
  List<LiveChunk> finish(Duration recorded) {
    if (_engine == null) return const [];
    return planner.finish(recorded);
  }

  /// Whisper sta trascrivendo un pezzo.
  bool get busy => _inFlight != null;

  /// Attende il pezzo in corso.
  Future<void> settle() async => _inFlight;

  /// Recupera i pezzi [chunks] leggendo da [source] (il WAV della
  /// registrazione). [progress] riceve (fatti, totale).
  Future<void> recover(
    List<LiveChunk> chunks,
    File source, {
    void Function(int done, int total)? progress,
  }) async {
    await settle();
    if (state == LiveState.failed || _engine == null) return;
    for (var i = 0; i < chunks.length; i++) {
      progress?.call(i, chunks.length);
      await _process(chunks[i], source: source);
      if (state == LiveState.failed) return;
    }
    progress?.call(chunks.length, chunks.length);
  }

  /// Libera il riconoscitore, Whisper e i file temporanei.
  Future<void> close() async {
    _closed = true;
    _feeds = false;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    if (engine == LiveEngine.system) {
      final ended = _ended;
      if (ended == null) unawaited(speech?.stop());
    }
    try {
      await _inFlight;
    } catch (_) {}
    try {
      await _engine?.close();
    } catch (_) {}
    _engine = null;
    final tmp = _tmp;
    _tmp = null;
    try {
      if (tmp != null && await tmp.exists()) await tmp.delete(recursive: true);
    } catch (_) {}
  }

  /// Segmenti già trascritti (da un file di sessione dopo un riavvio).
  void restore(List<TranscriptSegment> segs) {
    merger.segments
      ..clear()
      ..addAll(segs);
  }
}
