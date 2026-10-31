import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'live_agreement.dart';
import 'recording_meta.dart';

/// Testo dal vivo guidato dalle pause (Parakeet su desktop): logica pura,
/// senza FFI (test in test/parakeet_live_test.dart con VAD e decodificatore
/// finti; quelli veri di sherpa-onnx sono in core/services/parakeet_engine.dart).
///
/// 1. L'audio della registrazione (mono 16 kHz) passa da un rilevatore di
///    voce ([SpeechVad], Silero VAD): i silenzi non producono testo.
/// 2. Mentre si parla, ogni [VadLiveSegmenter.partialEvery] (~0,75 s) di
///    audio nuovo si decodifica il tratto di parlato in corso: è
///    un'**ipotesi**, con le parole e i loro tempi ([LiveStep.partialWords]).
///    Le parole uguali in due ipotesi di fila diventano subito confermate e
///    modificabili (live_agreement.dart), il resto è il testo provvisorio.
/// 3. A una pausa il tratto diventa **definitivo**, decodificato una volta
///    sola con tutto il suo audio e diviso in frasi alla punteggiatura
///    ([splitSentences]), con i tempi della registrazione: sostituisce le
///    parole confermate (salvo le frasi già corrette a mano). Dal vivo, dopo
///    ~12 s di parlato senza pause ([VadLiveSegmenter.softMax]) il tratto si
///    chiude nel punto più silenzioso degli ultimi secondi invece di
///    aspettare il taglio forzato del VAD (18 s, anche a metà parola).
/// 4. Parakeet riceve ogni tratto con 0,25 s di silenzio digitale prima e
///    dopo ([VadLiveSegmenter.silencePad]): senza, sull'audio vero perde
///    spesso le prime parole dopo un silenzio o restituisce un testo vuoto
///    (misure del 30/10/2026 in docs/registratore.md). Se il testo
///    definitivo è vuoto o molto più corto dell'ultima ipotesi, si riprova
///    una volta con 1 s di silenzio e si tiene il testo più lungo.

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
    this.partialWords = const [],
    this.speaking = false,
    this.stableUntil = Duration.zero,
    this.took = Duration.zero,
  });
  final List<TranscriptSegment> committed;
  final String? partial;

  /// Parole di [partial] con i tempi della registrazione (dai pezzi di
  /// Parakeet).
  final List<HypWord> partialWords;
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
    this.partialEvery = 12000,
    this.minPartial = 8000,
    this.lead = 2 * 512 + 4000,
    this.tail = 8000 + 1024,
    this.keep = 40 * _rate,
    this.pad = 4800,
    this.silencePad = 4000,
    this.retryPad = _rate,
    this.softMax = 12 * _rate,
    this.minCut = 5 * _rate,
  });

  /// Audio aggiunto prima di ogni tratto del VAD (~0,3 s).
  final int pad;

  /// Silenzio digitale (zeri) prima e dopo l'audio dato a Parakeet (0,25 s):
  /// i tempi dei pezzi restano quelli dell'audio vero.
  final int silencePad;

  /// Silenzio del secondo tentativo, se il testo definitivo è vuoto o molto
  /// più corto dell'ultima ipotesi (1 s).
  final int retryPad;

  /// Parlato senza pause oltre il quale, dal vivo, il tratto si chiude nel
  /// punto più silenzioso (~12 s; 0 = mai): ipotesi su al massimo ~12 s di
  /// audio (calcolo limitato) e niente taglio forzato a metà parola.
  final int softMax;

  /// Il punto di taglio è almeno così dopo l'inizio del tratto (~5 s).
  final int minCut;

  final SpeechVad vad;
  final SpeechDecoder decoder;

  /// Audio nuovo (campioni) fra due ipotesi (~0,75 s: una parola detta è
  /// confermata, per accordo fra due ipotesi, entro ~1–2 s).
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
    if (partial && softMax > 0) committed.addAll(_softCut());
    String? text;
    var words = const <HypWord>[];
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
        final d = _decode(_slice(s, _fed), silencePad);
        final ws = collapseRepeatedWords(
          wordsOfDecoded(d, samplesToDuration(s), samplesToDuration(_fed)),
        );
        // ipotesi vuota a metà del parlato (Parakeet a volte non dà niente
        // anche con la voce): il testo provvisorio resta quello di prima.
        // Prima diventava «fine della frase» e le parole già confermate
        // restavano accanto al testo definitivo, doppie (30/10/2026)
        if (ws.isNotEmpty) {
          words = ws;
          text = ws.map((w) => w.text).join(' ');
          _hyp = [
            for (final w in ws)
              w.start == null ? s : durationToSamples(w.start!),
          ];
          final h = _hypHead;
          if (ws.length >= 3 && (h == null || _hyp.first < h)) {
            _hypHead = _hyp.first;
          }
          _hadPartial = true;
        }
      }
    } else {
      _speechStart = null;
      if (_hadPartial && text == null) text = '';
      _hadPartial = false;
      _hyp = const [];
      _hypHead = null;
    }
    if (text != null && text.isEmpty) _hadPartial = false;
    _trim();
    return LiveStep(
      committed: committed,
      partial: text,
      partialWords: words,
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
    _hyp = const [];
    _hypHead = null;
    _bufLen = 0;
    _bufStart = start;
  }

  /// Inizio delle parole dell'ultima ipotesi del tratto in corso (campioni
  /// della registrazione; vuoto = nessuna ipotesi).
  List<int> _hyp = const [];

  /// Inizio più presto di un'ipotesi di almeno 3 parole dello stesso
  /// parlato: se il testo definitivo inizia molto dopo, Parakeet ha perso
  /// le prime parole.
  int? _hypHead;

  List<TranscriptSegment> _drain() {
    final out = <TranscriptSegment>[];
    while (vad.hasSegment) {
      final seg = vad.pop();
      if (seg.samples.isEmpty) continue;
      final at = _origin + seg.start;
      final end = at + seg.samples.length;
      // dopo un taglio nel punto più silenzioso ([_softCut]) l'inizio del
      // tratto è già trascritto: solo l'audio dopo
      final first = math.max(at, _lastEnd);
      // un po' di audio prima del tratto (se c'è ancora): il VAD a volte
      // taglia l'inizio della prima parola
      final want = first > at ? first : math.max(at - pad, _lastEnd);
      var from = first;
      Float32List samples;
      if (want >= _bufStart && end <= _bufStart + _bufLen) {
        from = want;
        samples = _slice(from, end);
      } else {
        samples = first >= end
            ? Float32List(0)
            : Float32List.sublistView(seg.samples, first - at);
      }
      if (end > _lastEnd) _lastEnd = end;
      _speechStart = null;
      _lastPartialAt = _fed;
      final hyp = _hyp, head = _hypHead;
      _hyp = const [];
      _hypHead = null;
      if (samples.length < 1600) continue;
      out.addAll(_sentences(_final(samples, from, hyp, head), from, end));
    }
    return out;
  }

  /// Frasi del testo [d] dell'audio [from]–[to] (campioni della
  /// registrazione), senza le parole ripetute a ciclo.
  List<TranscriptSegment> _sentences(DecodedText d, int from, int to) => [
    for (final s in splitSentences(
      d,
      samplesToDuration(from),
      samplesToDuration(to),
    ))
      if (collapseRepeats(s.text) case final t when t.isNotEmpty)
        s.copyWith(text: t),
  ];

  /// Testo definitivo di [samples] (dal campione [from] della
  /// registrazione); [hyp] inizio delle parole dell'ultima ipotesi dello
  /// stesso parlato, [head] il primo inizio delle ipotesi ([_hypHead]).
  /// Vuoto, molto più corto dell'ipotesi o senza le prime parole (inizia
  /// ~0,8 s dopo [head]: Parakeet ha saltato un pezzo): un secondo
  /// tentativo con più silenzio intorno, si tiene il testo con più
  /// parole.
  DecodedText _final(Float32List samples, int from, List<int> hyp, int? head) {
    final d = _decode(samples, silencePad);
    final n = _wordCount(d.text);
    final ts = d.timestamps;
    final headLost =
        head != null &&
        ts.isNotEmpty &&
        ts.first.isFinite &&
        from + ts.first * _rate > head + _rate * 0.8;
    final short =
        headLost ||
        (hyp.length >= 4
            ? n * 2 < hyp.length
            : n == 0 && samples.length >= _rate);
    if (!short || retryPad <= 0 || retryPad == silencePad) return d;
    final r = _decode(samples, retryPad);
    return _wordCount(r.text) > n ? r : d;
  }

  /// [samples] decodificati con [silence] campioni di zeri prima e dopo; i
  /// tempi dei pezzi tornano quelli di [samples].
  DecodedText _decode(Float32List samples, int silence) {
    // meno di 0,1 s: niente da riconoscere
    if (samples.length < 1600) return const DecodedText('');
    if (silence <= 0) return decoder.decode(samples);
    final padded = Float32List(samples.length + 2 * silence)
      ..setRange(silence, silence + samples.length, samples);
    final d = decoder.decode(padded);
    final shift = silence / _rate;
    final max = samples.length / _rate;
    return DecodedText(
      d.text,
      tokens: d.tokens,
      timestamps: [
        for (final t in d.timestamps)
          t.isFinite ? (t - shift).clamp(0.0, max).toDouble() : t,
      ],
    );
  }

  /// Parlato continuo da più di [softMax]: si chiude il tratto nel punto
  /// più silenzioso fra [minCut] dall'inizio e ~0,4 s fa e il VAD riparte
  /// da lì (riceve di nuovo l'audio dopo il taglio), così non taglia da
  /// solo a 18 s, anche a metà parola. Le frasi fino al taglio sono
  /// definitive.
  List<TranscriptSegment> _softCut() {
    final s = _speechStart;
    if (s == null || !vad.speaking || _fed - s < softMax) return const [];
    final lo = math.max(s + minCut, _bufStart);
    final hi = math.min(s + softMax, _fed - 6400);
    if (hi - lo < 3200) return const [];
    final cut = _quietest(lo, hi);
    // le parole dell'ultima ipotesi prima del taglio
    final hyp = [
      for (final w in _hyp)
        if (w < cut) w,
    ];
    final head = _hypHead;
    final out = _sentences(
      _final(_slice(s, cut), s, hyp, head != null && head < cut ? head : null),
      s,
      cut,
    );
    _hypHead = null;
    _lastEnd = cut;
    _speechStart = cut;
    _hyp = const [];
    _hadPartial = false;
    _lastPartialAt = _fed;
    // il VAD riparte dal taglio: il suo tratto in corso inizierebbe prima
    vad.reset();
    _origin = cut;
    vad.accept(Float32List.fromList(_slice(cut, _fed)));
    // un tratto già chiuso nell'audio dato di nuovo (pausa subito dopo)
    out.addAll(_drain());
    _speechStart = vad.speaking ? math.max(cut, _lastEnd) : null;
    return out;
  }

  /// Centro della finestra di ~0,16 s con meno energia fra [from] e [to].
  int _quietest(int from, int to) {
    const frame = 320, win = 8;
    final a = (from - _bufStart).clamp(0, _bufLen);
    final b = (to - _bufStart).clamp(a, _bufLen);
    final n = (b - a) ~/ frame;
    if (n <= win) return from + (to - from) ~/ 2;
    final e = Float64List(n);
    for (var i = 0; i < n; i++) {
      var sum = 0.0;
      for (var k = a + i * frame, z = k + frame; k < z; k++) {
        final x = _buf[k];
        sum += x * x;
      }
      e[i] = sum;
    }
    var run = 0.0;
    for (var i = 0; i < win; i++) {
      run += e[i];
    }
    var best = run, at = 0;
    for (var i = win; i < n; i++) {
      run += e[i] - e[i - win];
      // a parità di energia il punto più avanti (tratto più lungo)
      if (run <= best) {
        best = run;
        at = i - win + 1;
      }
    }
    return _bufStart + a + (at + win ~/ 2) * frame;
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

/// Tempi del decodificatore (FFI): NaN o infiniti valgono 0 invece di far
/// fallire la frase.
Duration _secs(double s) =>
    s.isFinite ? Duration(microseconds: (s * 1e6).round()) : Duration.zero;

final _blank = RegExp(r'\s+');

/// Parole del testo decodificato [d] (audio da [origin] a [end] della
/// registrazione) con l'inizio di ognuna dai tempi dei pezzi (token): un
/// pezzo che inizia con «▁» (o uno spazio) apre una parola nuova, la
/// punteggiatura resta attaccata alla parola prima. Senza pezzi i tempi si
/// stimano in proporzione ai caratteri.
List<HypWord> wordsOfDecoded(DecodedText d, Duration origin, Duration end) {
  final tokens = d.tokens;
  final ts = d.timestamps;
  if (tokens.isEmpty || ts.length != tokens.length) {
    return wordsOfText(d.text.trim(), from: origin, to: end);
  }
  final texts = <String>[];
  final starts = <Duration>[];
  var space = true;
  for (var i = 0; i < tokens.length; i++) {
    final piece = tokens[i].replaceAll('▁', ' ');
    final clean = piece.trim();
    if (clean.isEmpty) {
      space = true;
      continue;
    }
    if (space || texts.isEmpty || piece.startsWith(' ')) {
      texts.add(clean);
      starts.add(origin + _secs(ts[i]));
    } else {
      texts[texts.length - 1] += clean;
    }
    space = piece.endsWith(' ');
  }
  final expect = d.text.trim().split(_blank).where((w) => w.isNotEmpty);
  if (texts.length != expect.length) {
    return wordsOfText(d.text.trim(), from: origin, to: end);
  }
  return [
    for (var i = 0; i < texts.length; i++)
      HypWord(
        texts[i],
        start: starts[i],
        end: i + 1 < texts.length ? starts[i + 1] : end,
      ),
  ];
}

int _wordCount(String text) =>
    text.trim().split(_blank).where((w) => w.isNotEmpty).length;

final _edgePunct = RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true);

/// Parole [keys] da tenere senza le ripetizioni a ciclo di Parakeet sul
/// rumore («stando stando stando stando stando»): una parola ripetuta di
/// fila 4 volte o più, o un gruppo di 2–6 parole ripetuto 3 volte o più,
/// resta una volta sola (l'ultima, con la sua punteggiatura). «piano
/// piano» e «bene, bene, bene» restano. Per ogni parola tenuta: il suo
/// indice e quello della parola corrispondente nella prima ripetizione
/// (per l'inizio).
List<(int, int)> _withoutLoops(List<String> keys) {
  final out = <(int, int)>[];
  bool same(int a, int b, int n) {
    if (b + n > keys.length) return false;
    for (var j = 0; j < n; j++) {
      if (keys[a + j].isEmpty || keys[a + j] != keys[b + j]) return false;
    }
    return true;
  }

  var i = 0;
  while (i < keys.length) {
    var done = false;
    for (var n = 6; n >= 1; n--) {
      if (i + n > keys.length) continue;
      var r = 1;
      while (same(i, i + r * n, n)) {
        r++;
      }
      if (r >= (n == 1 ? 4 : 3)) {
        for (var j = 0; j < n; j++) {
          out.add((i + (r - 1) * n + j, i + j));
        }
        i += r * n;
        done = true;
        break;
      }
    }
    if (!done) {
      out.add((i, i));
      i++;
    }
  }
  return out;
}

String _key(String w) => w.toLowerCase().replaceAll(_edgePunct, '');

/// [text] senza le parole ripetute a ciclo ([_withoutLoops]).
String collapseRepeats(String text) {
  final w = text.trim().split(_blank).where((x) => x.isNotEmpty).toList();
  final keep = _withoutLoops([for (final x in w) _key(x)]);
  if (keep.length == w.length) return text.trim();
  return [for (final (k, _) in keep) w[k]].join(' ');
}

/// Le parole [words] di un'ipotesi senza le ripetizioni a ciclo: con
/// l'inizio della prima ripetizione e il testo dell'ultima.
List<HypWord> collapseRepeatedWords(List<HypWord> words) {
  final keep = _withoutLoops([for (final w in words) _key(w.text)]);
  if (keep.length == words.length) return words;
  return [
    for (final (k, first) in keep)
      first == k
          ? words[k]
          : HypWord(
              words[k].text,
              start: words[first].start,
              end: words[k].end,
            ),
  ];
}

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
