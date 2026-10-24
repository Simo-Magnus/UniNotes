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
import '../safe_files.dart';
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
/// 3. la trascrizione dal vivo (Parakeet su PC e Mac, Whisper con il
///    modello integrato sul telefono) diventa la trascrizione della registrazione
///    (`Trascrizioni/<nome>.md`, stesso formato delle altre);
/// 4. i pezzi che il motore non ha fatto in tempo a trascrivere (anche
///    tutta la registrazione, se Parakeet si stava ancora scaricando) si
///    recuperano in background (operazione «Completo la trascrizione»), poi
///    il WAV di lavoro si cancella.

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
  // scrittura sicura: con il disco pieno la trascrizione già salvata non
  // resta troncata
  await writeStringAtomic(f, md);
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
      await AudioCodec.instance.compress(session.wav, m4a) &&
      await _plausibleM4a(m4a, take.duration);
  if (compressed) {
    out = m4a;
  } else {
    out = await moveFile(session.wav, p.join(dir.path, '$base.wav'));
  }
  // l'audio è al suo posto: da qui un errore (dati, trascrizione) non deve
  // far salvare di nuovo la registrazione al prossimo avvio (doppione)
  session.savedAs = out.path;
  try {
    await session.save();
  } catch (_) {}
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

/// Il `.m4a` compresso ha una dimensione credibile per [duration] (a 48
/// kbit/s ~6 KB al secondo): uno molto più piccolo (codificatore fermato a
/// metà, disco pieno) non deve far cancellare il WAV, l'unica copia intera.
/// In quel caso si tiene il WAV.
Future<bool> _plausibleM4a(File m4a, Duration duration) async {
  try {
    final seconds = duration.inMilliseconds / 1000;
    if (seconds < 10 || await m4a.length() >= seconds * 1500) return true;
    await m4a.delete();
  } catch (_) {}
  return false;
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
Future<TrashEntry?> discardRecording(AppServices s) async {
  final rec = s.recorder;
  if (!rec.active || rec.saving) return null;
  rec.saving = true;
  try {
    final take = await rec.stop();
    if (take == null) return null;
    unawaited(take.live?.close());
    return await trashSession(
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
/// dati), poi cancella i file di lavoro. Restituisce la voce del cestino
/// (per «Annulla»), null se non c'era niente da conservare.
Future<TrashEntry?> trashSession(
  AppServices s,
  RecordingSession session, {
  List<int>? peaks,
  Duration? duration,
}) async {
  if (session.savedAs != null) {
    await session.delete();
    return null;
  }
  if (!await session.wav.exists()) {
    await session.delete();
    return null;
  }
  TrashEntry? entry;
  final tmpDir = await Directory.systemTemp.createTemp('uninotes_cestino_');
  File? moved;
  try {
    final wav = moved = await moveFile(
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
    entry = await s.trash.trash(
      [wav, RecordingMeta.sidecarOf(wav.path)],
      title: session.baseName,
      course: session.course,
      originDir: session.targetDir,
    );
  } catch (_) {
    // il cestino non è raggiungibile (disco pieno, cartella degli appunti
    // assente): l'audio torna nel WAV di lavoro, che resta da recuperare,
    // invece di sparire con la cartella temporanea
    final m = moved;
    if (m != null && await m.exists()) {
      try {
        await moveFile(m, session.wav.path);
      } catch (_) {}
    }
    rethrow;
  } finally {
    try {
      // con l'audio ancora qui (non rimesso a posto) la cartella resta
      if (!(moved != null && await moved.exists())) {
        await tmpDir.delete(recursive: true);
      }
    } catch (_) {}
  }
  await session.delete();
  s.revision.bump();
  return entry;
}

/// Recupera una registrazione rimasta dopo una chiusura improvvisa.
Future<File?> recoverSession(AppServices s, RecordingSession session) async {
  final saved = session.savedAs;
  if (saved != null) {
    // già salvata: restavano solo i file di lavoro. Se i dati accanto
    // all'audio non si erano scritti (app chiusa, disco pieno) si rifanno
    // da quelli della sessione: segnalibri e testo dal vivo non si perdono
    try {
      if (await File(saved).exists() &&
          !await RecordingMeta.sidecarOf(saved).exists() &&
          (session.bookmarks.isNotEmpty || session.segments.isNotEmpty)) {
        await RecordingMeta(
          started: session.started,
          course: session.course,
          bookmarks: [...session.bookmarks],
          segments: [...session.segments],
          transcriptSource: session.segments.isEmpty
              ? null
              : 'trascrizione dal vivo',
        ).save(saved);
      }
    } catch (e) {
      debugPrint('Dati della registrazione non ripristinati: $e');
      return null;
    }
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
