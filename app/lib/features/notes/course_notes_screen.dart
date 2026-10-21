import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/services/whisper_service.dart' show WhisperModelInfo;
import '../../models/course.dart';
import '../../widgets/common.dart';
import '../../widgets/find_bar.dart';
import '../../widgets/glass.dart';
import '../reader/reader_screen.dart';
import '../study/attachments.dart';
import 'background_jobs.dart';
import '../links/link_settings.dart';
import 'ai_prompts.dart';
import 'lesson_transcripts.dart';
import 'note_viewer_screen.dart';
import 'notes_actions.dart';
import 'notes_screen.dart';
import 'notes_store.dart';
import 'recording_player_screen.dart';
import '../../core/constants/text_limits.dart';

/// Appunti di un corso: registrazioni (con le loro trascrizioni) →
/// «Riassunti lezioni e Appunti», «Note» e «Studia con la tua AI di
/// riferimento».
/// Ctrl+F (o la lente) cerca nei nomi e nel testo dei file, trascrizioni
/// comprese.
///
/// Card «Registrazioni delle lezioni»: un tocco sulla card apre la
/// registrazione (ascolto e trascrizione), un tocco sul nome la rinomina,
/// il cestino la elimina; sotto, sulla stessa riga, «Trascrivi con Whisper»
/// e «Trascrivi con Gemini», che diventano «Vedi trascrizione» (azzurro per
/// Whisper, viola per Gemini) quando la trascrizione c'è. Sotto «Trascrivi
/// con Whisper» c'è il modello che si userà («Vedi trascrizione» non ha più
/// la riga del modello); tenendo premuto (o dal menu ⋮) si sceglie un altro
/// modello o si trascrive di nuovo.
class CourseNotesScreen extends StatefulWidget {
  const CourseNotesScreen({super.key, required this.course, this.justSaved});
  final Course course;

  /// Registrazione appena salvata (evidenziata, con l'avviso).
  final String? justSaved;

  @override
  State<CourseNotesScreen> createState() => _CourseNotesScreenState();
}

class _CourseNotesScreenState extends State<CourseNotesScreen> {
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  bool _searchOpen = false;

  /// Registrazione appena salvata (evidenziata).
  late String? _justSaved = widget.justSaved;

  /// Testo dei file Markdown per la ricerca (per percorso e data).
  final _texts = <String, (DateTime, String)>{};

  Course get course => widget.course;

  @override
  void initState() {
    super.initState();
    if (widget.justSaved != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showSnack(context, 'Registrazione salvata.');
      });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queryFocus.requestFocus();
      _query.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _query.text.length,
      );
    });
  }

  void _closeSearch() => setState(() {
    _searchOpen = false;
    _query.clear();
  });

  Future<_NotesView> _load(AppServices s) async {
    final files = await s.notes.list(course);
    final transcripts = <String, LessonTranscripts>{};
    final recs = files[NoteFolder.recordings]!.where((f) => f.isAudio);
    if (recs.isNotEmpty) {
      final dir = await s.notes.courseDir(course, NoteFolder.transcripts);
      for (final r in recs) {
        transcripts[r.name] = await loadLessonTranscripts(
          dir,
          r.name,
          audioPath: r.file.path,
        );
      }
    }
    // trascrizioni del vecchio formato senza registrazione: via gli orari
    for (final t in files[NoteFolder.transcripts]!) {
      if (t.extension == '.md') await removeTranscriptTimes(t.file);
    }
    WhisperModelInfo? whisperModel;
    if (recs.isNotEmpty) {
      try {
        whisperModel = await s.whisper.resolveModel();
      } catch (_) {
        whisperModel = null;
      }
    }
    final q = _searchOpen ? _query.text.trim().toLowerCase() : '';
    if (q.isEmpty) return _NotesView(files, transcripts, null, whisperModel);
    final hits = <String, String?>{};
    for (final list in files.values) {
      for (final f in list) {
        String? snippet;
        if (!f.isAudio && f.extension == '.md') {
          final cached = _texts[f.file.path];
          String text;
          if (cached != null && cached.$1 == f.modified) {
            text = cached.$2;
          } else {
            text = await f.file.readAsString();
            _texts[f.file.path] = (f.modified, text);
          }
          final i = text.toLowerCase().indexOf(q);
          if (i >= 0) snippet = _snippet(text, i, q.length);
        }
        if (snippet != null || f.name.toLowerCase().contains(q)) {
          hits[f.file.path] = snippet;
        }
      }
    }
    return _NotesView(files, transcripts, hits, whisperModel);
  }

  static String _snippet(String text, int i, int len) {
    final a = (i - 40).clamp(0, text.length);
    final b = (i + len + 60).clamp(0, text.length);
    return '${a > 0 ? '…' : ''}'
        '${text.substring(a, b).replaceAll(RegExp(r'\s+'), ' ').trim()}'
        '${b < text.length ? '…' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(
        title: Text(course.name),
        actions: [
          IconButton(
            tooltip: 'Cerca negli appunti (Ctrl+F)',
            icon: const Icon(Icons.search),
            onPressed: _openSearch,
          ),
        ],
      ),
      floatingActionButton: GlowFab(
        heroTag: 'record-course',
        onPressed: () async {
          final saved = await openRecorder(
            context,
            course: course,
            fromCourse: true,
          );
          if (saved == null || !mounted) return;
          setState(() => _justSaved = saved);
          showSnack(this.context, 'Registrazione salvata.');
        },
        icon: const Icon(Icons.mic),
        label: const Text('Registra'),
      ),
      body: FindShortcuts(
        onFind: _openSearch,
        onClose: _closeSearch,
        child: Column(
          children: [
            if (_searchOpen)
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                  child: Row(
                    children: [
                      const Icon(Icons.search, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _query,
                          focusNode: _queryFocus,
                          autofocus: true,
                          inputFormatters: TextLimits.max(TextLimits.search),
                          decoration: const InputDecoration(
                            hintText: 'Cerca nei nomi e nel testo dei file',
                            isDense: true,
                            border: InputBorder.none,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Chiudi (Esc)',
                        icon: const Icon(Icons.close),
                        onPressed: _closeSearch,
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: RevisionBuilder<_NotesView>(
                load: _load,
                deps: [course.id, _searchOpen, _query.text],
                builder: (context, v) => ListenableBuilder(
                  listenable: s.jobs,
                  builder: (context, _) => _list(context, s, v),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context, AppServices s, _NotesView v) {
    final files = v.files;
    final hits = v.hits;
    final query = hits == null ? null : _query.text.trim();
    List<NoteFile> shown(NoteFolder f) => hits == null
        ? files[f]!
        : files[f]!.where((x) => hits.containsKey(x.file.path)).toList();
    Widget section(NoteFolder f, String empty, {Widget? action}) =>
        hits != null && shown(f).isEmpty
        ? const SizedBox.shrink()
        : _Section(
            course: course,
            folder: f,
            files: shown(f),
            all: files,
            transcripts: v.transcripts,
            empty: hits == null ? empty : 'Nessun risultato.',
            action: action,
            query: query,
            snippets: hits,
            highlight: _justSaved,
            whisperModel: v.whisperModel,
          );
    // Le trascrizioni non hanno più una card: si aprono dalla card della
    // registrazione. Durante la ricerca i risultati nelle trascrizioni
    // compaiono comunque.
    // Le operazioni in corso su una registrazione si vedono nella sua card,
    // gli errori di Whisper anche (con cosa provare).
    final recordings = {
      for (final r in files[NoteFolder.recordings]!) r.file.path,
    };
    final jobs = [
      for (final j in s.jobs.forCourse(course.id))
        if (!(j.kind == JobKind.whisper && j.state == JobState.failed) &&
            !(j.state == JobState.running && recordings.contains(j.target)))
          j,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      children: [
        for (final j in jobs) _JobTile(job: j),
        section(NoteFolder.recordings, 'Nessuna registrazione salvata'),
        if (hits != null) section(NoteFolder.transcripts, 'Nessun risultato.'),
        section(
          NoteFolder.summaries,
          'Allega qui i riassunti delle lezioni e i tuoi appunti',
          action: TextButton.icon(
            onPressed: () => attachSummaries(context, course),
            icon: const Icon(Icons.attach_file, size: 18),
            label: const Text('Allega'),
          ),
        ),
        section(
          NoteFolder.notes,
          'Nessuna nota.',
          action: TextButton.icon(
            onPressed: () => openNoteEditor(context, course),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Nuovo'),
          ),
        ),
        if (hits == null)
          _AiSection(course: course, files: files[NoteFolder.ai]!)
        else
          section(NoteFolder.ai, 'Nessun risultato.'),
        if (hits != null && hits.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Nessun file contiene questo testo.')),
          ),
      ],
    );
  }
}

class _NotesView {
  const _NotesView(this.files, this.transcripts, this.hits, this.whisperModel);
  final Map<NoteFolder, List<NoteFile>> files;

  /// Modello che userebbe «Trascrivi con Whisper» (null = nessuno).
  final WhisperModelInfo? whisperModel;

  /// Trascrizioni per registrazione (nome della lezione).
  final Map<String, LessonTranscripts> transcripts;

  /// Durante una ricerca: file trovati (percorso → frammento del testo).
  final Map<String, String?>? hits;
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job});
  final BackgroundJob job;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final theme = Theme.of(context);
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(job.title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  SelectableText(
                    switch (job.state) {
                      JobState.running => job.phase,
                      JobState.done => 'Completato',
                      JobState.failed => job.error ?? 'Non riuscito',
                    },
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: job.state == JobState.failed
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                  if (job.state == JobState.running) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: job.fraction),
                  ],
                ],
              ),
            ),
            if (job.state != JobState.running)
              IconButton(
                tooltip: 'Chiudi',
                icon: const Icon(Icons.close),
                onPressed: () => s.jobs.dismiss(job),
              ),
          ],
        ),
      ),
    );
  }
}

enum _Act {
  open,
  summarize,
  openInAi,
  pdf,
  share,
  saveCopy,
  attachStudy,
  rename,
  delete,
}

class _Section extends StatelessWidget {
  const _Section({
    required this.course,
    required this.folder,
    required this.files,
    required this.all,
    required this.transcripts,
    required this.empty,
    this.action,
    this.query,
    this.snippets,
    this.highlight,
    this.whisperModel,
  });
  final Course course;
  final NoteFolder folder;
  final WhisperModelInfo? whisperModel;
  final List<NoteFile> files;
  final Map<NoteFolder, List<NoteFile>> all;
  final Map<String, LessonTranscripts> transcripts;
  final String empty;
  final Widget? action;

  /// Ricerca in corso: testo cercato e frammenti trovati per percorso.
  final String? query;
  final Map<String, String?>? snippets;

  /// Registrazione appena salvata.
  final String? highlight;

  NoteFile? _companion(NoteFolder f, NoteFile of) => all[f]!
      .where((x) => x.name == of.name && x.extension == '.md')
      .firstOrNull;

  bool _has(NoteFolder f, NoteFile of) => _companion(f, of) != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      folder.label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        letterSpacing: 0.3,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  ?action,
                ],
              ),
            ),
            if (files.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(empty, style: theme.textTheme.bodySmall),
              )
            else
              for (final f in files)
                folder == NoteFolder.recordings && f.isAudio
                    ? _RecordingTile(
                        course: course,
                        file: f,
                        transcripts:
                            transcripts[f.name] ?? LessonTranscripts.none,
                        summarized: _has(NoteFolder.summaries, f),
                        query: query,
                        highlighted:
                            highlight != null &&
                            p.equals(highlight!, f.file.path),
                        whisperModel: whisperModel,
                      )
                    : _tile(context, f),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, NoteFile f) {
    final s = context.read<AppServices>();
    final running = s.jobs.runningOn(f.file.path);
    final chips = <String>[
      if (f.isAudio) fileSizeLabel(f.size),
      if (folder != NoteFolder.summaries && _has(NoteFolder.summaries, f))
        'riassunta',
    ];
    final snippet = snippets?[f.file.path];
    final actions = running != null ? const <Widget>[] : _actions(context, f);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(
            f.isAudio ? Icons.graphic_eq : Icons.article_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(f.name),
          subtitle: snippet != null
              ? Text(snippet, maxLines: 2, overflow: TextOverflow.ellipsis)
              : (chips.isEmpty ? null : Text(chips.join(' · '))),
          trailing: running != null
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : PopupMenuButton<_Act>(
                  onSelected: (a) => _act(context, f, a),
                  itemBuilder: (_) => _menu(f),
                ),
          onTap: () => _act(context, f, _Act.open),
        ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(68, 0, 12, 8),
            child: Wrap(spacing: 8, runSpacing: 6, children: actions),
          ),
      ],
    );
  }

  /// «Apri in (AI di riferimento)» per trascrizioni, riassunti e appunti.
  List<Widget> _actions(BuildContext context, NoteFile f) {
    if (folder != NoteFolder.ai && f.extension == '.md') {
      return [
        ReferenceAiButton(onPressed: () => _act(context, f, _Act.openInAi)),
      ];
    }
    return const [];
  }

  List<PopupMenuEntry<_Act>> _menu(NoteFile f) => [
    if (folder == NoteFolder.transcripts)
      const PopupMenuItem(
        value: _Act.summarize,
        child: Text('Riassumi con Gemini'),
      ),
    if (f.extension == '.md')
      const PopupMenuItem(value: _Act.pdf, child: Text('Esporta PDF')),
    if (f.isAudio)
      const PopupMenuItem(
        value: _Act.saveCopy,
        child: Text('Salva una copia…'),
      ),
    const PopupMenuItem(value: _Act.share, child: Text('Condividi')),
    const PopupMenuItem(value: _Act.rename, child: Text('Rinomina…')),
    const PopupMenuItem(
      value: _Act.attachStudy,
      child: Text('Allega a modulo/argomento di Studio'),
    ),
    const PopupMenuDivider(),
    const PopupMenuItem(value: _Act.delete, child: Text('Elimina')),
  ];

  Future<void> _act(BuildContext context, NoteFile f, _Act a) async {
    switch (a) {
      case _Act.open:
        if (folder == NoteFolder.transcripts && f.extension == '.md') {
          // la trascrizione si legge insieme alla sua registrazione
          final rec = all[NoteFolder.recordings]!
              .where((r) => r.isAudio && r.name == lessonOfTranscript(f.name))
              .firstOrNull;
          if (rec != null) {
            await openRecording(
              context,
              course,
              rec,
              transcript: transcriptKindOf(f.name),
              query: query,
            );
            return;
          }
        }
        if (f.isAudio) {
          await openRecording(context, course, f, query: query);
        } else if (f.extension != '.md') {
          // Altri file: lettore interno; "Apri con…" è nel suo menu.
          await openInReader(context, f.file.path, title: f.name);
        } else {
          await openNote(context, course, f, query: query);
        }
      case _Act.rename:
        await renameNote(context, course, f);
      case _Act.openInAi:
        await openNoteInAi(context, course, f);
      case _Act.summarize:
        await summarizeWithGemini(context, course, f);
      case _Act.pdf:
        await exportPdf(context, f, subtitle: course.name);
      case _Act.share:
        await shareNote(context, f);
      case _Act.saveCopy:
        await saveCopy(context, f);
      case _Act.attachStudy:
        await attachNoteToStudy(context, course, f);
      case _Act.delete:
        await trashNote(context, course, f);
    }
  }
}

/// Apre la registrazione (ascolto e trascrizione), con la trascrizione
/// [transcript] in vista.
Future<void> openRecording(
  BuildContext context,
  Course course,
  NoteFile rec, {
  TranscriptKind? transcript,
  String? query,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => RecordingPlayerScreen(
      course: course,
      file: rec.file,
      query: query,
      transcript: transcript,
    ),
  ),
);

/// «12 MB» o «640 KB».
String fileSizeLabel(int bytes) {
  final mb = bytes / (1024 * 1024);
  return mb >= 1
      ? '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB'
      : '${bytes ~/ 1024} KB';
}

/// Una lezione registrata nella card «Registrazioni delle lezioni».
class _RecordingTile extends StatelessWidget {
  const _RecordingTile({
    required this.course,
    required this.file,
    required this.transcripts,
    required this.summarized,
    required this.query,
    required this.highlighted,
    this.whisperModel,
  });

  final Course course;
  final NoteFile file;
  final LessonTranscripts transcripts;
  final bool summarized;
  final String? query;
  final bool highlighted;

  /// Modello che userebbe «Trascrivi con Whisper».
  final WhisperModelInfo? whisperModel;

  /// «Trascrivi con…» / «Trascrivi di nuovo con…».
  Future<void> _chooseModel(BuildContext context) =>
      chooseWhisperModelAndTranscribe(
        context,
        course,
        file,
        again: transcripts.whisper != null,
        current: transcripts.whisperModel,
      );

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final theme = Theme.of(context);
    final f = file;
    final running = s.jobs.runningOn(f.file.path);
    final failed = s.jobs
        .failedOn(f.file.path, kind: JobKind.whisper)
        .lastOrNull;
    final info = [fileSizeLabel(f.size), if (summarized) 'riassunta'];
    return Container(
      decoration: highlighted
          ? BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openRecording(context, course, f, query: query),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.graphic_eq, color: theme.colorScheme.primary),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // un tocco sul nome lo rinomina
                        Tooltip(
                          message: 'Rinomina',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: running == null
                                ? () => renameNote(context, course, f)
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                f.name,
                                style: theme.textTheme.bodyLarge,
                                semanticsLabel:
                                    '${f.name}, tocca per rinominare',
                              ),
                            ),
                          ),
                        ),
                        Text(
                          info.join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (running == null) ...[
                    IconButton(
                      tooltip: 'Elimina la registrazione',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => trashNote(context, course, f),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Altre azioni',
                      onSelected: (v) => switch (v) {
                        'copia' => saveCopy(context, f),
                        'condividi' => shareNote(context, f),
                        'whisper' => _chooseModel(context),
                        _ => attachNoteToStudy(context, course, f),
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'whisper',
                          child: Text(
                            transcripts.whisper != null
                                ? 'Trascrivi di nuovo con…'
                                : 'Trascrivi con un altro modello…',
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'copia',
                          child: Text('Salva una copia…'),
                        ),
                        const PopupMenuItem(
                          value: 'condividi',
                          child: Text('Condividi'),
                        ),
                        const PopupMenuItem(
                          value: 'studio',
                          child: Text('Allega a modulo/argomento di Studio'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              if (running != null) ...[
                Text(
                  '${running.title}: ${running.phase}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: running.fraction),
              ] else
                Row(
                  children: [
                    for (final k in TranscriptKind.values) ...[
                      if (k != TranscriptKind.values.first)
                        const SizedBox(width: 8),
                      Expanded(
                        child: TranscriptButton(
                          kind: k,
                          done: transcripts.of(k) != null,
                          model: k != TranscriptKind.whisper
                              ? null
                              : (transcripts.whisper != null
                                    ? whisperModelShort(
                                        transcripts.whisperModel,
                                      )
                                    : whisperModelShort(whisperModel?.id)),
                          onLongPress: k == TranscriptKind.whisper
                              ? () => _chooseModel(context)
                              : null,
                          onPressed: () => transcripts.of(k) != null
                              ? openRecording(context, course, f, transcript: k)
                              : (k == TranscriptKind.whisper
                                    ? transcribeWithWhisper(context, course, f)
                                    : transcribeWithGemini(context, course, f)),
                        ),
                      ),
                    ],
                  ],
                ),
              if (failed != null && running == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          whisperFailureMessage(failed.error ?? ''),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Chiudi il messaggio',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: const Icon(Icons.close),
                        onPressed: () => s.jobs.dismiss(failed),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «Trascrivi con Whisper/Gemini» o, se la trascrizione c'è, «Vedi
/// trascrizione», con il colore di chi la fa (Whisper azzurro, Gemini viola).
/// Per «Trascrivi con Whisper» la seconda riga dice il modello che si userà;
/// «Vedi trascrizione» resta su una riga sola.
class TranscriptButton extends StatelessWidget {
  const TranscriptButton({
    super.key,
    required this.kind,
    required this.done,
    required this.onPressed,
    this.model,
    this.onLongPress,
  });

  final TranscriptKind kind;
  final bool done;
  final VoidCallback onPressed;

  /// Modello di Whisper da mostrare (null = nessuno).
  final String? model;

  /// Pressione lunga: scelta di un altro modello.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final color = transcriptColor(context, kind);
    final icon = kind == TranscriptKind.whisper
        ? Icons.graphic_eq
        : Icons.auto_awesome_outlined;
    final label = done ? 'Vedi trascrizione' : 'Trascrivi con ${kind.label}';
    final m = model;
    return OutlinedButton.icon(
      onPressed: onPressed,
      onLongPress: onLongPress,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        backgroundColor: done ? color.withValues(alpha: 0.14) : null,
        side: BorderSide(color: color.withValues(alpha: done ? 0.9 : 0.6)),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        tapTargetSize:
            defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS
            ? MaterialTapTargetSize.padded
            : MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(done ? Icons.article_outlined : icon, size: 18),
      // fatta la trascrizione solo «Vedi trascrizione» (il modello si legge
      // nella registrazione: «Trascrizione con Whisper · small»)
      label: m == null || done
          ? Text(
              label,
              textAlign: TextAlign.center,
              semanticsLabel: done
                  ? 'Vedi la trascrizione di ${kind.label}'
                  : null,
            )
          : Semantics(
              label:
                  '$label, modello $m. Tieni premuto per sceglierne un altro',
              excludeSemantics: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, textAlign: TextAlign.center),
                  Text(
                    m,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: color.withValues(alpha: 0.85)),
                  ),
                ],
              ),
            ),
    );
  }
}

/// «Apri in (AI di riferimento)» (trascrizioni, riassunti, appunti).
class ReferenceAiButton extends StatelessWidget {
  const ReferenceAiButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  static final _compact = ButtonStyle(
    visualDensity: VisualDensity.compact,
    // sul telefono l'area di tocco resta piena (48 px)
    tapTargetSize:
        defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS
        ? MaterialTapTargetSize.padded
        : MaterialTapTargetSize.shrinkWrap,
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
  );

  @override
  Widget build(BuildContext context) => RevisionBuilder(
    load: (s) => s.settings.referenceAi(),
    builder: (context, ai) => OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.open_in_new, size: 18),
      label: Text('Apri in ${ai.label}'),
      style: _compact,
    ),
  );
}

/// «Studia con la tua AI di riferimento»: richieste pronte sul materiale del
/// corso. Sotto, le risposte salvate in passato (rinominabili ed
/// eliminabili).
class _AiSection extends StatelessWidget {
  const _AiSection({required this.course, required this.files});
  final Course course;
  final List<NoteFile> files;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Studia con la tua AI di riferimento',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Invia i materiali e gli appunti del corso alla tua AI di '
              'riferimento, incolla anche il prompt suggerito in app in base a '
              'ciò che vuoi ottenere',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in AiTask.values)
                  ActionChip(
                    avatar: const Icon(Icons.auto_awesome_outlined, size: 18),
                    label: Text(t.label),
                    tooltip: t.description,
                    onPressed: () => askReferenceAi(context, course, t),
                  ),
              ],
            ),
            if (files.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                NoteFolder.ai.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            for (final f in files)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.article_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: Text(f.name),
                onTap: () => openNote(context, course, f),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: 'Rinomina',
                      icon: const Icon(Icons.drive_file_rename_outline),
                      onPressed: () => renameNote(context, course, f),
                    ),
                    IconButton(
                      tooltip: 'Elimina la risposta',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => trashNote(context, course, f),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
