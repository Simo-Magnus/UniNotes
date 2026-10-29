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

/// Pezzi di al massimo [max], tagliati al centro delle pause (almeno 360 ms
/// sotto il livello medio del file meno 12 dB); dove non c'è una pausa il
/// taglio cade a [max]. Mai pezzi più corti di 3 s, salvo l'ultimo.
List<AudioChunk> planChunks(
  Float64List levels,
  Duration total, {
  Duration max = kWhisperChunkMax,
}) {
  if (total <= Duration.zero) return const [];
  final cuts = <Duration>[];
  var threshold = double.negativeInfinity;
  if (levels.isNotEmpty) {
    // livello medio dell'energia (non dei dB): il parlato pesa più dei silenzi
    var power = 0.0;
    for (final l in levels) {
      power += math.pow(10, l / 10);
    }
    threshold = 10 * math.log(power / levels.length + 1e-18) / math.ln10 - 12;
    const minPause = 12; // finestre da 30 ms
    var run = 0;
    for (var i = 0; i <= levels.length; i++) {
      if (i < levels.length && levels[i] < threshold) {
        run++;
        continue;
      }
      if (run >= minPause) cuts.add(_frame * (i - run ~/ 2));
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

  final out = <AudioChunk>[];
  var start = Duration.zero;
  var k = 0;
  while (total - start > max) {
    Duration? cut;
    for (; k < cuts.length && cuts[k] <= start + max; k++) {
      if (cuts[k] > start + const Duration(seconds: 3)) cut = cuts[k];
    }
    final end = cut ?? start + max;
    out.add(AudioChunk(start, end, speech: speech(start, end)));
    start = end;
  }
  out.add(AudioChunk(start, total, speech: speech(start, total)));
  return out;
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
/// metà ([looksLooped], [withoutLoops]), frasi del silenzio tolte
/// ([isSilenceFiller]). I WAV dei pezzi stanno in [tmp] solo il tempo del
/// loro gruppo.
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
  Future<File> write(Duration a, Duration b, String name) async => writeWav16k(
    File(p.join(tmp.path, '$name.wav')),
    toMono16k(
      await readWavRange(wav, info, a, b),
      info.sampleRate,
      info.channels,
    ),
  );
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
      var segs = i < results.length ? results[i] : const <WhisperSegment>[];
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
        final a = again.isNotEmpty ? again[0] : const <WhisperSegment>[];
        final b = again.length > 1 ? again[1] : const <WhisperSegment>[];
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
          segs = [
            WhisperSegment(
              Duration.zero,
              withoutLoops(text),
              end: c.end - c.start,
            ),
          ];
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
