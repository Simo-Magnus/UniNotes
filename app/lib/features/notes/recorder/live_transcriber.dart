import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/services/power.dart';
import '../../../core/services/whisper_service.dart';
import '../spoken_math.dart';
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

  /// Avvio del riconoscitore, download o caricamento del modello.
  starting,

  /// Al passo con il parlato.
  running,

  /// Whisper è indietro: alcuni tratti si recuperano a fine registrazione.
  lagging,

  /// Errore del motore (la registrazione continua).
  failed,
}

/// Chi trascrive dal vivo.
enum LiveEngine {
  none,

  /// Riconoscimento vocale del sistema in streaming (testo istantaneo).
  system,

  /// Whisper sul dispositivo (ripiego): finestre di ~2 s con il modello dal
  /// vivo, pezzi da ~10 s con un modello più pesante.
  whisper,
}

/// Trascrizione dal vivo durante la registrazione.
///
/// 1. **Whisper** con il modello integrato (base q5_1, incluso nell'app o
///    scaricato da solo la prima volta), sempre offline: ogni ~2 s
///    ritrascrive dal WAV di lavoro il tratto non ancora definitivo
///    ([LiveWindowPlanner]): il testo provvisorio ([partial]) si aggiorna
///    mentre si parla. È il motore del testo istantaneo dell'app, qualunque
///    altra cosa sia collegata: i modelli scaricati più accurati sono
///    troppo lenti per stare al passo e si usano dopo il salvataggio
///    («Trascrivi di nuovo con…», recorder/better_transcription.dart). Solo
///    se il modello integrato non può girare (PC senza AVX2, build senza il
///    modello e download non riuscito) si usa quello scaricato
///    dall'utente a pezzi da ~10 s. Una trascrizione alla volta, fuori dal
///    thread dell'interfaccia; i tratti saltati si recuperano alla fine
///    ([recover]).
/// 2. **Riconoscimento del sistema** (recorder/system_speech.dart): solo se
///    si passa [speech] (oggi nessuno lo fa: il registratore usa sempre
///    Whisper, perché su Windows con «Riconoscimento vocale online» il testo
///    istantaneo non arrivava). Resta per i test e per un eventuale ritorno;
///    riceve l'audio della registrazione man mano ([onPcm]).
///
/// Non blocca mai la registrazione: ogni errore ferma solo la trascrizione
/// (o fa passare dal sistema a Whisper).
///
/// Mentre si registra lo studente può **correggere** le frasi già scritte
/// ([editSegment]) e attivare **«Formule (LaTeX)»** ([formulas]): le
/// formule dette a voce diventano LaTeX (`spoken_math.dart`). Correzioni e
/// formule si applicano a [segments], che finiscono nella trascrizione
/// salvata; il testo originale resta in [merger] per unire bene le finestre
/// successive di Whisper.
class LiveTranscriber extends ChangeNotifier {
  LiveTranscriber(
    this._whisper, {
    LiveWindowPlanner? planner,
    this.speech,
    this.locale = 'it-IT',
  }) : _customPlanner = planner,
       planner = planner ?? LiveWindowPlanner();

  final WhisperService? _whisper;

  /// Riconoscimento vocale del sistema (null = solo Whisper).
  final SystemSpeech? speech;
  final LiveWindowPlanner? _customPlanner;

  /// Finestre di Whisper (scelte in base al modello all'avvio di Whisper).
  LiveWindowPlanner planner;
  final TranscriptMerger merger = TranscriptMerger();

  /// Lingua del riconoscimento (es. «it-IT»).
  final String locale;

  LiveState state = LiveState.off;
  LiveEngine engine = LiveEngine.none;
  String? modelId;
  String? error;

  /// Whisper usa il modello dal vivo (testo provvisorio ogni ~2 s).
  bool quick = false;

  /// Testo provvisorio (la frase in corso): dal riconoscitore del sistema o
  /// dall'ultima finestra di Whisper.
  String partial = '';

  /// Il riconoscitore del sistema lavora sul dispositivo.
  bool onDevice = false;

  /// Perché il riconoscitore del sistema non è disponibile (codice di
  /// [SpeechSupport.reason]).
  String? systemUnavailable;

  /// La lingua manca fra quelle del riconoscitore del sistema.
  bool systemLanguageMissing = false;

  /// Download del modello dal vivo in corso ([downloadProgress] 0–1, null
  /// se non si sa).
  bool downloading = false;
  double? downloadProgress;
  String? downloadError;

  /// Quanto ha impiegato Whisper per l'ultima finestra.
  Duration? lastTook;

  LiveWhisper? _engine;
  File? _wav;
  int _sampleRate = 16000;
  int _channels = 1;
  Directory? _tmp;
  Future<void>? _inFlight;
  bool _closed = false;
  bool _finished = false;
  CancelToken? _download;

  bool _feeds = false;
  StreamSubscription<SpeechEvent>? _sub;
  Duration _recorded = Duration.zero;
  Duration? _partialStart;
  Completer<void>? _ended;

  /// Chiamato a ogni nuovo segmento (salvataggio nel file di sessione).
  VoidCallback? onSegments;

  /// Correzioni dello studente (inizio del segmento in ms → testo).
  final Map<int, String> _edits = {};

  /// Formule dette a voce → LaTeX.
  bool _formulas = false;
  bool get formulas => _formulas;
  set formulas(bool v) {
    if (v == _formulas) return;
    _formulas = v;
    onSegments?.call();
    notifyListeners();
  }

  /// Conversioni già fatte (il testo si ridisegna spesso).
  final Map<String, String> _latex = {};

  String _shown(String raw) {
    if (!_formulas) return raw;
    final hit = _latex[raw];
    if (hit != null) return hit;
    if (_latex.length > 400) _latex.clear();
    return _latex[raw] = spokenMathToLatex(raw);
  }

  /// Segmenti come li vede (e li salva) lo studente: con le sue correzioni
  /// e, se attive, le formule in LaTeX.
  List<TranscriptSegment> get segments => [
    for (final s in merger.segments)
      s.copyWith(text: _edits[s.start.inMilliseconds] ?? _shown(s.text)),
  ];

  /// Testo provvisorio come si mostra (formule comprese).
  String get partialShown => partial.isEmpty ? '' : _shown(partial);

  String get text => segments.map((s) => s.text).join(' ');

  /// Il segmento [index] è stato corretto a mano.
  bool isEdited(int index) =>
      index >= 0 &&
      index < merger.segments.length &&
      _edits.containsKey(merger.segments[index].start.inMilliseconds);

  /// Correzione del segmento [index] (testo vuoto = frase tolta).
  void editSegment(int index, String text) {
    if (index < 0 || index >= merger.segments.length) return;
    replaceSegments([merger.segments[index].start.inMilliseconds], text);
  }

  /// Modifica dal campo di testo della trascrizione (come in un editor): i
  /// segmenti che iniziano a [startsMs] diventano uno solo con [text]
  /// (inizio del primo, fine dell'ultimo); testo vuoto = tolti. Gli altri
  /// segmenti tengono testo e tempi.
  void replaceSegments(List<int> startsMs, String text) {
    final idx = <int>[
      for (final k in startsMs)
        if (merger.segments.indexWhere((s) => s.start.inMilliseconds == k)
            case final i when i >= 0)
          i,
    ]..sort();
    if (idx.isEmpty) return;
    final first = idx.first;
    final lastEnd = merger.segments[idx.last].end;
    // dal fondo, così l'indice del primo non cambia
    for (final i in idx.skip(1).toList().reversed) {
      _edits.remove(merger.segments[i].start.inMilliseconds);
      merger.segments.removeAt(i);
    }
    final seg = merger.segments[first];
    final key = seg.start.inMilliseconds;
    final t = text.trim();
    if (t.isEmpty) {
      merger.segments.removeAt(first);
      _edits.remove(key);
    } else {
      if (lastEnd > seg.end) {
        merger.segments[first] = seg.copyWith(end: lastEnd);
      }
      _edits[key] = t;
    }
    onSegments?.call();
    notifyListeners();
  }

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
      systemLanguageMissing = !sup.languageOk;
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

  /// Whisper dal punto [from] della registrazione in poi. Se manca il
  /// modello dal vivo lo scarica (barra nella card); l'audio registrato
  /// nel frattempo si trascrive dopo il salvataggio.
  Future<void> _beginWhisper(Duration from) async {
    final w = _whisper;
    if (w != null) await _ensureLiveModel(w);
    if (_closed || _finished) return;
    try {
      _engine = await w?.liveEngine();
    } catch (e) {
      _engine = null;
    }
    if (_closed) {
      unawaited(_engine?.close());
      return;
    }
    final eng = _engine;
    if (eng == null) {
      engine = LiveEngine.none;
      state = LiveState.unavailable;
    } else {
      engine = LiveEngine.whisper;
      modelId = eng.modelId;
      quick = eng.quick;
      final pl = planner =
          _customPlanner ??
          (eng.quick ? LiveWindowPlanner() : LiveWindowPlanner.slow());
      pl.startAt(from);
      pl.skipTo(_recorded);
      state = LiveState.running;
      _tmp ??= await Directory.systemTemp.createTemp('uninotes_live_');
    }
    notifyListeners();
    _pump();
  }

  /// Scarica il modello dal vivo se manca (sul telefono solo con Wi‑Fi:
  /// con i dati mobili si usa il modello già scaricato, se c'è).
  Future<void> _ensureLiveModel(WhisperService w) async {
    try {
      if (!w.liveModelSupported || await w.liveModelFile() != null) return;
      if (w.isPhone && !await Power.onWifi()) return;
    } catch (_) {
      return;
    }
    if (_closed) return;
    final cancel = _download = CancelToken();
    downloading = true;
    downloadProgress = 0;
    notifyListeners();
    var shown = -1;
    try {
      await for (final pr in w.downloadLiveModel(cancel: cancel)) {
        if (_closed) break;
        downloadProgress = pr.fraction;
        final pct = ((pr.fraction ?? 0) * 100).floor();
        if (pct != shown) {
          shown = pct;
          notifyListeners();
        }
      }
    } catch (e) {
      if (!cancel.isCancelled) downloadError = '$e';
    } finally {
      _download = null;
      downloading = false;
      downloadProgress = null;
      if (!_closed) notifyListeners();
    }
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
        // il motivo resta visibile nella card (es. Dettatura disattivata)
        systemUnavailable ??= e.text;
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
    if (_engine == null || _closed || _finished) return;
    if (state == LiveState.failed) return;
    final next = planner.lagSkips > 0 ? LiveState.lagging : LiveState.running;
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
    if (_inFlight != null || _closed || _finished || _engine == null) return;
    if (state == LiveState.failed) return;
    final c = planner.next(_recorded);
    if (c == null) return;
    _inFlight = _window(c).whenComplete(() {
      _inFlight = null;
      if (!_closed) _pump();
    });
  }

  /// Trascrive la finestra [c]: testo provvisorio e segmenti definitivi.
  Future<void> _window(LiveChunk c) async {
    final sw = Stopwatch()..start();
    try {
      final r = await _run(c);
      if (_finished || _closed) {
        planner.abandon();
        return;
      }
      lastTook = sw.elapsed;
      final out = planner.done(
        c,
        r.segments,
        silentTail: r.silentTail,
        took: sw.elapsed,
      );
      if (out.committed.isNotEmpty) {
        merger.add(out.committed);
        onSegments?.call();
      }
      partial = out.provisional;
      notifyListeners();
    } catch (e) {
      planner.abandon();
      debugPrint('Trascrizione dal vivo: $e');
      error = '$e';
      partial = '';
      state = LiveState.failed;
      notifyListeners();
    }
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
  }) async => (await _run(c, source: source)).segments;

  Future<({List<TranscriptSegment> segments, bool silentTail})> _run(
    LiveChunk c, {
    File? source,
  }) async {
    const none = (segments: <TranscriptSegment>[], silentTail: true);
    final engine = _engine;
    final wav = source ?? _wav;
    if (engine == null || wav == null) return none;
    final info = source == null
        ? WavInfo(
            sampleRate: _sampleRate,
            channels: _channels,
            dataLength: 1 << 40,
          )
        : await readWavInfo(source);
    if (info == null) return none;
    final raw = await readWavRange(wav, info, c.start, c.end);
    if (raw.isEmpty) return none;
    final mono = toMono16k(raw, info.sampleRate, info.channels);
    if (pcmLevel(mono) < 0.12) return none;
    final silentTail = endsInPause(mono);
    final dir = _tmp ??= await Directory.systemTemp.createTemp(
      'uninotes_live_',
    );
    final file = File(p.join(dir.path, 'pezzo_${c.index}.wav'));
    await writeWav16k(file, mono);
    try {
      final out = await engine.transcribeWav(file);
      return (
        segments: [
          for (var i = 0; i < out.length; i++)
            TranscriptSegment(
              c.start + out[i].start,
              c.start +
                  (out[i].end ??
                      (i + 1 < out.length
                          ? out[i + 1].start
                          : c.end - c.start)),
              out[i].text,
            ),
        ],
        silentTail: silentTail,
      );
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

  /// Fine registrazione a [recorded]: tratti ancora da trascrivere con
  /// Whisper (saltati e quello non ancora definitivo). Il testo provvisorio
  /// sparisce: il suo tratto si ritrascrive dopo il salvataggio.
  List<LiveChunk> finish(Duration recorded) {
    _download?.cancel();
    _finished = true;
    if (_engine == null) return const [];
    partial = '';
    return planner.finish(recorded);
  }

  /// Whisper sta trascrivendo una finestra.
  bool get busy => _inFlight != null;

  /// Attende la finestra in corso.
  Future<void> settle() async => _inFlight;

  /// Recupera i tratti [chunks] leggendo da [source] (il WAV della
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
    _download?.cancel();
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

/// La finestra [mono16k] finisce in una pausa: l'ultimo mezzo secondo è
/// molto più basso del resto (~10 dB) o quasi silenzioso. Lì il testo
/// diventa definitivo.
bool endsInPause(
  Int16List mono16k, {
  Duration tail = const Duration(milliseconds: 500),
}) {
  final n = tail.inMilliseconds * 16;
  if (mono16k.length < n * 2) return false;
  final end = pcmLevel(Int16List.sublistView(mono16k, mono16k.length - n));
  final all = pcmLevel(Int16List.sublistView(mono16k, 0, mono16k.length - n));
  return end < 0.15 || end < all - 0.17;
}
