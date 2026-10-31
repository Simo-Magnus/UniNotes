import 'dart:math' as math;
import 'dart:typed_data';

import 'live_transcript.dart';
import 'recording_meta.dart';

/// Testo dal vivo confermato **per accordo** (LocalAgreement-2, come in
/// whisper_streaming di Macháček, Dabre e Bojar, 2023): logica pura, test in
/// test/live_agreement_test.dart.
///
/// Mentre si parla il riconoscitore ridecodifica più volte il tratto in
/// corso (Parakeet ogni ~0,75 s, il riconoscitore del sistema a ogni testo
/// provvisorio, Whisper ogni ~2 s). Le parole iniziali uguali in **due
/// ipotesi consecutive** diventano subito confermate: entrano nei segmenti
/// della trascrizione ([TranscriptMerger.segments]) e sono modificabili come
/// il resto; solo le parole dopo restano provvisorie ([pending], in grigio).
/// A fine frase ([finish]) il testo definitivo del riconoscitore sostituisce
/// le parole confermate (punteggiatura, maiuscole, correzioni), divise in
/// frasi con i loro tempi; le frasi già modificate dallo studente restano
/// come le ha scritte e le loro parole non si ripetono.
///
/// - Le parole confermate non tornano mai indietro durante la frase: se il
///   riconoscitore riscrive una parola già confermata, la correzione si
///   applica solo se è uguale in due ipotesi di fila e la frase non è stata
///   modificata a mano; le altre differenze si sistemano a fine frase.
/// - Se il riconoscitore riparte da capo (il testo nuovo non ha più niente
///   delle parole confermate) la frase si chiude così com'è e ne inizia una
///   nuova: niente doppioni.
/// - Ogni frase confermata è un segmento con l'inizio della sua prima parola
///   (chiave per l'editor, live_transcript_editor.dart): le parole nuove si
///   aggiungono all'ultimo segmento, o a uno nuovo dopo un punto o se lo
///   studente sta modificando l'ultimo.

/// Parola di un'ipotesi del riconoscitore, con i tempi della registrazione
/// se noti.
class HypWord {
  const HypWord(this.text, {this.start, this.end});
  final String text;
  final Duration? start;
  final Duration? end;

  HypWord withText(String t) => HypWord(t, start: start, end: end);

  @override
  String toString() => text;
}

final _space = RegExp(r'\s+');

/// Parole di [text]; con [from] i tempi si dividono fra le parole in
/// proporzione ai caratteri, fino a [to].
List<HypWord> wordsOfText(String text, {Duration? from, Duration? to}) {
  final words = text.split(_space).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  if (from == null) return [for (final w in words) HypWord(w)];
  final end = to == null || to < from ? from : to;
  final total = words.fold<int>(0, (a, w) => a + w.length + 1);
  final span = (end - from).inMicroseconds;
  final out = <HypWord>[];
  var at = 0;
  for (final w in words) {
    final s = from + Duration(microseconds: span * at ~/ total);
    at += w.length + 1;
    final e = from + Duration(microseconds: span * at ~/ total);
    out.add(HypWord(w, start: s, end: e));
  }
  return out;
}

/// Parole dei segmenti [segs], con i tempi di ognuno.
List<HypWord> wordsOfSegments(Iterable<TranscriptSegment> segs) => [
  for (final s in segs) ...wordsOfText(s.text, from: s.start, to: s.end),
];

final _sentenceEnd = RegExp(r'[.?!…]["»”’)\]]*$');

/// La parola chiude una frase (punto, punto di domanda…).
bool endsSentence(String word) => _sentenceEnd.hasMatch(word);

/// Divide [text] ([start]–[end]) in frasi alla punteggiatura, con i tempi
/// in proporzione ai caratteri; le frasi di una o due parole si uniscono
/// alla precedente (come `splitSentences` per Parakeet).
List<TranscriptSegment> splitTextSentences(
  String text,
  Duration start,
  Duration end,
) {
  final words = wordsOfText(text, from: start, to: end);
  if (words.isEmpty) return const [];
  final out = <TranscriptSegment>[];
  var from = 0;
  void close(int to) {
    if (to <= from) return;
    final ws = words.sublist(from, to);
    final t = ws.map((w) => w.text).join(' ');
    final s = from == 0 ? start : ws.first.start!;
    final e = to == words.length ? end : ws.last.end!;
    if (out.isNotEmpty && ws.length <= 2) {
      final prev = out.removeLast();
      out.add(TranscriptSegment(prev.start, e, '${prev.text} $t'));
    } else {
      out.add(TranscriptSegment(s, e < s ? s : e, t));
    }
    from = to;
  }

  for (var i = 0; i < words.length; i++) {
    if (endsSentence(words[i].text)) close(i + 1);
  }
  close(words.length);
  return out;
}

/// Allineamento delle parole confermate con un'ipotesi: costo, parole
/// confermate allineate ([cEnd], tutte salvo «riporto»), parole
/// dell'ipotesi corrispondenti ([hEnd]) e, per ogni parola confermata,
/// l'indice nell'ipotesi (-1 = non c'è più).
class WordAlignment {
  const WordAlignment(this.cost, this.cEnd, this.hEnd, this.map);
  final double cost;
  final int cEnd;
  final int hEnd;
  final List<int> map;
}

int _lev(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final c = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = math.min(math.min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + c);
    }
    prev = cur;
  }
  return prev[b.length];
}

/// Costo di sostituire la parola [a] con [b] (forme normalizzate): 0 uguali,
/// 0,5 simili (correzione: «teorema»/«teoremi»), 1 diverse.
double _sub(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty || b.isEmpty) return 1;
  final m = math.max(a.length, b.length);
  if (m >= 4 && _lev(a, b) <= m ~/ 3) return 0.5;
  return 1;
}

/// Allinea le parole [c] con l'inizio di [h] (forme normalizzate, distanza
/// di modifica a livello di parole): tutte le parole di [c], quelle di [h]
/// dopo restano fuori. Con [carry] le ultime parole di [c] possono restare
/// fuori se [h] finisce prima (testo definitivo più corto delle parole
/// confermate: le altre passano alla frase dopo).
WordAlignment alignWords(List<String> c, List<String> h, {bool carry = false}) {
  final n = c.length, m = h.length;
  final w = m + 1;
  final d = Float64List((n + 1) * w);
  final op = Uint8List((n + 1) * w);
  for (var j = 1; j <= m; j++) {
    d[j] = j.toDouble();
    op[j] = 2;
  }
  for (var i = 1; i <= n; i++) {
    d[i * w] = i.toDouble();
    op[i * w] = 1;
    for (var j = 1; j <= m; j++) {
      var best = d[(i - 1) * w + j - 1] + _sub(c[i - 1], h[j - 1]);
      var o = 0;
      final up = d[(i - 1) * w + j] + 1;
      final left = d[i * w + j - 1] + 1;
      if (up < best - 1e-9) {
        best = up;
        o = 1;
      }
      if (left < best - 1e-9) {
        best = left;
        o = 2;
      }
      d[i * w + j] = best;
      op[i * w + j] = o;
    }
  }
  var bi = n, bj = 0;
  var bc = d[n * w];
  for (var j = 1; j <= m; j++) {
    if (d[n * w + j] < bc - 1e-9) {
      bc = d[n * w + j];
      bj = j;
    }
  }
  if (carry) {
    for (var i = 0; i < n; i++) {
      if (d[i * w + m] < bc - 1e-9) {
        bc = d[i * w + m];
        bi = i;
        bj = m;
      }
    }
  }
  final map = List<int>.filled(bi, -1);
  var i = bi, j = bj;
  while (i > 0 || j > 0) {
    final o = op[i * w + j];
    if (i > 0 && j > 0 && o == 0) {
      map[i - 1] = j - 1;
      i--;
      j--;
    } else if (i > 0 && (o == 1 || j == 0)) {
      i--;
    } else {
      j--;
    }
  }
  return WordAlignment(bc, bi, bj, map);
}

List<String> _norms(List<HypWord> w) => [for (final x in w) normWord(x.text)];

/// Segmento confermato della frase in corso: chiave (inizio in ms) e
/// parole ([from], [to]) fra quelle confermate.
class _Live {
  _Live(this.key, this.from, this.to);
  final int key;
  int from;
  int to;

  /// Modificato dallo studente (o tolto/unito a mano): non si tocca più.
  bool frozen = false;

  /// Il segmento non c'è più (unito a un altro o cancellato).
  bool gone = false;
}

/// Tratto del testo definitivo che diventa una o più frasi nuove.
class _Run {
  _Run(this.key);
  int? key;
  final List<int> words = [];
}

/// Frase della frase in corso modificata a mano: resta com'è.
class _Kept {
  _Kept(this.key);
  final int key;
}

class LiveAgreement {
  LiveAgreement(this.merger, {required this.isEdited});

  /// Segmenti della trascrizione (quelli confermati si aggiungono qui).
  final TranscriptMerger merger;

  /// Il segmento che inizia a quei millisecondi è stato corretto a mano.
  final bool Function(int key) isEdited;

  final List<HypWord> _words = [];
  final List<_Live> _live = [];
  List<HypWord>? _prev;
  int _prevJ = 0;
  Map<int, String> _prevSubs = const {};

  /// Parole dell'ultima ipotesi non ancora confermate (testo provvisorio).
  String pending = '';

  List<TranscriptSegment> get _segs => merger.segments;

  /// C'è una frase in corso con parole confermate.
  bool get open => _words.isNotEmpty || _live.isNotEmpty;

  /// Parole confermate della frase in corso.
  int get confirmedCount => _words.length;

  /// Inizio della frase in corso (null se non ci sono parole confermate):
  /// prima di qui il testo non cambia più.
  Duration? get openFrom {
    _validate();
    for (final l in _live) {
      if (!l.gone) return Duration(milliseconds: l.key);
    }
    return null;
  }

  /// Fine dell'ultima parola confermata.
  Duration? get confirmedEnd =>
      _words.isEmpty ? null : (_words.last.end ?? _words.last.start);

  int _indexOf(int key) =>
      _segs.indexWhere((s) => s.start.inMilliseconds == key);

  void _validate() {
    for (final l in _live) {
      l.gone = _indexOf(l.key) < 0;
      l.frozen = l.gone || isEdited(l.key);
    }
  }

  _Live? _liveOf(int i) {
    for (final l in _live) {
      if (i >= l.from && i < l.to) return l;
    }
    return null;
  }

  /// Parole delle ultime frasi prima della frase in corso (per togliere la
  /// sovrapposizione fra due pezzi di audio).
  List<String> _beforeWords() {
    final first = _live.isEmpty ? null : _live.first.key;
    final before = [
      for (final s in _segs)
        if (first == null || s.start.inMilliseconds < first) s,
    ];
    return [
      for (final s in before.skip(math.max(0, before.length - 3)))
        ...s.text.split(_space).where((w) => w.isNotEmpty),
    ];
  }

  int _headDrop(List<HypWord> h) {
    if (h.isEmpty) return 0;
    final before = _beforeWords();
    if (before.isEmpty) return 0;
    return overlapWords(before, [for (final w in h) w.text]);
  }

  /// La frase in corso si chiude così com'è (niente testo definitivo: le
  /// parole confermate restano).
  void close() {
    _words.clear();
    _live.clear();
    _prev = null;
    _prevJ = 0;
    _prevSubs = const {};
    pending = '';
  }

  /// Nuova ipotesi [words] del tratto in corso (tutto, dall'inizio della
  /// frase), con l'audio fino a [now]. true se i segmenti sono cambiati.
  ///
  /// Con [restart] falso un'ipotesi molto diversa dalle parole confermate
  /// non chiude la frase: Parakeet ridecodifica sempre dallo stesso inizio
  /// del parlato, e su un audio difficile un'ipotesi può cambiare quasi
  /// tutta senza essere ripartita da capo. Chiudere lasciava le parole
  /// confermate accanto al testo definitivo, che poi arrivava per tutto il
  /// tratto: frasi doppie e sovrapposte (30/10/2026). Il testo definitivo
  /// a fine frase sostituisce comunque tutte le parole confermate.
  bool hypothesis(
    List<HypWord> words, {
    required Duration now,
    bool restart = true,
  }) {
    _validate();
    List<HypWord> clean() {
      final h = [
        for (final w in words)
          if (w.text.trim().isNotEmpty) w,
      ];
      return _words.isEmpty ? h.sublist(math.min(h.length, _headDrop(h))) : h;
    }

    var h = clean();
    if (h.isEmpty) {
      pending = '';
      return false;
    }
    var a = alignWords(_norms(_words), _norms(h));
    if (restart &&
        _words.isNotEmpty &&
        a.cost > math.max(2.0, 0.6 * _words.length)) {
      // il riconoscitore è ripartito da capo: le parole confermate restano
      // e questa è una frase nuova
      close();
      h = clean();
      a = alignWords(const [], _norms(h));
    }
    final j = a.hEnd;
    final tail = h.sublist(j);
    var k = 0;
    final prev = _prev;
    if (prev != null) {
      final pt = prev.sublist(math.min(_prevJ, prev.length));
      while (k < pt.length &&
          k < tail.length &&
          normWord(pt[k].text) == normWord(tail[k].text)) {
        k++;
      }
    }
    var touched = false;
    final subs = <int, String>{};
    for (var i = 0; i < a.cEnd; i++) {
      final m = a.map[i];
      if (m < 0) continue;
      final hw = h[m];
      final cw = _words[i];
      final hn = normWord(hw.text);
      final l = _liveOf(i);
      if (l == null || l.frozen) continue;
      if (hn == normWord(cw.text)) {
        // punteggiatura e maiuscole come nell'ultima conferma
        if (k > 0 && hw.text != cw.text) {
          _words[i] = cw.withText(hw.text);
          touched = true;
        }
      } else {
        subs[i] = hn;
        // il riconoscitore ha corretto la parola, uguale due volte di fila
        if (_prevSubs[i] == hn) {
          _words[i] = cw.withText(hw.text);
          touched = true;
        }
      }
    }
    if (k > 0) _append(tail.sublist(0, k), now);
    pending = tail.sublist(k).map((w) => w.text).join(' ');
    _prev = h;
    _prevJ = j + k;
    _prevSubs = subs;
    if (k > 0 || touched) {
      _rebuild(now);
      return true;
    }
    return false;
  }

  /// Primo inizio libero da [s] in poi (millisecondi interi, dopo l'ultimo
  /// segmento e diverso da tutti: è la chiave della frase).
  Duration _freeStart(Duration s) {
    var ms = s.inMilliseconds;
    if (_segs.isNotEmpty && ms <= _segs.last.start.inMilliseconds) {
      ms = _segs.last.start.inMilliseconds + 1;
    }
    while (_indexOf(ms) >= 0) {
      ms++;
    }
    return Duration(milliseconds: ms);
  }

  /// Nessuna frase finisce dopo l'inizio della seguente, dalla frase prima
  /// di [from] in poi: i tempi del testo definitivo e quelli delle parole
  /// confermate vengono da decodifiche diverse (e le parole confermate di
  /// un tratto senza testo definitivo restano). Si accorcia la fine,
  /// l'inizio (la chiave della frase) resta.
  void _clampEnds(Duration from) {
    var i = _segs.length - 1;
    while (i > 0 && _segs[i].start >= from) {
      i--;
    }
    for (; i + 1 < _segs.length; i++) {
      final s = _segs[i];
      final next = _segs[i + 1].start;
      if (s.end > next && next > s.start) _segs[i] = s.copyWith(end: next);
    }
  }

  void _insert(TranscriptSegment seg) {
    var i = _segs.length;
    while (i > 0 && _segs[i - 1].start > seg.start) {
      i--;
    }
    _segs.insert(i, seg);
  }

  void _append(List<HypWord> add, Duration now) {
    for (final w in add) {
      final idx = _words.length;
      _words.add(w);
      final l = _live.isEmpty ? null : _live.last;
      final startNew =
          l == null ||
          l.frozen ||
          l.to != idx ||
          (l.to - l.from >= 3 && endsSentence(_words[l.to - 1].text));
      if (!startNew) {
        l.to = idx + 1;
        continue;
      }
      final start = _freeStart(w.start ?? now);
      var end = w.end ?? now;
      if (end <= start) end = start + const Duration(milliseconds: 1);
      _insert(TranscriptSegment(start, end, w.text));
      _live.add(_Live(start.inMilliseconds, idx, idx + 1));
    }
  }

  /// Testo e fine dei segmenti confermati non modificati a mano.
  void _rebuild(Duration now) {
    for (final l in _live) {
      if (l.frozen || l.from >= l.to) continue;
      final i = _indexOf(l.key);
      if (i < 0) continue;
      final ws = _words.sublist(l.from, l.to);
      final text = ws.map((w) => w.text).join(' ');
      final s = _segs[i];
      var end = ws.last.end ?? now;
      if (end <= s.start) end = s.start + const Duration(milliseconds: 1);
      if (s.text != text || s.end != end) {
        _segs[i] = s.copyWith(text: text, end: end);
      }
    }
    if (_live.isNotEmpty) _clampEnds(Duration(milliseconds: _live.first.key));
  }

  /// Fine della frase: [finals] è il testo definitivo del riconoscitore
  /// (frasi con i tempi della registrazione). Sostituisce le parole
  /// confermate non modificate a mano, senza ripetere quelle delle frasi
  /// modificate. Con [carry] il testo definitivo può finire prima delle
  /// parole confermate (Whisper con la finestra piena: l'ultima frase resta
  /// provvisoria) e quelle in più passano alla frase dopo. true se i
  /// segmenti sono cambiati.
  bool finish(
    List<TranscriptSegment> finals, {
    bool carry = false,
    Duration? now,
  }) {
    _validate();
    final f = [
      for (final s in finals)
        if (s.text.trim().isNotEmpty && !isHallucination(s.text))
          s.copyWith(text: s.text.trim()),
    ]..sort((a, b) => a.start.compareTo(b.start));
    if (!open) {
      close();
      if (f.isEmpty) return false;
      merger.add(f);
      _clampEnds(f.first.start);
      return true;
    }
    if (f.isEmpty) {
      // niente testo definitivo: le parole confermate restano
      close();
      return false;
    }
    final fw = <HypWord>[];
    final fs = <int>[];
    for (var k = 0; k < f.length; k++) {
      final ws = wordsOfText(f[k].text, from: f[k].start, to: f[k].end);
      fw.addAll(ws);
      fs.addAll(List<int>.filled(ws.length, k));
    }
    final a = alignWords(_norms(_words), _norms(fw), carry: carry);
    // q[i]: dove inizia nel testo definitivo la parola confermata i
    final q = List<int>.filled(_words.length + 1, a.hEnd);
    for (var i = a.cEnd - 1; i >= 0; i--) {
      final m = a.map[i];
      q[i] = m >= 0 ? m : q[i + 1];
    }
    // parole iniziali non confermate che ripetono la frase prima
    final head = math.min(
      overlapWords(_beforeWords(), [for (final w in fw) w.text]),
      q[0],
    );
    final firstKey = _live.isEmpty ? null : _live.first.key;
    Duration? lower;
    for (final s in _segs) {
      if (firstKey != null && s.start.inMilliseconds >= firstKey) break;
      lower = s.start;
    }

    final items = <Object>[];
    _Run? run;
    var pos = head;
    void take(int to, int? key) {
      if (to <= pos && key == null) return;
      final r = run ??= () {
        final n = _Run(key);
        items.add(n);
        return n;
      }();
      r.key ??= key;
      for (var x = pos; x < to; x++) {
        r.words.add(x);
      }
      if (to > pos) pos = to;
    }

    final keepAsIs = <int>{};
    final nextLive = <_Live>[];
    var straddle = 0;
    for (final l in _live) {
      final mTo = math.min(l.to, a.cEnd);
      if (l.from < a.cEnd) {
        if (l.frozen) {
          if (!l.gone) {
            items.add(_Kept(l.key));
            keepAsIs.add(l.key);
          }
          run = null;
          if (q[mTo] > pos) pos = q[mTo];
        } else {
          take(q[mTo], l.key);
        }
      }
      if (l.to > a.cEnd) {
        // parole confermate oltre il testo definitivo (solo con [carry])
        if (l.from >= a.cEnd) {
          keepAsIs.add(l.key);
          nextLive.add(
            _Live(l.key, l.from - a.cEnd, l.to - a.cEnd)
              ..frozen = l.frozen
              ..gone = l.gone,
          );
        } else if (l.frozen) {
          nextLive.add(
            _Live(l.key, 0, l.to - a.cEnd)
              ..frozen = true
              ..gone = l.gone,
          );
        } else {
          straddle = l.to - a.cEnd;
        }
      }
    }
    // testo definitivo dopo le parole confermate
    if (fw.length > pos) take(fw.length, null);

    _segs.removeWhere((s) {
      final k = s.start.inMilliseconds;
      return _live.any((l) => l.key == k) && !keepAsIs.contains(k);
    });

    final liveStartAt = <int, int>{
      for (final l in _live)
        if (!l.frozen && l.from < a.cEnd && a.map[l.from] >= 0)
          a.map[l.from]: l.key,
    };
    final emitted = <TranscriptSegment>[];
    for (var it = 0; it < items.length; it++) {
      final item = items[it];
      if (item is _Kept) {
        lower = Duration(milliseconds: item.key);
        continue;
      }
      final r = item as _Run;
      if (r.words.isEmpty) continue;
      Duration? upper;
      for (var u = it + 1; u < items.length; u++) {
        final x = items[u];
        if (x is _Kept) {
          upper = Duration(milliseconds: x.key);
          break;
        }
      }
      // frasi del testo definitivo dentro il tratto
      var pa = 0;
      var first = true;
      while (pa < r.words.length) {
        var pb = pa + 1;
        while (pb < r.words.length && fs[r.words[pb]] == fs[r.words[pa]]) {
          pb++;
        }
        final wa = r.words[pa], wb = r.words[pb - 1];
        final text = [for (var x = pa; x < pb; x++) fw[r.words[x]].text]
            .join(' ');
        Duration start;
        if (first && r.key != null) {
          start = Duration(milliseconds: r.key!);
        } else if (liveStartAt[wa] case final k?) {
          start = Duration(milliseconds: k);
        } else if (wa == 0 || fs[wa - 1] != fs[wa]) {
          start = f[fs[wa]].start;
        } else {
          start = fw[wa].start ?? (lower ?? Duration.zero);
        }
        start = Duration(milliseconds: start.inMilliseconds);
        final lo = lower;
        if (lo != null && start <= lo) {
          start = lo + const Duration(milliseconds: 1);
        }
        while (emitted.any((e) => e.start == start) ||
            (_indexOf(start.inMilliseconds) >= 0)) {
          start += const Duration(milliseconds: 1);
        }
        final endsSeg = wb + 1 >= fw.length || fs[wb + 1] != fs[wb];
        var end = endsSeg ? f[fs[wb]].end : (fw[wb].end ?? start);
        if (end < start) end = start;
        final up = upper;
        if (!first && up != null && start >= up && emitted.isNotEmpty) {
          // non c'è posto prima della frase modificata: con la precedente
          final prev = emitted.removeLast();
          emitted.add(prev.copyWith(text: '${prev.text} $text', end: end));
        } else {
          emitted.add(TranscriptSegment(start, end, text));
          lower = start;
        }
        first = false;
        pa = pb;
      }
    }
    _segs.addAll(emitted);
    _segs.sort((x, y) => x.start.compareTo(y.start));
    if (emitted.isNotEmpty) _clampEnds(emitted.first.start);

    if (carry && a.cEnd < _words.length) {
      final rest = _words.sublist(a.cEnd);
      _words
        ..clear()
        ..addAll(rest);
      _live
        ..clear()
        ..addAll(nextLive);
      if (straddle > 0) {
        _live.sort((x, y) => x.from.compareTo(y.from));
        final next = _live.isEmpty ? null : _live.first;
        if (next != null && !next.frozen) {
          // le parole rimaste vanno con la frase confermata che segue
          next.from = 0;
        } else {
          final ws = rest.sublist(0, straddle);
          final start = _freeStart(ws.first.start ?? now ?? Duration.zero);
          var end = ws.last.end ?? now ?? start;
          if (end <= start) end = start + const Duration(milliseconds: 1);
          _insert(
            TranscriptSegment(start, end, ws.map((w) => w.text).join(' ')),
          );
          _live.insert(0, _Live(start.inMilliseconds, 0, straddle));
        }
      }
      _live.sort((x, y) => x.from.compareTo(y.from));
      _prev = null;
      _prevJ = 0;
      _prevSubs = const {};
      pending = '';
      _rebuild(now ?? confirmedEnd ?? Duration.zero);
    } else {
      close();
    }
    return true;
  }
}
