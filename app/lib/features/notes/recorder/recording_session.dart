import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../safe_files.dart';
import 'live_transcriber.dart';
import 'live_transcript.dart';
import 'recording_meta.dart';

/// Registrazione in corso (o non ancora salvata) sul disco: il WAV di
/// lavoro `<cartella di lavoro>/<id>.wav` e i suoi dati `<id>.json` (corso,
/// dove salvarla, segnalibri, trascrizione dal vivo). Se l'app si chiude di
/// colpo (crash, batteria, sistema) al riavvio i due file restano e l'app
/// propone di recuperare la registrazione: l'audio non si perde.
class RecordingSession {
  RecordingSession({
    required this.wav,
    required this.targetDir,
    required this.baseName,
    required this.course,
    required this.started,
    this.courseId,
    this.sampleRate = 16000,
    this.channels = 1,
    List<Bookmark>? bookmarks,
    List<TranscriptSegment>? segments,
    this.savedAs,
  }) : bookmarks = bookmarks ?? [],
       segments = segments ?? [];

  final File wav;

  /// Cartella «Registrazioni» del corso e nome della lezione (senza
  /// estensione).
  final String targetDir;
  final String baseName;
  final String course;
  final int? courseId;
  final DateTime started;
  int sampleRate;
  int channels;
  final List<Bookmark> bookmarks;
  List<TranscriptSegment> segments;

  /// Registrazione già salvata (resta solo da completare la trascrizione).
  String? savedAs;

  File get file => File(p.setExtension(wav.path, '.json'));

  Map<String, Object?> toJson() => {
    'cartella': targetDir,
    'nome': baseName,
    'corso': course,
    'corsoId': ?courseId,
    'inizio': started.toIso8601String(),
    'frequenza': sampleRate,
    'canali': channels,
    'segnalibri': [for (final b in bookmarks) b.toJson()],
    'segmenti': [for (final s in segments) s.toJson()],
    'salvataCome': ?savedAs,
  };

  static RecordingSession? fromJson(File wav, Object? j) {
    if (j is! Map) return null;
    final dir = j['cartella'], name = j['nome'];
    if (dir is! String || name is! String) return null;
    return RecordingSession(
      wav: wav,
      targetDir: dir,
      baseName: name,
      course: '${j['corso'] ?? ''}',
      courseId: j['corsoId'] is int ? j['corsoId'] as int : null,
      started: DateTime.tryParse('${j['inizio'] ?? ''}') ?? DateTime.now(),
      sampleRate: j['frequenza'] is int ? j['frequenza'] as int : 16000,
      channels: j['canali'] is int ? j['canali'] as int : 1,
      bookmarks: [
        for (final b in jsonList(j['segnalibri'])) ?Bookmark.fromJson(b),
      ],
      segments: [
        for (final s in jsonList(j['segmenti'])) ?TranscriptSegment.fromJson(s),
      ],
      savedAs: j['salvataCome'] is String ? j['salvataCome'] as String : null,
    );
  }

  /// Scrittura sicura, una alla volta (timer, pausa, segnalibri e stop
  /// possono salvare insieme).
  Future<void> save() => writeStringAtomic(file, jsonEncode(toJson()));

  /// Cancella WAV e dati di lavoro.
  Future<void> delete() async {
    for (final f in [wav, file, File('${file.path}.part')]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// Registrazioni rimaste nella cartella di lavoro (escluse [except]).
  static Future<List<RecordingSession>> orphans(
    Directory dir, {
    String? except,
  }) async {
    if (!await dir.exists()) return const [];
    final out = <RecordingSession>[];
    final entries = [
      await for (final e in dir.list())
        if (e is File) e,
    ];
    final names = {for (final e in entries) p.basename(e.path)};
    for (final e in entries) {
      final name = p.basename(e.path);
      File data;
      if (name.endsWith('.json')) {
        data = e;
      } else if (name.endsWith('.json.part') &&
          !names.contains(name.substring(0, name.length - 5))) {
        // l'app si è chiusa mentre salvava i dati: c'è solo la copia nuova
        data = e;
      } else {
        continue;
      }
      final base = name.substring(0, name.indexOf('.json'));
      final wav = File(p.join(dir.path, '$base.wav'));
      if (except != null && p.equals(wav.path, except)) continue;
      try {
        final s = fromJson(wav, jsonDecode(await data.readAsString()));
        if (s != null) out.add(s);
      } catch (_) {
        // dati illeggibili: il WAV resta dov'è
      }
    }
    out.sort((a, b) => a.started.compareTo(b.started));
    return out;
  }
}

/// Registrazione appena fermata, da salvare (compressione, dati,
/// trascrizione).
class RecordingTake {
  RecordingTake({
    required this.session,
    required this.duration,
    required this.peaks,
    this.live,
    this.pending = const [],
  });

  final RecordingSession session;
  final Duration duration;
  final Uint8List peaks;

  /// Trascrizione dal vivo (null se non c'era) e pezzi ancora da fare.
  final LiveTranscriber? live;
  final List<LiveChunk> pending;
}
