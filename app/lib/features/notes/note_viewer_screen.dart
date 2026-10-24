import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/feedback/motion.dart';
import '../../core/router/safe_pop.dart';
import '../../core/services/app_services.dart';
import '../../models/course.dart';
import '../../widgets/common.dart';
import 'formula_dialog.dart';
import 'lesson_transcripts.dart';
import 'markdown_view.dart';
import 'notes_actions.dart';
import 'notes_store.dart';
import 'safe_files.dart';
import 'spell_check.dart';
import '../../core/constants/text_limits.dart';

Future<void> openNote(
  BuildContext context,
  Course course,
  NoteFile note, {
  String? query,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => NoteViewerScreen(course: course, note: note, query: query),
  ),
);

Future<void> openNoteEditor(
  BuildContext context,
  Course course, {
  NoteFile? note,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => NoteEditorScreen(course: course, note: note),
    ),
  );
  if (context.mounted) context.read<AppServices>().revision.bump();
}

/// Lettura di trascrizioni, riassunti e appunti (Markdown formattato).
class NoteViewerScreen extends StatefulWidget {
  const NoteViewerScreen({
    super.key,
    required this.course,
    required this.note,
    this.query,
  });
  final Course course;
  final NoteFile note;

  /// Testo da cercare all'apertura.
  final String? query;

  @override
  State<NoteViewerScreen> createState() => _NoteViewerScreenState();
}

class _NoteViewerScreenState extends State<NoteViewerScreen> {
  late Future<String> _text = _read();

  /// Testo del file; le trascrizioni del vecchio formato senza gli orari.
  Future<String> _read() =>
      readTextLenient(widget.note.file).then(stripTranscriptTimes);
  final _view = GlobalKey<SearchableMarkdownViewState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.note.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Trova nel testo (Ctrl+F)',
            icon: const Icon(Icons.search),
            onPressed: () => _view.currentState?.openFind(),
          ),
          IconButton(
            tooltip: 'Modifica',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              await openNoteEditor(context, widget.course, note: widget.note);
              // il blocco non deve restituire il Future (setState lo rifiuta)
              if (mounted) {
                setState(() {
                  _text = _read();
                });
              }
            },
          ),
          // una risposta dell'AI non si rimanda all'AI
          if (widget.note.folder != NoteFolder.ai)
            IconButton(
              tooltip: 'Apri nell\'AI di riferimento',
              icon: const Icon(Icons.open_in_new),
              onPressed: () =>
                  openNoteInAi(context, widget.course, widget.note),
            ),
          IconButton(
            tooltip: 'Esporta PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: () =>
                exportPdf(context, widget.note, subtitle: widget.course.name),
          ),
          IconButton(
            tooltip: 'Condividi',
            icon: const Icon(Icons.ios_share),
            onPressed: () => shareNote(context, widget.note),
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _text,
        builder: (context, snap) {
          if (snap.hasError) {
            return EmptyState(
              icon: Icons.error_outline,
              message: 'Impossibile leggere il file: ${snap.error}',
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: SearchableMarkdownView(
                snap.data!,
                key: _view,
                initialQuery: widget.query,
                // linea rossa sulle parole errate anche in lettura (non
                // nelle risposte dell'AI: non sono testi dell'utente)
                spellLanguage: widget.note.folder == NoteFolder.ai
                    ? null
                    : spellLanguageOf(widget.course.examLanguage),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Editor semplice in Markdown (nuova nota o modifica di una nota, di un
/// riassunto o di una trascrizione), con il controllo ortografico del
/// sistema (spell_check.dart) nella lingua dell'insegnamento.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, required this.course, this.note});
  final Course course;
  final NoteFile? note;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen>
    with DeferredSpellCheck {
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final n = widget.note;
    if (n == null) {
      // «2026-10-05 08:30 Nota»: il titolo mostra i due punti, nel nome del
      // file diventano «꞉» (writeText)
      _title.text =
          '${NotesStore.displayName(NotesStore.lessonBaseName(DateTime.now()))}'
          ' Nota';
      _loaded = true;
      enableSpellCheck();
    } else {
      _title.text = n.title;
      // file non in UTF-8 si legge lo stesso; file sparito: si dice e si
      // torna indietro (prima la rotella girava per sempre)
      n.file
          .readAsBytes()
          .then((b) {
            if (!mounted) return;
            setState(() {
              _body.text = stripTranscriptTimes(
                utf8.decode(b, allowMalformed: true),
              );
              _loaded = true;
            });
            enableSpellCheck();
          })
          .catchError((Object e) {
            if (!mounted) return;
            showSnack(context, 'Impossibile aprire la nota: $e');
            // già chiusa con Indietro durante la lettura: la pagina sotto
            // resta
            popIfCurrent(context);
          });
    }
  }

  @override
  String get spellLanguage => spellLanguageOf(widget.course.examLanguage);

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  bool _saving = false;

  Future<void> _save() async {
    // doppio clic su «Salva»: una sola nota (e un solo ritorno indietro)
    if (_saving) return;
    _saving = true;
    final s = context.read<AppServices>();
    final n = widget.note;
    try {
      if (n != null) {
        // scrittura sicura: con il disco pieno la nota di prima non resta
        // troncata (il testo nuovo resta comunque nel campo)
        await writeStringAtomic(n.file, _body.text);
      } else {
        await s.notes.writeText(
          widget.course,
          NoteFolder.notes,
          _title.text,
          _body.text,
        );
      }
    } catch (e) {
      // file bloccato, disco pieno: il testo resta nel campo
      _saving = false;
      if (mounted) showSnack(context, 'Salvataggio non riuscito: $e');
      return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    // Indietro durante il salvataggio: la pagina sotto resta
    popIfCurrent(context);
    if (messenger != null && messenger.mounted) {
      showSuccessSnack(
        messenger.context,
        widget.note == null ? 'Nota salvata.' : 'Modifiche salvate.',
        messenger: messenger,
      );
    }
  }

  /// «Inserisci formula»: LaTeX con l'anteprima dal vivo, al cursore.
  Future<void> _formula() async {
    final sel = _body.selection;
    final selected = sel.isValid && !sel.isCollapsed
        ? sel.textInside(_body.text)
        : '';
    final f = await showFormulaDialog(context, initial: selected);
    if (f == null || !mounted) return;
    setState(() => insertFormula(_body, f));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.note == null ? 'Nuova nota' : 'Modifica'),
        actions: [
          IconButton(
            tooltip: 'Inserisci formula',
            icon: const Icon(Icons.functions),
            onPressed: _loaded ? _formula : null,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Pressable(
              child: FilledButton(
                onPressed: _loaded ? _save : null,
                child: const Text('Salva'),
              ),
            ),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (widget.note == null)
                    TextField(
                      controller: _title,
                      inputFormatters: TextLimits.max(TextLimits.noteTitle),
                      decoration: const InputDecoration(labelText: 'Titolo'),
                    ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: TextField(
                      controller: _body,
                      expands: true,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      spellCheckConfiguration: spellCheck,
                      contextMenuBuilder: spellCheckContextMenu,
                      decoration: const InputDecoration(
                        hintText:
                            'Scrivi in Markdown: # titolo, **grassetto**, '
                            '==evidenziato==, - elenco, formule \$x^2\$',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
