import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'recording_meta.dart';

/// Testo dal vivo guidato dalle pause (Parakeet su desktop): logica pura,
/// senza FFI (test in test/parakeet_live_test.dart con VAD e decodificatore
/// finti; quelli veri di sherpa-onnx sono in core/services/parakeet_engine.dart).
///
/// 1. L'audio della registrazione (mono 16 kHz) passa da un rilevatore di
///    voce ([SpeechVad], Silero VAD): i silenzi non producono testo.
/// 2. Mentre si parla, ogni [VadLiveSegmenter.partialEvery] di audio nuovo
///    si decodifica il tratto di parlato in corso: è il **testo
///    provvisorio**, che si aggiorna.
/// 3. A una pausa (o dopo ~18 s di parlato senza pause: il VAD taglia da
///    solo) il tratto diventa una frase **confermata**, decodificata una
///    volta sola con tutto il suo audio e divisa in frasi alla
///    punteggiatura ([splitSentences]), con i tempi della registrazione.

/// Risultato del decodificatore: testo, pezzi (token) e istante d'inizio di
/// ogni pezzo in secondi dall'inizio dell'audio decodificato.
class DecodedText {
  const DecodedText(
    this.text, {
    this.tokens = const [],
    this.timestamps = const [],
  });
  final String text;
  final List<String> tokens;
  final List<double> timestamps;
}

/// Riconoscimento di un tratto di audio (mono 16 kHz, valori -1…1).
abstract class SpeechDecoder {
  DecodedText decode(Float32List samples);
}

/// Tratto di parlato trovato dal VAD: [start] in campioni dal primo
/// campione dato al VAD (o dall'ultimo [SpeechVad.reset]).
class VadSegment {
  const VadSegment(this.start, this.samples);
  final int start;
  final Float32List samples;
}

/// Rilevatore di voce in streaming (come VoiceActivityDetector di
/// sherpa-onnx).
abstract class SpeechVad {
  void accept(Float32List samples);

  /// Si sta parlando adesso (tratto iniziato e non ancora chiuso).
  bool get speaking;

  /// C'è almeno un tratto di parlato chiuso da prendere con [pop].
  bool get hasSegment;
  VadSegment pop();

  /// Fine dell'audio: il tratto in corso si chiude.
  void flush();

  /// Si riparte da zero (buco nell'audio).
  void reset();
}

/// Riconoscitore dal vivo guidato dal VAD (Parakeet su desktop, vedi
/// core/services/parakeet_service.dart; finto nei test).
abstract class VadLiveEngine {
  String get modelId;

  /// Audio della registrazione da [start] (campioni a 16 kHz).
  Future<LiveStep> feed(int start, Float32List samples, {bool partial = true});

  /// Trascrive il tratto [start]–[end] di [wav] (tempi della
  /// registrazione): tratti saltati, recuperati dopo il salvataggio.
  Future<List<TranscriptSegment>> transcribeRange(
    File wav,
    Duration start,
    Duration end,
  );

  Future<void> close();
}

/// Esito di un passo: frasi confermate (tempi della registrazione), testo
/// provvisorio ([partial]: null = invariato, vuoto = nessuno), se si sta
/// parlando e fin dove l'audio è definitivo ([stableUntil]: prima di lì
/// tutto è confermato o silenzio).
class LiveStep {
  const LiveStep({
    this.committed = const [],
    this.partial,
    this.speaking = false,
    this.stableUntil = Duration.zero,
    this.took = Duration.zero,
  });
  final List<TranscriptSegment> committed;
  final String? partial;
  final bool speaking;
  final Duration stableUntil;

  /// Tempo di calcolo del passo.
  final Duration took;
}

const _rate = 16000;

Duration samplesToDuration(int n) =>
    Duration(microseconds: (n * 1000000 / _rate).round());

int durationToSamples(Duration d) => (d.inMicroseconds * _rate / 1e6).round();

class VadLiveSegmenter {
  VadLiveSegmenter(
    this.vad,
    this.decoder, {
    this.partialEvery = 16000,
    this.minPartial = 8000,
    this.lead = 2 * 512 + 4000,
    this.tail = 8000 + 1024,
    this.keep = 40 * _rate,
    this.pad = 4800,
  });

  /// Audio aggiunto prima di ogni tratto del VAD (~0,3 s).
  final int pad;

  final SpeechVad vad;
  final SpeechDecoder decoder;

  /// Audio nuovo (campioni) fra due testi provvisori (~1 s).
  final int partialEvery;

  /// Parlato minimo per un testo provvisorio (~0,5 s).
  final int minPartial;

  /// Il VAD si accorge del parlato con un po' di ritardo: il tratto in
  /// corso parte così prima (finestre di Silero + parlato minimo).
  final int lead;

  /// Silenzio che il VAD aspetta prima di chiudere un tratto: l'audio più
  /// recente di così potrebbe ancora diventare parlato.
  final int tail;

  /// Audio tenuto per il testo provvisorio (campioni).
  final int keep;

  /// Campione della registrazione corrispondente al campione 0 del VAD.
  int _origin = 0;

  /// Fine dell'audio ricevuto (campione della registrazione).
  int _fed = 0;
  int _lastEnd = 0;
  int? _speechStart;
  int _lastPartialAt = 0;
  bool _hadPartial = false;

  /// Audio recente: da [_bufStart] (campione della registrazione).
  Float32List _buf = Float32List(0);
  int _bufLen = 0;
  int _bufStart = 0;

  /// Fine dell'audio ricevuto.
  Duration get fed => samplesToDuration(_fed);

  /// Audio da [start] (campione della registrazione): se non continua da
  /// dove si era arrivati (tratto saltato perché il PC era indietro) il VAD
  /// riparte da lì. Con [partial] falso niente testo provvisorio (file
  /// dopo il salvataggio, recupero dei tratti).
  LiveStep feed(int start, Float32List samples, {bool partial = true}) {
    final sw = Stopwatch()..start();
    if (start != _fed) _restart(start);
    vad.accept(samples);
    _append(samples);
    _fed += samples.length;
    final committed = _drain();
    String? text;
    if (committed.isNotEmpty) text = '';
    if (vad.speaking) {
      final s = _speechStart ??= math.max(
        math.max(_lastEnd, _bufStart),
        _fed - samples.length - lead,
      );
      if (partial &&
          _fed - s >= minPartial &&
          _fed - _lastPartialAt >= partialEvery) {
        _lastPartialAt = _fed;
        final d = decoder.decode(_slice(s, _fed));
        text = d.text.trim();
        _hadPartial = text.isNotEmpty;
      }
    } else {
      _speechStart = null;
      if (_hadPartial && text == null) text = '';
      _hadPartial = false;
    }
    if (text != null && text.isEmpty) _hadPartial = false;
    _trim();
    return LiveStep(
      committed: committed,
      partial: text,
      speaking: vad.speaking,
      stableUntil: samplesToDuration(_stable()),
      took: sw.elapsed,
    );
  }

  /// Fine dell'audio: il tratto in corso diventa una frase.
  LiveStep flush() {
    final sw = Stopwatch()..start();
    vad.flush();
    final committed = _drain();
    _speechStart = null;
    _hadPartial = false;
    return LiveStep(
      committed: committed,
      partial: '',
      stableUntil: samplesToDuration(_fed),
      took: sw.elapsed,
    );
  }

  /// Fin dove l'audio è definitivo: l'inizio del parlato in corso,
  /// altrimenti la fine dell'audio meno il silenzio che il VAD aspetta.
  int _stable() {
    final s = _speechStart;
    if (s != null) return s;
    return math.max(_lastEnd, math.max(_origin, _fed - tail));
  }

  void _restart(int start) {
    vad.reset();
    _origin = start;
    _fed = start;
    _lastEnd = start;
    _speechStart = null;
    _lastPartialAt = start;
    _hadPartial = false;
    _bufLen = 0;
    _bufStart = start;
  }

  List<TranscriptSegment> _drain() {
    final out = <TranscriptSegment>[];
    while (vad.hasSegment) {
      final seg = vad.pop();
      if (seg.samples.isEmpty) continue;
      var at = _origin + seg.start;
      final end = at + seg.samples.length;
      // un po' di audio prima del tratto (se c'è ancora): il VAD a volte
      // taglia l'inizio della prima parola
      final from = math.max(math.max(at - pad, _lastEnd), _bufStart);
      final samples = from < at && end <= _bufStart + _bufLen
          ? _slice(from, end)
          : seg.samples;
      if (samples != seg.samples) at = from;
      if (end > _lastEnd) _lastEnd = end;
      _speechStart = null;
      _lastPartialAt = _fed;
      final d = decoder.decode(samples);
      out.addAll(
        splitSentences(d, samplesToDuration(at), samplesToDuration(end)),
      );
    }
    return out;
  }

  void _append(Float32List s) {
    if (_bufLen + s.length > _buf.length) {
      final grown = Float32List(math.max(_buf.length * 2, _bufLen + s.length));
      grown.setRange(0, _bufLen, _buf);
      _buf = grown;
    }
    _buf.setRange(_bufLen, _bufLen + s.length, s);
    _bufLen += s.length;
  }

  Float32List _slice(int from, int to) {
    final a = (from - _bufStart).clamp(0, _bufLen);
    final b = (to - _bufStart).clamp(a, _bufLen);
    return Float32List.sublistView(_buf, a, b);
  }

  /// Si tiene solo l'audio che può servire al testo provvisorio.
  void _trim() {
    final need = math.min(_speechStart ?? _fed, _fed - minPartial);
    final from = math.max(need, _fed - keep);
    final drop = from - _bufStart;
    if (drop <= _rate * 5) return;
    final n = math.min(drop, _bufLen);
    _buf.setRange(0, _bufLen - n, _buf, n);
    _bufLen -= n;
    _bufStart += n;
  }
}

final _sentenceEnd = RegExp(r'[.?!…]$');

/// Divide il testo di un tratto ([start]–[end]) in frasi alla punteggiatura,
/// con i tempi dei pezzi (token) di Parakeet. Frasi di una o due parole si
/// uniscono alla precedente; senza pezzi si ha una frase sola.
List<TranscriptSegment> splitSentences(
  DecodedText d,
  Duration start,
  Duration end,
) {
  final text = d.text.trim();
  if (text.isEmpty) return const [];
  final tokens = d.tokens;
  final ts = d.timestamps;
  if (tokens.isEmpty || ts.length != tokens.length) {
    return [TranscriptSegment(start, end, text)];
  }
  final out = <TranscriptSegment>[];
  final b = StringBuffer();
  var first = 0;
  void close(int nextIndex) {
    final t = b.toString().replaceAll('▁', ' ').trim();
    b.clear();
    if (t.isEmpty) return;
    final s = start + _secs(ts[first]);
    final e = nextIndex < tokens.length ? start + _secs(ts[nextIndex]) : end;
    final words = t.split(RegExp(r'\s+')).length;
    if (out.isNotEmpty && words <= 2) {
      final prev = out.removeLast();
      out.add(TranscriptSegment(prev.start, e, '${prev.text} $t'));
    } else {
      out.add(TranscriptSegment(s, e < s ? s : e, t));
    }
  }

  for (var i = 0; i < tokens.length; i++) {
    if (b.isEmpty) first = i;
    b.write(tokens[i]);
    final next = i + 1 < tokens.length ? tokens[i + 1] : null;
    // fine frase: punteggiatura e la parola dopo è nuova (o non c'è)
    if (_sentenceEnd.hasMatch(tokens[i].trim()) &&
        (next == null || next.startsWith('▁') || next.startsWith(' '))) {
      close(i + 1);
    }
  }
  close(tokens.length);
  if (out.isEmpty) return [TranscriptSegment(start, end, text)];
  // il primo e l'ultimo pezzo coprono tutto il tratto
  out[0] = out[0].copyWith(start: start);
  return out;
}

Duration _secs(double s) => Duration(microseconds: (s * 1e6).round());

/// Audio arrivato dal microfono e non ancora passato al riconoscitore
/// (lato interfaccia): si manda tutto insieme quando il riconoscitore è
/// libero. Se resta troppo indietro (PC occupato) si tiene solo l'audio
/// più recente e il tratto saltato si recupera dopo il salvataggio.
class PcmBacklog {
  PcmBacklog({
    this.maxBehind = 30 * _rate,
    this.keepOnDrop = 8 * _rate,
    this.minBatch = _rate ~/ 5,
  });

  /// Oltre questo ritardo (campioni) si salta.
  final int maxBehind;

  /// Audio tenuto quando si salta.
  final int keepOnDrop;

  /// Audio minimo da mandare (~0,2 s).
  final int minBatch;

  final List<Float32List> _chunks = [];
  int _start = 0;
  int _length = 0;

  /// Campioni in attesa.
  int get length => _length;

  /// Fine dell'audio ricevuto (campione della registrazione).
  int get end => _start + _length;

  /// Audio dal campione [at]; un buco (pezzi persi) fa ripartire da [at].
  void add(int at, Float32List samples) {
    if (samples.isEmpty) return;
    if (_length == 0 || at != end) {
      if (_length > 0) clear();
      _start = at;
    }
    _chunks.add(samples);
    _length += samples.length;
  }

  void clear() {
    _chunks.clear();
    _start = end;
    _length = 0;
  }

  /// Oltre [maxBehind] di attesa si tolgono i pezzi più vecchi finché ne
  /// restano ~[keepOnDrop]: il tratto tolto (campioni della registrazione),
  /// null se non serviva.
  ({int from, int to})? trim() {
    if (_length <= maxBehind) return null;
    final from = _start;
    while (_chunks.isNotEmpty && _length - _chunks.first.length >= keepOnDrop) {
      final c = _chunks.removeAt(0);
      _length -= c.length;
      _start += c.length;
    }
    return _start > from ? (from: from, to: _start) : null;
  }

  /// Audio da mandare (null se è troppo poco). [dropped] è il tratto
  /// saltato perché si era troppo indietro (campioni della registrazione).
  ({int start, Float32List samples, ({int from, int to})? dropped})? take() {
    final dropped = trim();
    if (_length < minBatch) return null;
    final all = Float32List(_length);
    var o = 0;
    for (final c in _chunks) {
      all.setRange(o, o + c.length, c);
      o += c.length;
    }
    final start = _start;
    _start += _length;
    _length = 0;
    _chunks.clear();
    return (start: start, samples: all, dropped: dropped);
  }
}

/// PCM 16 bit mono 16 kHz → valori -1…1 per sherpa-onnx.
Float32List int16ToFloat(Int16List s) {
  final out = Float32List(s.length);
  for (var i = 0; i < s.length; i++) {
    out[i] = s[i] / 32768.0;
  }
  return out;
}
