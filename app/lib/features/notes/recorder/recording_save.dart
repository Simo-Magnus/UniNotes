import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/feedback/feedback_service.dart';
import '../../../core/services/app_services.dart';
import '../../../core/services/audio_codec.dart';
import '../../../core/services/whisper_service.dart';
import '../notes_store.dart';
import '../recycle_bin.dart';
import 'live_transcriber.dart';
import 'recording_meta.dart';
import 'recording_session.dart';
import 'wav.dart';

/// Salvataggio delle registrazioni: dal WAV di lavoro al file finale.
///
/// 1. il WAV si comprime in `.m4a` AAC mono (~48 kbit/s) con gli strumenti
///    del sistema (AudioCodec); se la compressione non riesce si tiene il
///    WAV, mai perdere la registrazione;
/// 2. segnalibri, forma d'onda e segmenti della trascrizione dal vivo vanno
///    nel file `.json` accanto all'audio (RecordingMeta);
/// 3. la trascrizione dal vivo (Whisper con il modello integrato) diventa la trascrizione della registrazione
///    (`Trascrizioni/<nome>.md`, stesso formato delle altre);
/// 4. i pezzi che Whisper non ha fatto in tempo a trascrivere si recuperano
///    in background (operazione «Completo la trascrizione»), poi il WAV di
///    lavoro si cancella.

/// Nome libero nella cartella (nessun file della lezione con quel nome).
Future<String> uniqueLessonName(Directory dir, String base) async {
  var name = base;
  for (var i = 2; ; i++) {
    final clash = await Future.wait([
      for (final ext in const ['.m4a', '.wav', '.flac', '.json'])
        File(p.join(dir.path, '$name$ext')).exists(),
    ]);
    if (!clash.contains(true)) return name;
    name = '$base ($i)';
  }
}

/// Trascrizione Markdown dei [segments] accanto alla registrazione
/// ([audio] in `<corso>/Registrazioni`): `<corso>/Trascrizioni/<nome>.md`.
Future<File> writeTranscriptFor(
  String audio,
  List<TranscriptSegment> segments, {
  required String course,
  required String source,
}) async {
  final name = p.basenameWithoutExtension(audio);
  final dir = Directory(
    p.join(p.dirname(p.dirname(audio)), NoteFolder.transcripts.dirName),
  );
  await dir.create(recursive: true);
  final md = segmentsToMarkdown(
    [for (final s in segments) WhisperSegment(s.start, s.text, end: s.end)],
    title: 'Trascrizione – $name',
    subtitle: [if (course.isNotEmpty) course, source].join(' · '),
  );
  final f = File(p.join(dir.path, '$name.md'));
  await f.writeAsString(md);
  return f;
}

/// «Salva»: ferma la registrazione in corso e la salva. Restituisce il file
/// salvato (null se non c'era nulla da salvare).
Future<File?> saveRecording(AppServices s) async {
  final rec = s.recorder;
  if (!rec.active || rec.saving) return null;
  rec.saving = true;
  try {
    final take = await rec.stop();
    if (take == null) return null;
    // fine registrazione: segnale breve (dopo lo stop, non finisce nell'audio)
    unawaited(s.feedback.play(FeedbackEvent.recordStop));
    return await finishTake(s, take);
  } finally {
    rec.saving = false;
  }
}

/// Salva una registrazione fermata (o recuperata dopo una chiusura).
Future<File> finishTake(AppServices s, RecordingTake take) async {
  final session = take.session;
  final dir = Directory(session.targetDir);
  await dir.create(recursive: true);
  final base = await uniqueLessonName(dir, session.baseName);
  final m4a = File(p.join(dir.path, '$base.m4a'));
  File out;
  final compressed =
      await take.session.wav.exists() &&
      await AudioCodec.instance.compress(session.wav, m4a);
  if (compressed) {
    out = m4a;
  } else {
    out = await moveFile(session.wav, p.join(dir.path, '$base.wav'));
  }
  final live = take.live;
  final segments = [...?live?.segments];
  if (segments.isEmpty) segments.addAll(session.segments);
  final liveSource = live?.sourceLabel ?? 'trascrizione dal vivo';
  final meta = RecordingMeta(
    duration: take.duration,
    started: session.started,
    course: session.course,
    bookmarks: [...session.bookmarks],
    segments: segments,
    transcriptSource: segments.isEmpty ? null : liveSource,
    peaks: take.peaks.isEmpty ? null : take.peaks,
  );
  await meta.save(out.path);
  if (segments.isNotEmpty) {
    await writeTranscriptFor(
      out.path,
      segments,
      course: session.course,
      source: liveSource,
    );
  }
  session.savedAs = out.path;
  try {
    await session.save();
  } catch (_) {}
  s.revision.bump();

  final pending = take.pending;
  // pezzi da recuperare o un pezzo ancora in lavorazione: il testo si
  // completa in background, la registrazione è già salvata
  if (live != null &&
      (pending.isNotEmpty || live.busy) &&
      live.state != LiveState.failed) {
    // la sorgente dei pezzi da recuperare: il WAV di lavoro o, se la
    // compressione non è riuscita, il WAV salvato
    final source = compressed ? session.wav : out;
    s.jobs.start(
      'Completo la trascrizione · $base',
      courseId: session.courseId,
      target: out.path,
      (report) async {
        try {
          await live.recover(
            pending,
            source,
            progress: (done, total) => report(
              'Trascrivo i pezzi rimasti: $done di $total',
              total == 0 ? null : done / total,
            ),
          );
          final segs = live.segments;
          if (segs.isNotEmpty) {
            final m = await RecordingMeta.load(out.path);
            m
              ..segments = [...segs]
              ..transcriptSource = liveSource;
            await m.save(out.path);
            await writeTranscriptFor(
              out.path,
              segs,
              course: session.course,
              source: liveSource,
            );
          }
          return out.path;
        } finally {
          await live.close();
          await _cleanup(session, compressed);
          s.revision.bump();
        }
      },
    );
  } else {
    unawaited(live?.close());
    await _cleanup(session, compressed);
  }
  return out;
}

/// File di lavoro da togliere dopo il salvataggio: tutto se la
/// registrazione è stata compressa, altrimenti solo i dati (il WAV è
/// diventato la registrazione).
Future<void> _cleanup(RecordingSession session, bool compressed) async {
  if (compressed) {
    await session.delete();
    return;
  }
  try {
    if (await session.file.exists()) await session.file.delete();
  } catch (_) {}
}

/// «Elimina» la registrazione in corso: si ferma e va in «Eliminati di
/// recente» (30 giorni per ripensarci).
Future<void> discardRecording(AppServices s) async {
  final rec = s.recorder;
  if (!rec.active || rec.saving) return;
  rec.saving = true;
  try {
    final take = await rec.stop();
    if (take == null) return;
    unawaited(take.live?.close());
    await trashSession(
      s,
      take.session,
      peaks: take.peaks,
      duration: take.duration,
    );
  } finally {
    rec.saving = false;
  }
}

/// Sposta l'audio di lavoro nel cestino come registrazione WAV (con i suoi
/// dati), poi cancella i file di lavoro.
Future<void> trashSession(
  AppServices s,
  RecordingSession session, {
  List<int>? peaks,
  Duration? duration,
}) async {
  if (session.savedAs != null) {
    await session.delete();
    return;
  }
  if (!await session.wav.exists()) {
    await session.delete();
    return;
  }
  final tmpDir = await Directory.systemTemp.createTemp('uninotes_cestino_');
  try {
    final wav = await moveFile(
      session.wav,
      p.join(tmpDir.path, '${session.baseName}.wav'),
    );
    final meta = RecordingMeta(
      duration: duration,
      started: session.started,
      course: session.course,
      bookmarks: [...session.bookmarks],
      segments: [...session.segments],
      peaks: peaks == null || peaks.isEmpty ? null : Uint8List.fromList(peaks),
    );
    await meta.save(wav.path);
    // il ripristino la rimette nella cartella Registrazioni del corso
    await s.trash.trash(
      [wav, RecordingMeta.sidecarOf(wav.path)],
      title: session.baseName,
      course: session.course,
      originDir: session.targetDir,
    );
  } finally {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  }
  await session.delete();
  s.revision.bump();
}

/// Recupera una registrazione rimasta dopo una chiusura improvvisa.
Future<File?> recoverSession(AppServices s, RecordingSession session) async {
  if (session.savedAs != null) {
    // già salvata: restavano solo i file di lavoro
    await session.delete();
    return null;
  }
  final info = await repairWav(session.wav);
  if (info == null || info.dataLength == 0) {
    await session.delete();
    return null;
  }
  Uint8List peaks;
  try {
    peaks = await computePeaks(session.wav);
  } catch (e) {
    debugPrint('Forma d\'onda non calcolata: $e');
    peaks = Uint8List(0);
  }
  final take = RecordingTake(
    session: session,
    duration: info.duration,
    peaks: peaks,
  );
  return finishTake(s, take);
}
