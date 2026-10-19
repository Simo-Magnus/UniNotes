import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/services/app_services.dart';
import '../../models/course.dart';
import '../../models/study.dart';
import '../study/attachments.dart';
import 'lesson_transcripts.dart';
import 'notes_store.dart';

/// Oltre questo numero di appunti di testo si allegano riuniti in un solo
/// file (molte chat accettano al massimo 10-20 allegati per messaggio).
const _maxSeparateNotes = 5;

/// Cartella dei file preparati per l'AI (riuniti in un solo Markdown).
Future<Directory> _aiTempDir() async {
  final d = Directory(p.join(Directory.systemTemp.path, 'UniNotes AI'));
  await d.create(recursive: true);
  return d;
}

/// File da allegare nella chat dell'AI di riferimento per [course]
/// (eventualmente ristretti a [module] o [topic]):
/// - appunti di testo (riassunti, appunti, trascrizioni, risposte salvate):
///   i file stessi se sono pochi, altrimenti un unico Markdown che li riunisce
///   con la struttura di Studio (moduli e argomenti);
/// - allegati di Studio del modulo/argomento (o di tutto il corso);
/// - libri obbligatori di cui c'è il file nell'app.
Future<List<File>> collectAiFiles(
  AppServices s,
  Course course, {
  StudyModule? module,
  Topic? topic,
}) async {
  final out = <File>[];
  final seen = <String>{};
  void add(File f) {
    if (seen.add(f.path)) out.add(f);
  }

  final notes = await s.notes.list(course);
  final texts = [
    for (final folder in [
      NoteFolder.summaries,
      NoteFolder.notes,
      NoteFolder.transcripts,
      NoteFolder.ai,
    ])
      for (final n in notes[folder] ?? const <NoteFile>[])
        if (!n.isAudio && (n.extension == '.md' || n.extension == '.txt')) n,
  ];
  final modules = course.id == null
      ? const <StudyModule>[]
      : await s.study.modules(course.id!);
  final topics = course.id == null
      ? const <Topic>[]
      : await s.study.topicsOfCourse(course.id!);

  if (texts.length > _maxSeparateNotes ||
      (texts.isNotEmpty && modules.isNotEmpty)) {
    final md = StringBuffer('# ${course.name} – appunti\n\n');
    if (modules.isNotEmpty) {
      md.writeln('## Struttura del corso (Studio)\n');
      for (final m in modules) {
        md.writeln('### ${m.name}');
        for (final t in topics.where((t) => t.moduleId == m.id)) {
          md.writeln('- ${t.name}');
        }
        md.writeln();
      }
    }
    for (final n in texts) {
      md.writeln(
        '\n---\n\n## ${n.folder.dirName} – ${n.name}\n\n'
        '${stripTranscriptTimes(await n.file.readAsString())}',
      );
    }
    final bundle = File(
      p.join(
        (await _aiTempDir()).path,
        'Appunti - ${NotesStore.folderName(course)}.md',
      ),
    );
    await bundle.writeAsString(md.toString());
    add(bundle);
  } else {
    for (final n in texts) {
      add(n.file);
    }
  }

  if (course.id != null) {
    final attachments = await s.study.attachmentsOfCourse(course.id!);
    for (final a in attachments) {
      final inScope = topic != null
          ? a.topicId == topic.id
          : module == null ||
                a.moduleId == module.id ||
                topics.any((t) => t.id == a.topicId && t.moduleId == module.id);
      if (!inScope) continue;
      final f = await attachmentFile(s, a);
      if (f != null) add(f);
    }
    for (final b in await s.books.all(courseId: course.id)) {
      if (b.required != true) continue;
      final f = await s.library.fileOf(b);
      if (f != null) add(f);
    }
  }
  return out;
}

/// Frase che restringe la richiesta a un modulo o argomento.
String? aiScope(List<Topic> topics, {StudyModule? module, Topic? topic}) {
  if (topic != null) {
    return 'Concentrati sull\'argomento «${topic.name}»'
        '${module == null ? '' : ' del modulo «${module.name}»'} e sui suoi '
        'allegati.';
  }
  if (module != null) {
    final names = topics
        .where((t) => t.moduleId == module.id)
        .map((t) => t.name);
    return 'Concentrati sul modulo «${module.name}»'
        '${names.isEmpty ? '' : ' (argomenti: ${names.join('; ')})'} e sui '
        'suoi allegati.';
  }
  return null;
}
