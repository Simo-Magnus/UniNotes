import 'dart:math' as math;

import 'recording_meta.dart';

/// Trascrizione dal vivo: logica pura (test in test/recorder_logic_test.dart).
///
/// Mentre si registra, ogni [LiveChunkPlanner.window] di audio nuovo diventa
/// un pezzo da trascrivere, che inizia [LiveChunkPlanner.overlap] prima
/// (così una parola tagliata a metà si sente intera in uno dei due pezzi).
/// Se Whisper resta indietro, i pezzi in attesa più vecchi si saltano (la
/// trascrizione resta al passo col parlato) e si recuperano a fine
/// registrazione. Il testo dei pezzi si unisce senza ripetere le parole
/// della sovrapposizione ([TranscriptMerger]).

class LiveChunk {
  const LiveChunk(this.index, this.start, this.end);
  final int index;
  final Duration start;
  final Duration end;

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

class LiveChunkPlanner {
  LiveChunkPlanner({
    this.window = const Duration(seconds: 9),
    this.overlap = const Duration(seconds: 1),
    this.maxWaiting = 1,
  });

  /// Audio nuovo per pezzo (più la sovrapposizione: ~10 s in tutto).
  final Duration window;
  final Duration overlap;

  /// Pezzi che possono aspettare mentre Whisper lavora; oltre si saltano.
  final int maxWaiting;

  Duration _next = Duration.zero;
  int _count = 0;
  bool _busy = false;
  final List<LiveChunk> waiting = [];
  final List<LiveChunk> skipped = [];

  bool get busy => _busy;

  /// Fine dell'audio già assegnato a un pezzo.
  Duration get planned => _next;

  /// I pezzi partono da [t] (Whisper subentra a metà registrazione al
  /// riconoscitore del sistema: il tratto prima è già trascritto).
  void startAt(Duration t) {
    if (t > _next) _next = t;
  }

  LiveChunk _chunk(Duration end) {
    final start = _next - overlap;
    return LiveChunk(
      _count++,
      start < Duration.zero ? Duration.zero : start,
      end,
    );
  }

  /// C'è audio registrato fino a [recorded]: crea i pezzi completi.
  void advance(Duration recorded) {
    while (recorded - _next >= window) {
      final c = _chunk(_next + window);
      _next += window;
      waiting.add(c);
      while (waiting.length > maxWaiting) {
        skipped.add(waiting.removeAt(0));
      }
    }
  }

  /// Prossimo pezzo da trascrivere (null se Whisper è occupato o non c'è
  /// niente). Va chiuso con [done].
  LiveChunk? takeNext() {
    if (_busy || waiting.isEmpty) return null;
    _busy = true;
    return waiting.removeAt(0);
  }

  void done() => _busy = false;

  /// Fine registrazione a [recorded]: i pezzi ancora da fare, in ordine di
  /// tempo (saltati, in attesa e l'ultimo pezzo, se dura almeno [minTail]).
  List<LiveChunk> finish(
    Duration recorded, {
    Duration minTail = const Duration(milliseconds: 600),
  }) {
    final out = [...skipped, ...waiting];
    skipped.clear();
    waiting.clear();
    if (recorded - _next >= minTail) {
      out.add(_chunk(recorded));
      _next = recorded;
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

/// Unisce i pezzi trascritti in un'unica trascrizione ordinata per tempo,
/// senza doppioni nella sovrapposizione.
class TranscriptMerger {
  final List<TranscriptSegment> segments = [];

  String get text => segments.map((s) => s.text).join(' ');

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
    segments.insertAll(i, segs);
  }

  static String _joined(List<TranscriptSegment> s) =>
      s.map((x) => x.text).join(' ');

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
