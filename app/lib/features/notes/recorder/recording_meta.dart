import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Dati di una registrazione salvati accanto all'audio, con lo stesso nome
/// ed estensione `.json` (`Registrazioni/2026-10-05 08-30 Lezione.json`):
/// segnalibri, segmenti della trascrizione con i tempi, forma d'onda e
/// durata. Il file si rinomina, si sincronizza e va nel cestino insieme alla
/// registrazione; le registrazioni senza questo file restano leggibili (la
/// trascrizione Markdown resta quella di sempre).

/// Segmento della trascrizione con inizio e fine nella registrazione.
class TranscriptSegment {
  const TranscriptSegment(this.start, this.end, this.text);
  final Duration start;
  final Duration end;
  final String text;

  TranscriptSegment copyWith({Duration? start, Duration? end, String? text}) =>
      TranscriptSegment(
        start ?? this.start,
        end ?? this.end,
        text ?? this.text,
      );

  Map<String, Object?> toJson() => {
    's': start.inMilliseconds,
    'e': end.inMilliseconds,
    't': text,
  };

  static TranscriptSegment? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['s'], e = j['e'], t = j['t'];
    if (s is! num || t is! String) return null;
    return TranscriptSegment(
      Duration(milliseconds: s.toInt()),
      Duration(milliseconds: (e is num ? e : s).toInt()),
      t,
    );
  }

  @override
  String toString() => '[${start.inMilliseconds}-${end.inMilliseconds}] $text';
}

/// Segnalibro: un istante della registrazione con una nota facoltativa.
class Bookmark {
  const Bookmark(this.at, [this.note = '']);
  final Duration at;
  final String note;

  Bookmark withNote(String n) => Bookmark(at, n.trim());

  Map<String, Object?> toJson() => {
    'ms': at.inMilliseconds,
    if (note.isNotEmpty) 'nota': note,
  };

  static Bookmark? fromJson(Object? j) {
    if (j is! Map || j['ms'] is! num) return null;
    return Bookmark(
      Duration(milliseconds: (j['ms'] as num).toInt()),
      j['nota'] is String ? j['nota'] as String : '',
    );
  }
}

class RecordingMeta {
  RecordingMeta({
    this.duration,
    this.started,
    this.course,
    List<Bookmark>? bookmarks,
    List<TranscriptSegment>? segments,
    this.transcriptSource,
    this.peaks,
    this.peakEvery = const Duration(milliseconds: 100),
  }) : bookmarks = bookmarks ?? [],
       segments = segments ?? [];

  static const version = 1;

  Duration? duration;
  DateTime? started;
  String? course;
  List<Bookmark> bookmarks;
  List<TranscriptSegment> segments;

  /// Chi ha prodotto i segmenti: `dal vivo` o `whisper <modello>`.
  String? transcriptSource;

  /// Forma d'onda: un livello 0–255 ogni [peakEvery].
  Uint8List? peaks;
  Duration peakEvery;

  bool get isEmpty =>
      bookmarks.isEmpty &&
      segments.isEmpty &&
      (peaks == null || peaks!.isEmpty) &&
      duration == null;

  static File sidecarOf(String audioPath) =>
      File(p.setExtension(audioPath, '.json'));

  Map<String, Object?> toJson() => {
    'versione': version,
    if (duration != null) 'durataMs': duration!.inMilliseconds,
    if (started != null) 'inizio': started!.toIso8601String(),
    if (course != null) 'corso': course,
    if (bookmarks.isNotEmpty)
      'segnalibri': [for (final b in bookmarks) b.toJson()],
    if (segments.isNotEmpty) 'segmenti': [for (final s in segments) s.toJson()],
    if (transcriptSource != null) 'trascrizione': transcriptSource,
    if (peaks != null && peaks!.isNotEmpty) ...{
      'formaOnda': base64Encode(peaks!),
      'formaOndaMs': peakEvery.inMilliseconds,
    },
  };

  static RecordingMeta fromJson(Map<Object?, Object?> j) {
    Uint8List? peaks;
    if (j['formaOnda'] is String) {
      try {
        peaks = base64Decode(j['formaOnda'] as String);
      } on FormatException {
        peaks = null;
      }
    }
    return RecordingMeta(
      duration: j['durataMs'] is num
          ? Duration(milliseconds: (j['durataMs'] as num).toInt())
          : null,
      started: DateTime.tryParse('${j['inizio'] ?? ''}'),
      course: j['corso'] is String ? j['corso'] as String : null,
      bookmarks: [
        for (final b in (j['segnalibri'] as List? ?? const []))
          ?Bookmark.fromJson(b),
      ]..sort((a, b) => a.at.compareTo(b.at)),
      segments: [
        for (final s in (j['segmenti'] as List? ?? const []))
          ?TranscriptSegment.fromJson(s),
      ]..sort((a, b) => a.start.compareTo(b.start)),
      transcriptSource: j['trascrizione'] is String
          ? j['trascrizione'] as String
          : null,
      peaks: peaks,
      peakEvery: Duration(
        milliseconds:
            (j['formaOndaMs'] is num ? (j['formaOndaMs'] as num).toInt() : 100)
                .clamp(10, 10000),
      ),
    );
  }

  /// Dati della registrazione [audioPath] (vuoti se il file manca o è
  /// illeggibile).
  static Future<RecordingMeta> load(String audioPath) async {
    final f = sidecarOf(audioPath);
    try {
      if (!await f.exists()) return RecordingMeta();
      final j = jsonDecode(await f.readAsString());
      return j is Map ? fromJson(j) : RecordingMeta();
    } catch (_) {
      return RecordingMeta();
    }
  }

  /// Scrittura sicura (file temporaneo poi rinominato).
  Future<void> save(String audioPath) async {
    final f = sidecarOf(audioPath);
    final tmp = File('${f.path}.part');
    await tmp.writeAsString(jsonEncode(toJson()));
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }
}

/// «1:05:09» o «05:09».
String clockLabel(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s ~/ 60) % 60, sec = s % 60;
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

final _stamp = RegExp(r'^\[(\d{1,2}):(\d{2}):(\d{2})\]\s*(.*)$');

/// Segmenti di una trascrizione Markdown dell'app (paragrafi che iniziano
/// con `[hh:mm:ss]`): la fine di ognuno è l'inizio del successivo (l'ultimo
/// finisce a [total], se nota). Vuoto se il testo non ha i tempi.
List<TranscriptSegment> segmentsFromMarkdown(String md, {Duration? total}) {
  final starts = <(Duration, String)>[];
  for (final raw in const LineSplitter().convert(md)) {
    final m = _stamp.firstMatch(raw.trim());
    if (m == null) {
      // righe che continuano il paragrafo precedente
      final t = raw.trim();
      if (starts.isNotEmpty && t.isNotEmpty && !t.startsWith('#')) {
        final last = starts.removeLast();
        starts.add((last.$1, '${last.$2} $t'.trim()));
      }
      continue;
    }
    final at = Duration(
      hours: int.parse(m.group(1)!),
      minutes: int.parse(m.group(2)!),
      seconds: int.parse(m.group(3)!),
    );
    starts.add((at, m.group(4)!.trim()));
  }
  return [
    for (var i = 0; i < starts.length; i++)
      if (starts[i].$2.isNotEmpty)
        TranscriptSegment(
          starts[i].$1,
          i + 1 < starts.length
              ? starts[i + 1].$1
              : (total ?? starts[i].$1 + const Duration(minutes: 2)),
          starts[i].$2,
        ),
  ];
}

/// Indice del segmento in corso all'istante [t] (l'ultimo iniziato), −1
/// prima del primo. [segments] ordinati per inizio.
int segmentIndexAt(List<TranscriptSegment> segments, Duration t) {
  var lo = 0, hi = segments.length - 1, found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (segments[mid].start <= t) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

/// «Salta silenzi»: se [pos] cade in un tratto silenzioso lungo almeno
/// [minRun] (livelli sotto [threshold]), restituisce dove riprendere (poco
/// prima della fine del silenzio); altrimenti null.
Duration? silenceSkipTarget(
  Uint8List peaks,
  Duration every,
  Duration pos, {
  int threshold = 40,
  Duration minRun = const Duration(milliseconds: 1500),
  Duration margin = const Duration(milliseconds: 250),
}) {
  if (peaks.isEmpty || every <= Duration.zero) return null;
  final i = pos.inMicroseconds ~/ every.inMicroseconds;
  if (i < 0 || i >= peaks.length || peaks[i] >= threshold) return null;
  var a = i, b = i;
  while (a > 0 && peaks[a - 1] < threshold) {
    a--;
  }
  while (b + 1 < peaks.length && peaks[b + 1] < threshold) {
    b++;
  }
  final runLen = every * (b - a + 1);
  if (runLen < minRun) return null;
  final end = every * (b + 1);
  final target = end - margin;
  return target > pos + const Duration(milliseconds: 200) ? target : null;
}

/// Tratti tenuti dopo un taglio: [keepStart]–[keepEnd] se [removeInside] è
/// falso, altrimenti tutto tranne quel tratto.
List<(Duration, Duration)> keptRanges(
  Duration total,
  Duration a,
  Duration b, {
  required bool removeInside,
}) {
  final s = a < b ? a : b, e = a < b ? b : a;
  if (!removeInside) return [(s, e)];
  return [if (s > Duration.zero) (Duration.zero, s), if (e < total) (e, total)];
}

/// Nuovo istante di [t] dopo il taglio che tiene solo [keep] (null se [t]
/// cade in un tratto tolto).
Duration? mapThroughCut(Duration t, List<(Duration, Duration)> keep) {
  var offset = Duration.zero;
  for (final (a, b) in keep) {
    if (t >= a && t <= b) return offset + (t - a);
    offset += b - a;
  }
  return null;
}

/// Segnalibri, segmenti e forma d'onda riportati sulla registrazione
/// tagliata.
RecordingMeta cutMeta(RecordingMeta m, List<(Duration, Duration)> keep) {
  final segs = <TranscriptSegment>[];
  for (final s in m.segments) {
    // il segmento resta se almeno il suo inizio o la sua fine restano
    final a = mapThroughCut(s.start, keep);
    final b = mapThroughCut(s.end, keep);
    if (a == null && b == null) continue;
    final start = a ?? _firstKeptAfter(s.start, keep);
    final end = b ?? _lastKeptBefore(s.end, keep);
    if (start == null || end == null || end < start) continue;
    segs.add(TranscriptSegment(start, end, s.text));
  }
  Uint8List? peaks;
  if (m.peaks != null && m.peaks!.isNotEmpty) {
    final every = m.peakEvery.inMicroseconds;
    final out = BytesBuilder(copy: false);
    for (final (a, b) in keep) {
      final i = (a.inMicroseconds ~/ every).clamp(0, m.peaks!.length);
      final j = (b.inMicroseconds ~/ every).clamp(i, m.peaks!.length);
      out.add(Uint8List.sublistView(m.peaks!, i, j));
    }
    peaks = out.takeBytes();
  }
  return RecordingMeta(
    duration: keep.fold<Duration>(Duration.zero, (d, r) => d + (r.$2 - r.$1)),
    started: m.started,
    course: m.course,
    bookmarks: [
      for (final b in m.bookmarks)
        if (mapThroughCut(b.at, keep) case final at?) Bookmark(at, b.note),
    ],
    segments: segs,
    transcriptSource: m.transcriptSource,
    peaks: peaks,
    peakEvery: m.peakEvery,
  );
}

Duration? _firstKeptAfter(Duration t, List<(Duration, Duration)> keep) {
  var offset = Duration.zero;
  for (final (a, b) in keep) {
    if (a >= t) return offset;
    offset += b - a;
  }
  return null;
}

Duration? _lastKeptBefore(Duration t, List<(Duration, Duration)> keep) {
  var offset = Duration.zero;
  Duration? last;
  for (final (a, b) in keep) {
    offset += b - a;
    if (b <= t) last = offset;
  }
  return last;
}
