import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../features/notes/recorder/wav.dart';
import 'whisper_service.dart';

/// Trascrizione di una registrazione intera con Whisper a **pezzi brevi
/// tagliati alle pause** (fino a ~25 s, una finestra di Whisper), ognuno
/// trascritto da solo, senza il testo del pezzo prima.
///
/// Con pezzi lunghi (10 minuti, o il file intero con `whisper-cli`)
/// whisper.cpp passa a ogni finestra di 30 s il testo della precedente: con
/// audio lontano o rumoroso basta una frase sbagliata perché si ripeta per
/// minuti («Non è un'imposte.» ×60 nella lezione vera del 29/10/2026). A
/// pezzi brevi un errore resta nel suo pezzo; un pezzo che esce comunque «a
/// ciclo» ([looksLooped]) si ritrascrive in due metà e, se resta a ciclo, si
/// tiene una sola copia delle ripetizioni ([withoutLoops]).
///
/// Misure (large-v3-turbo q5_0, CPU, 33 frasi in fila, 393 s): microfono
/// lontano 8,0% di parole sbagliate, lontano con rumore 24,4%, nessun pezzo
/// a ciclo; il rilevatore di voce (VAD) sui pezzi peggiorava (9,0% e
/// 30,2%), come la riduzione del rumore prima di Whisper (32,5%).
/// docs/registratore.md, «Trascrizione dopo la registrazione».
const kWhisperChunkMax = Duration(seconds: 25);

/// Finestre di misura del livello (30 ms).
const _frame = Duration(milliseconds: 30);
const _frameSamples = 480;

/// Lunghezza minima di un pezzo mandato a Whisper (1,5 s a 16 kHz).
const _minSamples = 24000;

/// Livello (dB rispetto al fondo scala) di ogni finestra di 30 ms del WAV,
/// letto a tratti di 60 s (le lezioni durano ore: mai tutto in memoria).
Future<Float64List> frameLevels(File wav, WavInfo info) async {
  final total = info.duration;
  final out = <double>[];
  const step = Duration(seconds: 60);
  var carry = Int16List(0);
  for (var at = Duration.zero; at < total; at += step) {
    final end = at + step < total ? at + step : total;
    final mono = toMono16k(
      await readWavRange(wav, info, at, end),
      info.sampleRate,
      info.channels,
    );
    final s = carry.isEmpty
        ? mono
        : (Int16List(carry.length + mono.length)
            ..setAll(0, carry)
            ..setAll(carry.length, mono));
    var i = 0;
    for (; i + _frameSamples <= s.length; i += _frameSamples) {
      var sum = 0.0;
      for (var k = i; k < i + _frameSamples; k++) {
        sum += s[k] * s[k];
      }
      out.add(_db(math.sqrt(sum / _frameSamples)));
    }
    carry = Int16List.fromList(s.sublist(i));
  }
  return Float64List.fromList(out);
}

double _db(double rms) => 20 * math.log(rms / 32768 + 1e-9) / math.ln10;

/// Un pezzo della registrazione; [speech] false = solo silenzio o fondo
/// della stanza (non va a Whisper, che lì scriverebbe frasi inventate): il
/// 90% delle sue finestre sta sotto il fondo del file + 6 dB **e** sotto
/// −35 dBFS. Il fondo è il livello sotto cui sta il 10% delle finestre del
/// file; con il livello medio, rumori forti vicini al microfono facevano
/// sembrare silenzio il parlato lontano, e in un file quasi senza pause il
/// fondo è il parlato stesso: per questo serve anche il limite assoluto.
/// Nel dubbio il pezzo si trascrive.
class AudioChunk {
  const AudioChunk(this.start, this.end, {this.speech = true});
  final Duration start;
  final Duration end;
  final bool speech;
}

/// Pausa lunga: da almeno 3 s il pezzo si taglia sempre, ai due lati della
/// pausa (con [_pausePad] di margine), e la pausa diventa un pezzo a sé,
/// che va a Whisper solo se dentro c'è qualcosa più forte del fondo (di
/// solito è silenzio). Costa un po' di tempo in più (~20% di pezzi in più
/// nelle lezioni vere con tante pause: ogni pezzo costa come 30 s di
/// audio), ma Whisper non unisce più frasi lontane. Con la pausa dentro il
/// pezzo Whisper univa la frase prima e quella dopo e ne perdeva dei tratti
/// («ma mi… [5 s di silenzio] …delle dinamiche» → «ma ha delle dinamiche»,
/// lezione vera del 30/10/2026); un silenzio all'inizio del pezzo faceva
/// partire la prima frase da 0 s invece che da quando si parla.
const kWhisperLongPause = Duration(seconds: 3);
const _pausePad = Duration(milliseconds: 300);

/// Pezzi di al massimo [max], tagliati al centro delle pause (almeno 360 ms
/// sotto il livello medio del file meno 12 dB) e sempre ai due lati delle
/// pause lunghe ([kWhisperLongPause]). Dove non c'è una pausa il taglio
/// cade nel punto più basso (150 ms) fra il 60% di [max] e [max] (15–25 s),
/// cioè fra due parole, non a metà di una («super pro|dotti» diventava
/// «super progetti. prodotti»). Mai pezzi più corti di 3 s, salvo l'ultimo
/// prima di una pausa lunga e quello alla fine.
List<AudioChunk> planChunks(
  Float64List levels,
  Duration total, {
  Duration max = kWhisperChunkMax,
}) {
  if (total <= Duration.zero) return const [];
  final cuts = <Duration>[];
  // pause lunghe: tratti da non unire alle frasi intorno
  final long = <(Duration, Duration)>[];
  var threshold = double.negativeInfinity;
  if (levels.isNotEmpty) {
    // livello medio dell'energia (non dei dB): il parlato pesa più dei silenzi
    var power = 0.0;
    for (final l in levels) {
      power += math.pow(10, l / 10);
    }
    threshold = 10 * math.log(power / levels.length + 1e-18) / math.ln10 - 12;
    const minPause = 12; // finestre da 30 ms
    final longPause = kWhisperLongPause.inMicroseconds ~/ _frame.inMicroseconds;
    var run = 0;
    for (var i = 0; i <= levels.length; i++) {
      if (i < levels.length && levels[i] < threshold) {
        run++;
        continue;
      }
      if (run >= minPause) cuts.add(_frame * (i - run ~/ 2));
      if (run >= longPause) {
        final a = i - run == 0 ? Duration.zero : _frame * (i - run) + _pausePad;
        final b = i == levels.length ? total : _frame * i - _pausePad;
        if (b > a && a < total) long.add((a, b < total ? b : total));
      }
      run = 0;
    }
  }
  final quiet = levels.isEmpty
      ? double.negativeInfinity
      : math.min(
          (Float64List.fromList(levels)..sort())[levels.length ~/ 10] + 6,
          -35.0,
        );
  bool speech(Duration a, Duration b) {
    if (levels.isEmpty) return true;
    final from = (a.inMicroseconds ~/ _frame.inMicroseconds).clamp(
      0,
      levels.length,
    );
    final to = (b.inMicroseconds ~/ _frame.inMicroseconds).clamp(
      0,
      levels.length,
    );
    if (to <= from) return true;
    final own = Float64List.sublistView(levels, from, to).toList()..sort();
    return own[(own.length * 9) ~/ 10] >= quiet;
  }

  // una pausa lunga va a Whisper solo con qualcosa di più forte del fondo:
  // il 10% più forte delle sue finestre entro 22 dB dal livello medio (una
  // domanda dal fondo dell'aula sì, il fondo della stanza no). Da sola
  // Whisper sul fondo scrive frasi inventate e ogni pezzo costa come 30 s.
  bool voiced(Duration a, Duration b) {
    if (!speech(a, b)) return false;
    final from = (a.inMicroseconds ~/ _frame.inMicroseconds).clamp(
      0,
      levels.length,
    );
    final to = (b.inMicroseconds ~/ _frame.inMicroseconds).clamp(
      0,
      levels.length,
    );
    if (to <= from) return false;
    final own = Float64List.sublistView(levels, from, to).toList()..sort();
    return own[(own.length * 9) ~/ 10] >= threshold - 10;
  }

  final out = <AudioChunk>[];
  var k = 0;
  // pezzi da [from] a [to] (dentro non c'è una pausa lunga, o è la pausa)
  void fill(Duration from, Duration to, {bool pause = false}) {
    bool talk(Duration a, Duration b) => pause ? voiced(a, b) : speech(a, b);
    var start = from;
    while (to - start > max) {
      Duration? cut;
      for (; k < cuts.length && cuts[k] <= start + max; k++) {
        if (cuts[k] > start + const Duration(seconds: 3) && cuts[k] < to) {
          cut = cuts[k];
        }
      }
      final end =
          cut ??
          _quietest(levels, start + max * 0.6, start + max) ??
          start + max;
      out.add(AudioChunk(start, end, speech: talk(start, end)));
      start = end;
    }
    if (to > start) out.add(AudioChunk(start, to, speech: talk(start, to)));
  }

  var at = Duration.zero;
  for (final (a, b) in long) {
    if (a > at) fill(at, a);
    fill(a > at ? a : at, b, pause: true);
    at = b;
  }
  if (total > at) fill(at, total);
  return out;
}

/// Centro della finestra di 150 ms più bassa fra [from] e [to] (la più
/// tarda a parità di livello); null senza livelli in quel tratto.
Duration? _quietest(Float64List levels, Duration from, Duration to) {
  const span = 5; // finestre da 30 ms
  final a = math.max(0, from.inMicroseconds ~/ _frame.inMicroseconds);
  final b = math.min(levels.length, to.inMicroseconds ~/ _frame.inMicroseconds);
  if (b - a < span) return null;
  var sum = 0.0;
  for (var i = a; i < a + span; i++) {
    sum += math.pow(10, levels[i] / 10);
  }
  var best = sum;
  var bestAt = a;
  for (var i = a + span; i < b; i++) {
    sum += math.pow(10, levels[i] / 10) - math.pow(10, levels[i - span] / 10);
    if (sum <= best) {
      best = sum;
      bestAt = i - span + 1;
    }
  }
  return _frame * (bestAt + span ~/ 2);
}

/// Trascrive i WAV 16 kHz mono [parts] uno dopo l'altro (stesso modello,
/// nessun testo passato da un pezzo all'altro) e restituisce i segmenti di
/// ognuno, con i tempi del pezzo; [onProgress] riceve la frazione fatta
/// (0–1) del gruppo.
typedef ChunkRunner = Future<List<List<WhisperSegment>>> Function(
  List<File> parts,
  void Function(double fraction) onProgress,
);

/// Pezzi per gruppo passato a [ChunkRunner] (un processo `whisper-cli` per
/// gruppo: il modello si carica una volta ogni ~8 minuti di audio).
const kWhisperChunkGroup = 20;

/// Trascrizione di [wav] a pezzi brevi ([planChunks]) con [run]: tempi
/// riportati alla registrazione intera, pezzi a ciclo ritrascritti in due
/// metà ([looksLooped], [withoutLoops]), segmenti divisi alle fine delle
/// frasi ([splitSentences]), frasi del silenzio tolte ([isSilenceFiller]).
/// I WAV dei pezzi stanno in [tmp] solo il tempo del loro gruppo.
Future<List<WhisperSegment>> transcribeInChunks(
  File wav,
  WavInfo info,
  Directory tmp,
  ChunkRunner run, {
  void Function(WhisperProgress)? onProgress,
  CancelToken? cancel,
}) async {
  void checkCancel() {
    if (cancel?.isCancelled ?? false) throw DownloadCancelled();
  }

  onProgress?.call(const WhisperProgress('Cerco le pause…', null));
  final total = info.duration;
  final chunks = planChunks(await frameLevels(wav, info), total);
  final todo = [
    for (final c in chunks)
      if (c.speech) c,
  ];
  final out = <WhisperSegment>[];
  if (todo.isEmpty) return out;
  var n = 0;
  Future<File> write(Duration a, Duration b, String name) async {
    var mono = toMono16k(
      await readWavRange(wav, info, a, b),
      info.sampleRate,
      info.channels,
    );
    // whisper.cpp non trascrive meno di 1 s di audio: un pezzo corto fra
    // due pause lunghe («Sì.») si allunga con del silenzio in fondo
    if (mono.length < _minSamples) {
      mono = Int16List(_minSamples)..setAll(0, mono);
    }
    return writeWav16k(File(p.join(tmp.path, '$name.wav')), mono);
  }

  void report(double groupDone, int groupSize) {
    final f = (n + groupDone * groupSize) / todo.length;
    onProgress?.call(
      WhisperProgress('Trascrizione con Whisper: ${(f * 100).floor()}%', f),
    );
  }

  report(0, 0);
  for (var g = 0; g < todo.length; g += kWhisperChunkGroup) {
    checkCancel();
    final group = todo.sublist(
      g,
      math.min(g + kWhisperChunkGroup, todo.length),
    );
    final files = [
      for (var i = 0; i < group.length; i++)
        await write(group[i].start, group[i].end, 'pezzo_${g + i}'),
    ];
    final results = await run(files, (f) => report(f, group.length));
    for (final f in files) {
      try {
        await f.delete();
      } catch (_) {}
    }
    for (var i = 0; i < group.length; i++) {
      final c = group[i];
      var segs = splitSentences(
        i < results.length ? results[i] : const <WhisperSegment>[],
      );
      if (looksLooped(segs.map((s) => s.text).join(' '))) {
        checkCancel();
        // a ciclo: si ritrascrive in due metà, ognuna da sola
        final mid = c.start + (c.end - c.start) ~/ 2;
        final halves = [
          await write(c.start, mid, 'meta_${g + i}_a'),
          await write(mid, c.end, 'meta_${g + i}_b'),
        ];
        final again = await run(halves, (_) {});
        for (final f in halves) {
          try {
            await f.delete();
          } catch (_) {}
        }
        final a = splitSentences(
          again.isNotEmpty ? again[0] : const <WhisperSegment>[],
        );
        final b = splitSentences(
          again.length > 1 ? again[1] : const <WhisperSegment>[],
        );
        segs = [
          ...a,
          for (final s in b)
            WhisperSegment(
              s.start + (mid - c.start),
              s.text,
              end: s.end == null ? null : s.end! + (mid - c.start),
            ),
        ];
        final text = segs.map((s) => s.text).join(' ');
        if (looksLooped(text)) {
          segs = splitSentences([
            WhisperSegment(
              Duration.zero,
              withoutLoops(text),
              end: c.end - c.start,
            ),
          ]);
        }
      }
      for (final s in segs) {
        final t = withoutFillers(s.text);
        if (t.isEmpty) continue;
        final end = s.end == null ? null : c.start + s.end!;
        out.add(
          WhisperSegment(
            c.start + s.start,
            t,
            end: end != null && end > c.end ? c.end : end,
          ),
        );
      }
    }
    n += group.length;
    report(0, 0);
  }
  return out;
}

final _words = RegExp(r'[\p{L}\p{N}]+', unicode: true);
final _sentences = RegExp(r'(?<=[.!?…])\s+');

/// Il testo di un pezzo è «a ciclo»: la stessa frase almeno tre volte in
/// più, o la stessa sequenza di 4 parole almeno 3 volte (anche separate da
/// virgole: «e la sua vita è stata un'occhiata, e la sua vita…»).
bool looksLooped(String text) {
  final t = text.trim();
  if (t.length < 40) return false;
  final sentences = [
    for (final s in t.split(RegExp(r'[.!?…]')))
      if (s.trim().length > 8) s.trim().toLowerCase(),
  ];
  if (sentences.length - sentences.toSet().length >= 3) return true;
  final w = [for (final m in _words.allMatches(t.toLowerCase())) m.group(0)!];
  final counts = <String, int>{};
  for (var i = 0; i + 4 <= w.length; i++) {
    final k = w.sublist(i, i + 4).join(' ');
    final c = (counts[k] ?? 0) + 1;
    if (c >= 3) return true;
    counts[k] = c;
  }
  return false;
}

/// Toglie le ripetizioni di un testo a ciclo: le frasi già scritte e i
/// tratti di 2–10 parole ripetuti di fila almeno 3 volte (ne resta uno).
String withoutLoops(String text) {
  final seen = <String>{};
  final kept = <String>[];
  for (final s in text.trim().split(_sentences)) {
    final k = s.trim().toLowerCase();
    if (k.isEmpty || !seen.add(k)) continue;
    kept.add(s.trim());
  }
  final w = kept.join(' ').split(RegExp(r'\s+'));
  String key(String x) =>
      x.toLowerCase().replaceAll(RegExp(r'[,.;:!?…]+$'), '');
  bool same(int a, int b, int n) {
    if (b + n > w.length) return false;
    for (var j = 0; j < n; j++) {
      if (key(w[a + j]) != key(w[b + j])) return false;
    }
    return true;
  }

  final out = <String>[];
  var i = 0;
  while (i < w.length) {
    var skipped = false;
    for (var n = 10; n >= 2; n--) {
      if (i + n > w.length) continue;
      var r = 1;
      while (same(i, i + r * n, n)) {
        r++;
      }
      if (r >= 3) {
        out.addAll(w.sublist(i, i + n));
        i += r * n;
        skipped = true;
        break;
      }
    }
    if (!skipped) out.add(w[i++]);
  }
  return out.join(' ').trim();
}

/// Frasi che Whisper scrive da sole sul rumore o sui silenzi di un pezzo
/// («Grazie.», «Grazie a tutti.»: nella lezione vera del 29/10/2026 quattro
/// di fila). Solo come frase intera: dentro una frase della lezione restano.
final _fillers = RegExp(
  r'^(grazie( a tutti| mille| per l.attenzione)?|ciao( a tutti)?)$',
);

bool isSilenceFiller(String sentence) {
  final k = sentence.trim().toLowerCase().replaceAll(
    RegExp(r'[.!?,…\s]+$'),
    '',
  );
  return k.isEmpty || _fillers.hasMatch(k);
}

/// [text] senza le frasi del silenzio ([isSilenceFiller]).
String withoutFillers(String text) => [
  for (final s in text.trim().split(_sentences))
    if (!isSilenceFiller(s)) s.trim(),
].join(' ');

/// Segmento salvato più lungo del normale: oltre si divide alle virgole e,
/// se non bastano, fra le parole.
const kWhisperSentenceMax = Duration(seconds: 10);

/// Nessuna parte più corta di così quando si divide alle virgole o fra le
/// parole (le frasi intere sì).
const _minPart = Duration(seconds: 2);

/// Un punto in cui si può dividere un segmento: posizione nel testo, istante
/// e indice dell'ultimo token della parte prima (-1 se i tempi sono stimati).
typedef _Mark = ({int at, Duration time, int token});

final _sentenceMark = RegExp(r'[.!?…]+(?=\s)');
final _clauseMark = RegExp(r'[,;:](?=\s)');
final _wordMark = RegExp(r'\S(?=\s)');
final _sentenceToken = RegExp(r'[.!?…]$');
final _clauseToken = RegExp(r'[,;:]$');
final _anyToken = RegExp(r'');
final _space = RegExp(r'\s');

/// Divide i segmenti di Whisper a ogni fine di frase e, quelli che restano
/// più lunghi di [max], alle virgole (o fra le parole oltre 1,5 volte
/// [max]): Whisper scrive spesso un segmento solo per 15–30 s di parlato, e
/// nel lettore la frase in ascolto diventava un blocco di righe. I tempi
/// vengono dai token (`-ojf` di whisper-cli, [WhisperSegment.tokens]); senza
/// token (whisper.cpp nell'app) sono stimati in proporzione ai caratteri. Il
/// testo non cambia.
List<WhisperSegment> splitSentences(
  List<WhisperSegment> segments, {
  Duration max = kWhisperSentenceMax,
}) {
  final out = <WhisperSegment>[];
  for (final s in segments) {
    for (final sentence in _cutAt(
      s,
      _marks(s, _sentenceMark, _sentenceToken),
    )) {
      if (_length(sentence) <= max) {
        out.add(sentence);
        continue;
      }
      for (final clause in _cutAt(
        sentence,
        _pick(sentence, _marks(sentence, _clauseMark, _clauseToken), max),
      )) {
        out.addAll(
          _length(clause) <= max * 1.5
              ? [clause]
              : _cutAt(
                  clause,
                  _pick(clause, _marks(clause, _wordMark, _anyToken), max),
                ),
        );
      }
    }
  }
  return out;
}

Duration _length(WhisperSegment s) =>
    s.end == null ? Duration.zero : s.end! - s.start;

/// I punti di [s] dove il testo ha il segno [mark] seguito da uno spazio.
/// Con i token: il k-esimo token che finisce con quel segno ([token]) ed è
/// seguito da un token che comincia con uno spazio è il k-esimo punto del
/// testo (se il conto non torna, i tempi si stimano dai caratteri). Senza
/// token né fine: nessuno.
List<_Mark> _marks(WhisperSegment s, RegExp mark, RegExp token) {
  final at = [for (final m in mark.allMatches(s.text)) m.end];
  if (at.isEmpty) return const [];
  final ends = <(int, Duration)>[];
  int? last;
  for (var i = 0; i < s.tokens.length; i++) {
    final t = s.tokens[i];
    if (t.special) continue;
    if (last != null && t.text.startsWith(_space)) {
      final prev = s.tokens[last];
      if (token.hasMatch(prev.text.trimRight())) ends.add((last, prev.end));
    }
    last = i;
  }
  final end = s.end;
  if (ends.length == at.length) {
    return [
      for (var i = 0; i < at.length; i++)
        (at: at[i], time: ends[i].$2, token: ends[i].$1),
    ];
  }
  if (end == null || end <= s.start) return const [];
  final len = s.text.length;
  return [
    for (final a in at)
      (at: a, time: s.start + (end - s.start) * (a / len), token: -1),
  ];
}

/// Fra i punti [marks] di [s], quelli più vicini a una divisione in parti
/// uguali, abbastanza da stare sotto [max] (con margine), ognuna di almeno
/// [_minPart].
List<_Mark> _pick(WhisperSegment s, List<_Mark> marks, Duration max) {
  final end = s.end;
  if (end == null || marks.isEmpty) return const [];
  final total = end - s.start;
  final n = (total.inMicroseconds / (max.inMicroseconds * 0.85)).ceil();
  final out = <_Mark>[];
  var from = s.start;
  var i = 0;
  for (var j = 1; j < n; j++) {
    final target = s.start + total * (j / n);
    _Mark? best;
    for (; i < marks.length; i++) {
      final m = marks[i];
      if (m.time - from < _minPart) continue;
      if (end - m.time < _minPart) break;
      if (best != null &&
          (m.time - target).abs() > (best.time - target).abs()) {
        break;
      }
      best = m;
    }
    if (best == null) break;
    out.add(best);
    from = best.time;
  }
  return out;
}

/// [s] diviso nei punti [marks] (tempi sempre in ordine e dentro [s]; i
/// token vanno alla loro parte).
List<WhisperSegment> _cutAt(WhisperSegment s, List<_Mark> marks) {
  if (marks.isEmpty) return [s];
  final out = <WhisperSegment>[];
  var at = 0;
  var start = s.start;
  var token = 0;
  final end = s.end;
  void add(int to, Duration? until, int lastToken) {
    final text = s.text.substring(at, to).trim();
    var e = until;
    if (e != null) {
      if (end != null && e > end) e = end;
      if (e < start) e = start;
    }
    final tokens = lastToken < 0
        ? const <WhisperToken>[]
        : s.tokens.sublist(token, lastToken + 1);
    if (text.isNotEmpty) {
      out.add(WhisperSegment(start, text, end: e, tokens: tokens));
    }
    at = to;
    if (e != null) start = e;
    if (lastToken >= 0) token = lastToken + 1;
  }

  for (final m in marks) {
    add(m.at, m.time, m.token);
  }
  add(s.text.length, end, marks.last.token < 0 ? -1 : s.tokens.length - 1);
  return out;
}
