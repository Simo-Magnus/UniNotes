import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/services/external_launcher.dart';
import '../../core/services/whisper_service.dart';
import '../links/ai_assistants.dart';
import '../../models/course.dart';
import '../../widgets/common.dart';
import '../../widgets/share_files.dart';
import '../study/study_widgets.dart';
import 'ai_files.dart';
import 'ai_prompts.dart';
import '../../core/services/power.dart';
import 'ai_request_dialog.dart';
import 'background_jobs.dart';
import 'lesson_transcripts.dart';
import 'markdown_view.dart';
import 'notes_store.dart';
import 'recorder/better_transcription.dart' show recordWhisperSpeed;
import 'recorder/course_vocabulary.dart';
import 'recorder/recording_meta.dart';
import 'recorder/recording_overlay.dart' show confirmDeleteRecording;
import '../links/link_settings.dart';

/// Sul PC Whisper usa `whisper-cli`; sul telefono il motore incluso.
bool get isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

String _date(NoteFile f) => f.name;

/// Trascrizione locale con Whisper (PC, Mac e telefono), in background e
/// annullabile. Se non riesce, l'errore non diventa una card a parte: la
/// card della registrazione mostra «Impossibile trascrivere con Whisper: …»
/// con cosa provare (vedi [whisperFailureMessage]).
///
/// Modello: [model] se scelto per questa trascrizione («Trascrivi con…»),
/// altrimenti quello predefinito o il più accurato fra quelli scaricati che
/// il dispositivo regge; senza modelli scaricati il modello integrato (vedi
/// [WhisperService.pickModel]). Il modello usato si scrive nella
/// trascrizione e nei dati della registrazione. Con [again] la trascrizione
/// di prima va in «Eliminati di recente».
///
/// Se sulla registrazione c'è già un'operazione in corso (es. «Completo la
/// trascrizione» subito dopo il salvataggio) Whisper parte quando finisce,
/// così non scrivono la trascrizione in due. La velocità della
/// trascrizione si ricorda per stimare il tempo delle prossime
/// (recorder/better_transcription.dart). [startedMessage] sostituisce
/// l'avviso «Trascrizione avviata…».
void transcribeWithWhisper(
  BuildContext context,
  Course course,
  NoteFile rec, {
  String? model,
  bool again = false,
  String? startedMessage,
}) {
  final s = context.read<AppServices>();
  final cancel = CancelToken();
  // un errore precedente sulla stessa registrazione si toglie
  for (final j in s.jobs.failedOn(rec.file.path, kind: JobKind.whisper)) {
    s.jobs.dismiss(j);
  }
  final before = s.jobs.runningOn(rec.file.path);
  s.jobs.start(
    '${model == kParakeetId ? 'Trascrizione Parakeet' : 'Trascrizione Whisper'}'
    ' · ${rec.name}',
    courseId: course.id,
    target: rec.file.path,
    kind: JobKind.whisper,
    onCancel: cancel.cancel,
    (report) async {
      if (before != null) {
        report('In attesa: ${before.title}', null);
        await before.done;
        if (cancel.isCancelled) {
          throw WhisperException('Trascrizione annullata.');
        }
      }
      final chosen = await s.whisper.resolveModel(requested: model);
      if (chosen == null) {
        final st = await s.whisper.status();
        throw WhisperException(
          s.whisper.isPhone
              ? (st.engineReady
                    ? 'Nessun modello Whisper scaricato.'
                    : 'Whisper non è installato.')
              : 'Nessun motore di trascrizione: scarica Parakeet o un '
                    'modello Whisper da Collegamenti → Whisper.',
        );
      }
      // vocabolario del corso per Whisper (nome, moduli, argomenti)
      final prompt = chosen.isParakeet
          ? null
          : buildWhisperPrompt(
              await loadCourseVocabulary(s.study, course.id, course.name),
            );
      if (await Power.whisperOnlyCharging(s.settings) &&
          !await Power.charging()) {
        report('In attesa del caricabatterie…', null);
        await Power.waitForCharging(cancelled: () => cancel.isCancelled);
        if (cancel.isCancelled) {
          throw WhisperException('Trascrizione annullata.');
        }
      }
      final took = Stopwatch()..start();
      final result = await s.whisper.transcribeWith(
        rec.file,
        model: chosen.id,
        cancel: cancel,
        prompt: prompt,
        onProgress: (pr) => report(
          '${pr.phase} · ${whisperModelLabel(chosen.id)}',
          pr.fraction,
        ),
      );
      took.stop();
      final segs = result.segments;
      final used = result.model.id;
      try {
        final audio = (await RecordingMeta.load(rec.file.path)).duration;
        if (audio != null) {
          await recordWhisperSpeed(
            s.settings,
            used,
            took: took.elapsed,
            audio: audio,
          );
        }
      } catch (_) {}
      if (segs.isEmpty) {
        throw WhisperException('Nessun parlato riconosciuto nell\'audio.');
      }
      final md = segmentsToMarkdown(
        segs,
        title: 'Trascrizione – ${_date(rec)}',
        subtitle:
            '${course.name} · trascritta con ${transcriptionEngineLabel(used)}',
      );
      if (again) {
        // la trascrizione di prima resta recuperabile per 30 giorni
        final dir = await s.notes.courseDir(course, NoteFolder.transcripts);
        final old = File(p.join(dir.path, '${rec.name}.md'));
        if (await old.exists()) {
          await s.trash.trash(
            [old],
            title: 'Trascrizione – ${rec.name}',
            course: course.name,
          );
        }
      }
      final f = await s.notes.writeText(
        course,
        NoteFolder.transcripts,
        rec.name,
        md,
      );
      // segmenti con i tempi accanto alla registrazione (testo sincronizzato
      // con l'audio nel lettore delle registrazioni)
      try {
        final meta = await RecordingMeta.load(rec.file.path);
        meta
          ..segments = [
            for (var i = 0; i < segs.length; i++)
              TranscriptSegment(
                segs[i].start,
                segs[i].end ??
                    (i + 1 < segs.length
                        ? segs[i + 1].start
                        : segs[i].start + const Duration(seconds: 5)),
                segs[i].text,
              ),
          ]
          ..transcriptSource = transcriptionEngineLabel(used);
        await meta.save(rec.file.path);
      } catch (_) {
        // la trascrizione Markdown basta
      }
      s.revision.bump();
      return f.path;
    },
    onFinished: (j) {
      // annullata: niente messaggio d'errore sulla card
      if (j.state == JobState.failed && j.cancelled) s.jobs.dismiss(j);
    },
  );
  showSnack(
    context,
    startedMessage ?? 'Trascrizione avviata: puoi continuare a usare l\'app.',
  );
}

/// «Trascrivi con…» / «Trascrivi di nuovo con…»: sceglie il modello per
/// questa trascrizione fra quelli scaricati e il modello integrato, poi la
/// avvia. [current] è il modello della trascrizione che c'è già (segnato
/// nell'elenco).
Future<void> chooseWhisperModelAndTranscribe(
  BuildContext context,
  Course course,
  NoteFile rec, {
  bool again = false,
  String? current,
}) async {
  final s = context.read<AppServices>();
  final models = await s.whisper.availableModels();
  final auto = await s.whisper.resolveModel();
  final device = await s.whisper.deviceProfile();
  if (!context.mounted) return;
  if (models.isEmpty) {
    showSnack(
      context,
      s.whisper.isPhone
          ? 'Nessun modello Whisper: scaricane uno da Collegamenti → Whisper.'
          : 'Nessun motore: scarica Parakeet o un modello Whisper da '
                'Collegamenti → Whisper.',
    );
    return;
  }
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                again ? 'Trascrivi di nuovo con…' : 'Trascrivi con…',
                style: Theme.of(c).textTheme.titleMedium,
              ),
            ),
            for (final m in models)
              ListTile(
                leading: Icon(
                  m.id == auto?.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(whisperModelLabel(m.id)),
                subtitle: Text(
                  [
                    if (m.id == kBuiltInWhisperModel.id)
                      'base q5_1, ${m.disk}'
                    else if (m.isParakeet)
                      'NVIDIA, veloce, ${m.disk}'
                    else
                      '${m.disk} · RAM ${m.ram}',
                    if (m.id == auto?.id) 'usato di solito',
                    if (m.id == current) 'trascrizione attuale',
                    if (!deviceCanRun(m, device))
                      'pesante per questo dispositivo',
                  ].join(' · '),
                ),
                onTap: () => Navigator.pop(c, m.id),
              ),
          ],
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  transcribeWithWhisper(context, course, rec, model: picked, again: again);
}

/// I tre passi mostrati nel riquadro dell'AI (Registra → insegnamento).
const kAiSteps = [
  '1) Avvia una chat con il tuo modello AI di riferimento.',
  '2) Allega i file da far analizzare e incolla il prompt consigliato.',
  '3) Leggi la risposta nella chat della tua AI.',
];

/// Passi quando la risposta torna nell'app da sola (trascrizione, riassunto).
List<String> _captureSteps(String ai, String what) => [
  '1) Apri $ai con il tuo account universitario.',
  '2) Allega il file e incolla il prompt (è già copiato).',
  '3) Copia $what e torna in UniNotes: si salva da sola.',
];

/// «Trascrivi con Gemini», con l'account (universitario) dell'utente e senza
/// chiave API: si apre Gemini con il file della registrazione da allegare e
/// il prompt da inviare; la trascrizione copiata in Gemini si salva da sola
/// al ritorno nell'app (`Trascrizioni/<lezione> (Gemini).md`).
Future<void> transcribeWithGemini(
  BuildContext context,
  Course course,
  NoteFile rec,
) async {
  final s = context.read<AppServices>();
  final name = transcriptName(rec.name, TranscriptKind.gemini);
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  await showAiRequestDialog(
    context,
    title: 'Trascrivi con Gemini',
    ai: ReferenceAi.gemini,
    steps: _captureSteps('Gemini', 'la trascrizione'),
    prompt: manualTranscriptionPrompt(course.name),
    files: [rec.file],
    onCapture: (text) => _saveCaptured(
      s,
      messenger,
      course,
      NoteFolder.transcripts,
      name,
      text,
      'Trascrizione di Gemini salvata.',
    ),
  );
}

/// «Riassumi con Gemini»: riassunto formattato della trascrizione; il
/// riassunto copiato in Gemini si salva da solo nei Riassunti.
Future<void> summarizeWithGemini(
  BuildContext context,
  Course course,
  NoteFile transcript,
) async {
  final s = context.read<AppServices>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  await showAiRequestDialog(
    context,
    title: 'Riassumi con Gemini',
    ai: ReferenceAi.gemini,
    steps: _captureSteps('Gemini', 'il riassunto'),
    prompt: summaryOfTranscriptPrompt(
      course.name,
      p.basename(transcript.file.path),
    ),
    files: [transcript.file],
    onCapture: (text) => _saveCaptured(
      s,
      messenger,
      course,
      NoteFolder.summaries,
      lessonOfTranscript(transcript.name),
      text,
      'Riassunto salvato.',
    ),
  );
}

/// Salva il testo copiato dall'app AI in [folder]/[name].md; l'avviso
/// permette di annullare (torna il file di prima, se c'era).
Future<void> _saveCaptured(
  AppServices s,
  ScaffoldMessengerState? messenger,
  Course course,
  NoteFolder folder,
  String name,
  String text,
  String done,
) async {
  final dir = await s.notes.courseDir(course, folder);
  final target = File(p.join(dir.path, '${NotesStore.safeName(name)}.md'));
  final before = await target.exists() ? await target.readAsString() : null;
  await s.notes.writeText(course, folder, name, text);
  s.revision.bump();
  if (messenger == null || !messenger.mounted) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(done),
        action: SnackBarAction(
          label: 'Annulla',
          onPressed: () async {
            if (before == null) {
              if (await target.exists()) await target.delete();
            } else {
              await target.writeAsString(before);
            }
            s.revision.bump();
          },
        ),
      ),
    );
}

/// «Allega» nei Riassunti: copia i file scelti (Markdown, PDF, Word…) nella
/// cartella Riassunti del corso.
Future<void> attachSummaries(BuildContext context, Course course) async {
  final s = context.read<AppServices>();
  final List<PlatformFile> picked;
  try {
    picked = await FilePicker.pickFiles(
      dialogTitle: 'Scegli i riassunti da allegare',
    );
  } catch (e) {
    if (context.mounted) showSnack(context, 'Selezione non riuscita: $e');
    return;
  }
  if (picked.isEmpty) return;
  final dir = await s.notes.courseDir(course, NoteFolder.summaries);
  var n = 0;
  for (final f in picked) {
    final src = f.path;
    if (src == null) continue;
    var dest = p.join(dir.path, p.basename(src));
    for (var i = 2; await File(dest).exists(); i++) {
      dest = p.join(
        dir.path,
        '${p.basenameWithoutExtension(src)} ($i)${p.extension(src)}',
      );
    }
    await File(src).copy(dest);
    n++;
  }
  s.revision.bump();
  if (context.mounted && n > 0) {
    showSnack(
      context,
      n == 1 ? 'Riassunto allegato.' : '$n riassunti allegati.',
    );
  }
}

/// «Studia con la tua AI di riferimento» (Registra → insegnamento): prompt
/// per [task] e file del corso da allegare.
Future<void> askReferenceAi(
  BuildContext context,
  Course course,
  AiTask task,
) async {
  final s = context.read<AppServices>();
  final ai = await s.settings.referenceAi();
  final files = await collectAiFiles(s, course);
  if (!context.mounted) return;
  await showAiRequestDialog(
    context,
    title: 'Apri con la tua app di riferimento',
    ai: ai,
    steps: kAiSteps,
    prompt: task.prompt(
      course,
      ai,
      files: [for (final f in files) p.basename(f.path)],
      today: DateTime.now(),
    ),
    files: files,
  );
}

/// «Apri in (AI)» per una sola trascrizione, riassunto o appunto.
Future<void> openNoteInAi(
  BuildContext context,
  Course course,
  NoteFile note,
) async {
  final s = context.read<AppServices>();
  final ai = await s.settings.referenceAi();
  if (!context.mounted) return;
  final t = await showModalBottomSheet<AiTask>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(note.name, style: Theme.of(c).textTheme.titleMedium),
            ),
            for (final t in AiTask.values)
              ListTile(
                title: Text(t.label),
                subtitle: Text(t.description),
                onTap: () => Navigator.pop(c, t),
              ),
          ],
        ),
      ),
    ),
  );
  if (t == null || !context.mounted) return;
  await showAiRequestDialog(
    context,
    title: 'Apri con la tua app di riferimento',
    ai: ai,
    steps: kAiSteps,
    prompt: t.prompt(
      course,
      ai,
      files: [p.basename(note.file.path)],
      today: DateTime.now(),
    ),
    files: [note.file],
  );
}

// PDF del Markdown: sul PC accanto al file e aperto; sul telefono
/// "Salva con nome".
Future<void> exportPdf(
  BuildContext context,
  NoteFile note, {
  required String subtitle,
}) async {
  try {
    // trascrizioni del vecchio formato: senza gli orari delle frasi
    final bytes = await markdownToPdf(
      stripTranscriptTimes(await note.file.readAsString()),
      title: note.name,
      subtitle: subtitle,
    );
    if (isDesktop) {
      final out = File(p.setExtension(note.file.path, '.pdf'));
      await out.writeAsBytes(bytes);
      final r = await ExternalLauncher.openPath(out.path);
      if (context.mounted) showLaunchResult(context, r);
      return;
    }
    final dest = await FilePicker.saveFile(
      dialogTitle: 'Salva PDF',
      fileName: '${note.name}.pdf',
      bytes: Uint8List.fromList(bytes),
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (dest != null && context.mounted) showSnack(context, 'PDF salvato.');
  } catch (e) {
    if (context.mounted) {
      showSnack(context, 'Esportazione PDF non riuscita: $e');
    }
  }
}

/// Copia del file sul telefono (cartella scelta) o condivisione.
Future<void> saveCopy(BuildContext context, NoteFile note) async {
  try {
    final dest = await FilePicker.saveFile(
      dialogTitle: 'Salva una copia',
      fileName: p.basename(note.file.path),
      bytes: await note.file.readAsBytes(),
    );
    if (dest != null && context.mounted) showSnack(context, 'Copia salvata.');
  } catch (e) {
    if (context.mounted) showSnack(context, 'Salvataggio non riuscito: $e');
  }
}

Future<void> shareNote(BuildContext context, NoteFile note) =>
    shareFiles(context, [note.file], subject: note.name);

/// Rinomina un file degli appunti. Una lezione si rinomina insieme a
/// trascrizione, riassunto e PDF con lo stesso nome; gli allegati di Studio
/// che li collegano vengono aggiornati.
Future<String?> renameNote(
  BuildContext context,
  Course course,
  NoteFile f,
) async {
  final s = context.read<AppServices>();
  if (s.jobs.runningOn(f.file.path) != null) {
    showSnack(context, 'Attendi la fine della trascrizione o del riassunto.');
    return null;
  }
  if (s.recorder.active && s.recorder.path == f.file.path) {
    showSnack(context, 'La registrazione è ancora in corso.');
    return null;
  }
  final lesson = NotesStore.lessonFolders.contains(f.folder);
  final name = await promptText(
    context,
    title: lesson ? 'Rinomina la lezione' : 'Rinomina',
    label: lesson
        ? 'Nuovo nome (anche per trascrizione e riassunto)'
        : 'Nuovo nome',
    initial: f.name,
  );
  if (name == null || !context.mounted) return null;
  try {
    final moves = await s.notes.rename(course, f, name);
    if (moves.isEmpty) return null;
    await s.study.renameAttachmentPaths(
      moves,
      oldName: f.name,
      newName: NotesStore.safeName(name),
    );
    s.revision.bump();
    if (context.mounted) {
      showSnack(
        context,
        moves.length == 1 ? 'Rinominato.' : 'Rinominati ${moves.length} file.',
      );
    }
    return NotesStore.safeName(name);
  } on FileSystemException catch (e) {
    if (context.mounted) showSnack(context, '${e.message}.');
    return null;
  }
}

/// «Elimina»: il file (per una registrazione anche i suoi dati) va in
/// «Eliminati di recente» per 30 giorni; l'avviso permette di annullare.
Future<bool> trashNote(BuildContext context, Course course, NoteFile f) async {
  final s = context.read<AppServices>();
  if (s.jobs.runningOn(f.file.path) != null) {
    showSnack(context, 'Attendi la fine della trascrizione o del riassunto.');
    return false;
  }
  final ok = f.isAudio
      ? await confirmDeleteRecording(context, name: f.name)
      : await confirmDialog(
          context,
          'Eliminare "${f.name}"?',
          'Il file va in «Eliminati di recente» per 30 giorni.',
        );
  if (!ok || !context.mounted) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final entry = await s.trash.trash(
    [f.file, if (f.isAudio) RecordingMeta.sidecarOf(f.file.path)],
    title: f.name,
    course: course.name,
  );
  s.revision.bump();
  if (entry != null) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Spostato in «Eliminati di recente».'),
          action: SnackBarAction(
            label: 'Annulla',
            onPressed: () async {
              await s.trash.restore(entry);
              s.revision.bump();
            },
          ),
        ),
      );
  }
  return entry != null;
}
