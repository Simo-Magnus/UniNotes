import 'dart:math' as math;

import 'recording_meta.dart';

//// Trascrizione dal vivo con Whisper: logica pura (test in
/// test/recorder_logic_test.dart).
///
/// **Finestre corte che si allungano** ([LiveWindowPlanner]): ogni ~2 s di
/// audio nuovo si ritrascrive il tratto non ancora definitivo (da
/// [LiveWindowPlanner.anchor] a ora, al massimo
/// [LiveWindowPlanner.maxWindow]). Il testo della finestra è provvisorio e
/// si aggiorna a ogni passo; diventa definitivo a una pausa del parlato o
/// quando la finestra è piena (in quel caso l'ultima frase, forse tagliata
/// a metà parola, resta provvisoria e si ritrascrive nella finestra dopo).
/// Ogni finestra inizia [LiveWindowPlanner.overlap] prima: le parole
/// ripetute si tolgono unendo il testo ([TranscriptMerger]).
///
/// Se Whisper è lento il passo si allunga (meno lavoro, testo un po' meno
/// frequente); se resta comunque indietro, il tratto più vecchio si salta
/// (il testo resta al passo col parlato) e si recupera dopo il salvataggio.

class LiveChunk {
  const LiveChunk(this.index, this.start, this.end);
  final int index;
  final Duration start;
  final Duration end;

  Duration get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is LiveChunk &&
      other.index == index &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(index, start, end);

  @override
  String toString() =>
      'Pezzo $index (${start.inMilliseconds}–${end.inMilliseconds} ms)';
}

/// Cosa resta di una finestra trascritta: segmenti definitivi e testo
/// provvisorio (che la finestra successiva sostituisce).
class WindowOutcome {
  const WindowOutcome(this.committed, this.provisional);
  final List<TranscriptSegment> committed;
  final String provisional;

  static const empty = WindowOutcome([], '');
}

class LiveWindowPlanner {
  LiveWindowPlanner({
    this.step = const Duration(seconds: 2),
    this.maxStep = const Duration(seconds: 5),
    this.maxWindow = const Duration(seconds: 6),
    this.minWindow = const Duration(seconds: 1),
    this.overlap = const Duration(milliseconds: 300),
    this.keepLast = true,
    this.maxPiece = const Duration(seconds: 30),
  }) : _step = step;

  /// Modello lento (quello scelto dall'utente, se manca il modello dal
  /// vivo): pezzi da ~10 s (9 s nuovi + 1 s di sovrapposizione), ognuno
  /// definitivo appena trascritto.
  factory LiveWindowPlanner.slow() => LiveWindowPlanner(
    step: const Duration(seconds: 9),
    maxStep: const Duration(seconds: 9),
    maxWindow: const Duration(seconds: 9),
    minWindow: const Duration(seconds: 9),
    overlap: const Duration(seconds: 1),
    keepLast: false,
  );

  /// Audio nuovo che fa partire una nuova trascrizione (passo minimo).
  final Duration step;

  /// Passo massimo quando Whisper è lento.
  final Duration maxStep;

  /// Lunghezza massima del tratto provvisorio: oltre diventa definitivo.
  final Duration maxWindow;

  /// Finestra minima (meno audio non vale una trascrizione).
  final Duration minWindow;
  final Duration overlap;

  /// Finestra piena: l'ultima frase resta provvisoria e si ritrascrive.
  final bool keepLast;

  /// Pezzi da recuperare alla fine: al massimo così lunghi.
  final Duration maxPiece;

  /// Inizio dell'audio non ancora definitivo.
  Duration anchor = Duration.zero;
  Duration _decoded = Duration.zero;
  Duration _step;
  Duration? _avg;
  int _count = 0;
  bool _busy = false;

  /// Tratti saltati, da trascrivere a fine registrazione.
  final List<LiveChunk> skipped = [];

  /// Salti perché Whisper era indietro (non per l'attesa del modello
  /// all'inizio).
  int lagSkips = 0;

  bool get busy => _busy;

  /// Passo attuale (si allunga se Whisper è lento).
  Duration get currentStep => _step;

  /// Si parte da [t]: il tratto prima è già trascritto (Whisper subentra
  /// a metà registrazione al riconoscitore del sistema).
  void startAt(Duration t) {
    if (t > anchor) anchor = t;
    if (anchor > _decoded) _decoded = anchor;
  }

  /// Il tratto da [anchor] a [t] non si trascrive ora: si recupera alla
  /// fine (es. registrato mentre si scaricava il modello).
  void skipTo(Duration t) {
    if (t - anchor >= const Duration(milliseconds: 600)) {
      skipped.add(_chunk(anchor, t));
    }
    startAt(t);
  }

  LiveChunk _chunk(Duration start, Duration end) {
    final s = start - overlap;
    return LiveChunk(_count++, s < Duration.zero ? Duration.zero : s, end);
  }

  /// Prossima finestra da trascrivere con l'audio registrato fino a
  /// [recorded] (null se Whisper è occupato o non c'è abbastanza audio
  /// nuovo). Va chiusa con [done] o [abandon].
  LiveChunk? next(Duration recorded) {
    if (_busy) return null;
    // troppo indietro: il tratto vecchio si recupera alla fine
    if (recorded - anchor > maxWindow * 3) {
      skipTo(recorded - maxWindow);
      lagSkips++;
    }
    final full = anchor + maxWindow;
    final end = recorded < full ? recorded : full;
    if (end - anchor < minWindow || end <= _decoded) return null;
    if (end - _decoded < _step && end < full) return null;
    _busy = true;
    return _chunk(anchor, end);
  }

  /// La finestra in corso non ha dato un risultato (errore, fine
  /// registrazione).
  void abandon() => _busy = false;

  /// Risultato della finestra [c]: [segments] con i tempi della
  /// registrazione, [silentTail] se finisce in una pausa, [took] quanto ha
  /// impiegato Whisper.
  WindowOutcome done(
    LiveChunk c,
    List<TranscriptSegment> segments, {
    bool silentTail = false,
    Duration? took,
  }) {
    _busy = false;
    if (c.end > _decoded) _decoded = c.end;
    if (took != null) _adapt(took);
    final segs = [
      for (final s in segments)
        if (!isHallucination(s.text)) s.copyWith(text: s.text.trim()),
    ];
    final full = c.end - anchor >= maxWindow;
    if (segs.isEmpty) {
      // silenzio o niente di comprensibile: la finestra non si allunga
      if (silentTail || full) startAt(c.end);
      return WindowOutcome.empty;
    }
    if (full && keepLast && !silentTail && segs.length > 1) {
      final last = segs.last;
      if (last.start > anchor + minWindow && last.start < c.end) {
        anchor = last.start;
        return WindowOutcome(segs.sublist(0, segs.length - 1), last.text);
      }
    }
    if (full || silentTail) {
      startAt(c.end);
      return WindowOutcome(segs, '');
    }
    return WindowOutcome(const [], segs.map((s) => s.text).join(' '));
  }

  void _adapt(Duration took) {
    final prev = _avg;
    final avg = prev == null
        ? took
        : Duration(
            microseconds:
                (prev.inMicroseconds * 0.7 + took.inMicroseconds * 0.3).round(),
          );
    _avg = avg;
    var s = Duration(microseconds: (avg.inMicroseconds * 1.2).round());
    if (s < step) s = step;
    if (s > maxStep) s = maxStep;
    _step = s;
  }

  /// Fine registrazione a [recorded]: i tratti ancora da trascrivere, in
  /// ordine di tempo (saltati e quello non ancora definitivo, se dura
  /// almeno [minTail]), divisi in pezzi di al massimo [maxPiece].
  List<LiveChunk> finish(
    Duration recorded, {
    Duration minTail = const Duration(milliseconds: 600),
  }) {
    final raw = [...skipped];
    skipped.clear();
    if (recorded - anchor >= minTail) raw.add(_chunk(anchor, recorded));
    startAt(recorded);
    _busy = false;
    final out = <LiveChunk>[];
    for (final c in raw) {
      if (c.length <= maxPiece + overlap) {
        out.add(c);
        continue;
      }
      var s = c.start;
      while (s < c.end) {
        var e = s + maxPiece;
        if (c.end - e < const Duration(seconds: 2)) e = c.end;
        out.add(LiveChunk(_count++, s, e));
        if (e >= c.end) break;
        s = e - overlap;
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }
}

final _notWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// Parola confrontabile: minuscole, senza punteggiatura.
String normWord(String w) => w.toLowerCase().replaceAll(_notWord, '');

List<String> _words(String t) =>
    t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

/// Quante parole togliere dall'inizio di [next] perché ripetono la fine di
/// [prev] (la sovrapposizione fra due pezzi). Cerca la ripetizione più
/// lunga (fino a [maxWords] parole), anche spostata di qualche parola
/// all'inizio di [next] (Whisper a volte aggiunge o perde una parola al
/// bordo del pezzo).
int overlapWords(
  List<String> prev,
  List<String> next, {
  int maxWords = 12,
  int maxShift = 3,
}) {
  final a = [for (final w in prev) normWord(w)];
  final b = [for (final w in next) normWord(w)];
  final maxL = math.min(maxWords, math.min(a.length, b.length));
  for (var len = maxL; len >= 1; len--) {
    for (var shift = 0; shift <= maxShift; shift++) {
      if (shift + len > b.length) break;
      // una sola parola corta coincidente non basta (es. «e», «di»)
      if (len == 1 && (shift > 0 || a.last.length < 4)) continue;
      if (len == 2 && shift > 1) continue;
      var same = true;
      for (var k = 0; k < len; k++) {
        if (a[a.length - len + k] != b[shift + k] ||
            a[a.length - len + k].isEmpty) {
          same = false;
          break;
        }
      }
      if (same) return shift + len;
    }
  }
  return 0;
}

/// Toglie dalla fine di [segs] le parole che ripetono l'inizio di [nextText]
/// (pezzo recuperato a fine registrazione, che sta prima di uno già
/// trascritto).
List<TranscriptSegment> _trimTail(
  List<TranscriptSegment> segs,
  String nextText,
) {
  if (segs.isEmpty) return segs;
  final next = _words(nextText);
  final out = [...segs];
  // confronto «al contrario»: la fine del nuovo con l'inizio del successivo
  final tail = <String>[];
  for (final s in out) {
    tail.addAll(_words(s.text));
  }
  final drop = overlapWords(
    next.reversed.toList(),
    tail.reversed.toList(),
    maxShift: 2,
  );
  var left = drop;
  while (left > 0 && out.isNotEmpty) {
    final w = _words(out.last.text);
    if (w.length <= left) {
      left -= w.length;
      out.removeLast();
    } else {
      out[out.length - 1] = out.last.copyWith(
        text: w.sublist(0, w.length - left).join(' '),
      );
      left = 0;
    }
  }
  return out;
}

/// Frasi che Whisper «inventa» sui silenzi (sottotitoli dei video su cui è
/// stato addestrato).
const _hallucinations = [
  'sottotitoli creati dalla comunità amara.org',
  'sottotitoli a cura di',
  'sottotitoli e revisione a cura di',
  'grazie per la visione',
  'grazie a tutti per la visione',
  'iscriviti al canale',
  'thank you for watching',
  'amara.org',
];

bool isHallucination(String text) {
  final t = text.toLowerCase().trim();
  if (t.isEmpty) return true;
  if (RegExp(r'^[\[\(].*[\]\)]$').hasMatch(t)) return true; // [Musica]
  return _hallucinations.any(t.contains);
}

final _sentenceEnd = RegExp(r'[.!?…]["»”’)\]]*$');
final _leadingCapital = RegExp(
  r'^([^\p{L}\p{N}]*)(\p{Lu})(\p{Ll}*)(?=$|[^\p{L}\p{N}])',
  unicode: true,
);
final _titleWord = RegExp(r'^\p{Lu}\p{Ll}+$', unicode: true);
final _wordEdges = RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true);

/// Parole con la sola iniziale maiuscola che in [text] stanno a metà frase
/// (non dopo un punto): nomi propri, in minuscolo.
Iterable<String> midSentenceNames(String text) sync* {
  final words = text.split(RegExp(r'\s+'));
  for (var k = 1; k < words.length; k++) {
    if (_sentenceEnd.hasMatch(words[k - 1])) continue;
    final w = words[k].replaceAll(_wordEdges, '');
    if (_titleWord.hasMatch(w)) yield w.toLowerCase();
  }
}

/// Unisce i pezzi trascritti in un'unica trascrizione ordinata per tempo,
/// senza doppioni nella sovrapposizione.
///
/// Il riconoscitore del telefono restituisce ogni pezzo con la maiuscola,
/// anche quando continua la frase di prima: se il testo precedente non
/// finisce con un punto (`.`, `!`, `?`, `…`) l'iniziale torna minuscola,
/// tranne per i nomi propri noti ([properNames]: dal vocabolario
/// dell'insegnamento e dalle parole già viste con la maiuscola a metà frase),
/// le sigle e le parole con maiuscole interne («PDF», «UniNotes»), e «I»
/// nelle lezioni in inglese ([english]).
class TranscriptMerger {
  final List<TranscriptSegment> segments = [];

  /// Nomi propri noti, in minuscolo.
  final Set<String> properNames = {};

  /// Lezione in inglese: «I» resta maiuscola.
  bool english = false;

  String get text => segments.map((s) => s.text).join(' ');

  /// [text] con l'iniziale minuscola se continua [before] (che non finisce
  /// con un punto) e non è un nome proprio noto.
  String continueSentence(String text, String? before) {
    if (before == null || before.trim().isEmpty) return text;
    if (_sentenceEnd.hasMatch(before.trimRight())) return text;
    final m = _leadingCapital.firstMatch(text);
    if (m == null) return text;
    final word = '${m[2]}${m[3]}';
    if (english && word == 'I') return text;
    if (properNames.contains(word.toLowerCase())) return text;
    return '${m[1]}${m[2]!.toLowerCase()}${m[3]}${text.substring(m.end)}';
  }

  /// Rifà le iniziali (vedi [continueSentence]) dei segmenti da [from] in
  /// poi, per le modifiche che non passano da [add]: parole confermate per
  /// accordo, testo definitivo di fine frase, seconda passata. I segmenti
  /// per cui [skip] è vero (corretti a mano) non si toccano. Solo
  /// maiuscole che diventano minuscole: rifarlo non cambia niente. true se
  /// qualcosa è cambiato.
  bool recase({int from = 1, bool Function(TranscriptSegment s)? skip}) {
    final start = math.max(1, from);
    for (var i = math.max(0, start - 1); i < segments.length; i++) {
      properNames.addAll(midSentenceNames(segments[i].text));
    }
    var changed = false;
    for (var i = start; i < segments.length; i++) {
      final s = segments[i];
      if (skip != null && skip(s)) continue;
      final t = continueSentence(s.text, segments[i - 1].text);
      if (t != s.text) {
        segments[i] = s.copyWith(text: t);
        changed = true;
      }
    }
    return changed;
  }

  /// Aggiunge i segmenti di un pezzo (tempi già riferiti alla
  /// registrazione intera).
  void add(List<TranscriptSegment> chunk) {
    var segs = [
      for (final s in chunk)
        if (!isHallucination(s.text)) s.copyWith(text: s.text.trim()),
    ];
    if (segs.isEmpty) return;
    segs.sort((a, b) => a.start.compareTo(b.start));
    final at = segs.first.start;
    // posizione: dopo l'ultimo segmento iniziato prima del pezzo
    var i = segments.length;
    while (i > 0 && segments[i - 1].start > at) {
      i--;
    }
    // inizio ripetuto rispetto a quanto c'è già prima
    if (i > 0) {
      final prev = <String>[];
      for (var k = math.max(0, i - 3); k < i; k++) {
        prev.addAll(_words(segments[k].text));
      }
      segs = _trimHead(segs, overlapWords(prev, _words(_joined(segs))));
    }
    // fine ripetuta rispetto a quanto c'è già dopo (pezzo recuperato)
    if (i < segments.length && segs.isNotEmpty) {
      final next = segments
          .sublist(i, math.min(segments.length, i + 3))
          .map((s) => s.text)
          .join(' ');
      segs = _trimTail(segs, next);
    }
    for (final s in segs) {
      properNames.addAll(midSentenceNames(s.text));
    }
    var before = i > 0 ? segments[i - 1].text : null;
    for (var k = 0; k < segs.length; k++) {
      final t = continueSentence(segs[k].text, before);
      if (t != segs[k].text) segs[k] = segs[k].copyWith(text: t);
      before = t;
    }
    segments.insertAll(i, segs);
  }

  static String _joined(List<TranscriptSegment> s) =>
      s.map((x) => x.text).join(' ');

  /// [texts] (pezzi in ordine, es. i segmenti di una trascrizione fatta dopo
  /// il salvataggio con Whisper o Parakeet) con l'iniziale minuscola dove il
  /// pezzo continua la frase del precedente, come in [add]; [names]: nomi
  /// propri noti (vocabolario dell'insegnamento).
  static List<String> recaseTexts(
    List<String> texts, {
    bool english = false,
    Iterable<String> names = const [],
  }) {
    final m = TranscriptMerger()..english = english;
    for (final n in names) {
      m.properNames.addAll(midSentenceNames(n));
    }
    for (final t in texts) {
      m.properNames.addAll(midSentenceNames(t));
    }
    final out = <String>[];
    String? before;
    for (final t in texts) {
      final r = m.continueSentence(t, before);
      out.add(r);
      before = r;
    }
    return out;
  }

  static List<TranscriptSegment> _trimHead(
    List<TranscriptSegment> segs,
    int drop,
  ) {
    final out = <TranscriptSegment>[];
    var left = drop;
    for (final s in segs) {
      if (left == 0) {
        out.add(s);
        continue;
      }
      final w = _words(s.text);
      if (w.length <= left) {
        left -= w.length;
        continue;
      }
      out.add(s.copyWith(text: w.sublist(left).join(' ')));
      left = 0;
    }
    return out;
  }
}
