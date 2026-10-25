import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/feedback/app_modals.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/attachment.dart';
import '../../models/course.dart';
import '../../widgets/common.dart';
import '../../widgets/undo_snack_bar.dart';
import '../notes/note_viewer_screen.dart';
import '../notes/notes_store.dart';
import '../reader/reader_screen.dart';
import '../notes/safe_files.dart';

/// File di un allegato su questo dispositivo, se c'è ancora.
Future<File?> attachmentFile(AppServices s, Attachment a) async {
  if (a.storedFile != null) {
    return s.attachmentsLibrary.fileNamed(a.storedFile);
  }
  final path = a.path;
  if (path == null) return null;
  final f = File(path);
  return await fileExistsQuick(path) ? f : null;
}

IconData attachmentIcon(Attachment a) {
  final ext = a.extension;
  if (NotesStore.audioExtensions.contains(ext)) return Icons.graphic_eq;
  if (ext == '.pdf') return Icons.picture_as_pdf_outlined;
  if (ext == '.md' || ext == '.txt') return Icons.article_outlined;
  if (const {'.png', '.jpg', '.jpeg', '.webp', '.heic'}.contains(ext)) {
    return Icons.image_outlined;
  }
  return Icons.attach_file;
}

/// Apre un allegato nel lettore interno; gli appunti collegati (Markdown
/// negli Appunti del corso) nel visualizzatore degli appunti, con modifica
/// ed esportazione. "Apri con…" resta nel menu del lettore.
Future<void> openAttachment(
  BuildContext context,
  Course course,
  Attachment a,
) async {
  final s = context.read<AppServices>();
  final file = await attachmentFile(s, a);
  if (!context.mounted) return;
  if (file == null) {
    showSnack(
      context,
      a.isLinkedNote
          ? 'L\'appunto "${a.title}" non c\'è più (rinominato o eliminato).'
          : 'Il file di "${a.title}" non è più nell\'app su questo dispositivo.',
    );
    return;
  }
  final ext = a.extension;
  if (ext == '.md' || ext == '.txt') {
    final folder = NoteFolder.values
        .where((f) => f.dirName == p.basename(file.parent.path))
        .firstOrNull;
    if (a.isLinkedNote && folder != null) {
      final stat = await file.stat();
      if (!context.mounted) return;
      await openNote(
        context,
        course,
        NoteFile(file, folder, stat.modified, stat.size),
      );
      return;
    }
  }
  await openInReader(context, file.path, title: a.title);
}

/// Elimina l'allegato (e la sua copia nell'app; gli appunti collegati restano).
Future<void> removeAttachment(BuildContext context, Attachment a) async {
  final ok = await confirmDialog(
    context,
    'Rimuovere l\'allegato?',
    a.isLinkedNote
        ? '"${a.title}" non sarà più collegato. L\'appunto resta in Appunti.'
        : 'La copia di "${a.title}" nell\'app verrà eliminata.',
  );
  if (!ok || !context.mounted) return;
  final s = context.read<AppServices>();
  await s.study.deleteAttachment(a.id!);
  s.revision.bump();
  if (!context.mounted) {
    await s.attachmentsLibrary.remove(a.storedFile);
    return;
  }
  // «Annulla»: l'allegato torna con lo stesso id; la copia nell'app si
  // cancella solo alla chiusura dell'avviso
  showUndoSnackBar(
    context,
    'Allegato rimosso: «${a.title}».',
    undoneMessage: 'Allegato ripristinato.',
    onUndo: () async {
      await s.database.db.insert('attachments', a.toMap());
      s.revision.bump();
    },
    onCommit: () => s.attachmentsLibrary.remove(a.storedFile),
  );
}

/// Elimina i file copiati nell'app degli allegati di un modulo/argomento
/// che sta per essere eliminato.
Future<void> removeStoredAttachments(
  AppServices s, {
  int? moduleId,
  int? topicId,
}) async {
  final files = await s.study.storedAttachmentFiles(
    moduleId: moduleId,
    topicId: topicId,
  );
  for (final f in files) {
    await s.attachmentsLibrary.remove(f);
  }
}

/// Da Appunti: allega una registrazione/trascrizione/riassunto a un modulo
/// o a un argomento di Studio scelto dall'utente.
Future<void> attachNoteToStudy(
  BuildContext context,
  Course course,
  NoteFile note,
) async {
  final s = context.read<AppServices>();
  final modules = await s.study.modules(course.id!);
  final topics = await s.study.topicsOfCourse(course.id!);
  if (!context.mounted) return;
  if (modules.isEmpty) {
    showSnack(
      context,
      'Nessun modulo per ${course.name}: crealo in Studio → Argomenti.',
    );
    return;
  }
  final target = await showAppDialog<(int?, int?)>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text('Allega «${note.title}» a…'),
      children: [
        for (final m in modules) ...[
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, (m.id, null)),
            child: Row(
              children: [
                const Icon(Icons.account_tree_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    m.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          for (final t in topics.where((t) => t.moduleId == m.id))
            SimpleDialogOption(
              padding: const EdgeInsets.fromLTRB(50, 6, 24, 6),
              onPressed: () => Navigator.pop(c, (null, t.id)),
              child: Text(t.name),
            ),
        ],
      ],
    ),
  );
  if (target == null) return;
  await s.study.insertAttachment(
    Attachment(
      moduleId: target.$1,
      topicId: target.$2,
      title: '${note.folder.dirName} – ${note.title}',
      path: note.file.path,
      createdAt: DateTime.now(),
    ),
  );
  s.revision.bump();
  if (context.mounted) showSnack(context, 'Allegato in Studio.');
}

enum _Source { device, notes }

/// Allega uno o più file a un modulo ([moduleId]) o a un argomento
/// ([topicId]): dal dispositivo (copiati nell'app) o dagli appunti del corso
/// (registrazioni, trascrizioni, riassunti, appunti, risposte dell'AI).
Future<void> attachTo(
  BuildContext context,
  Course course, {
  int? moduleId,
  int? topicId,
  required String targetName,
}) async {
  final source = await showAppSheet<_Source>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Allega a «$targetName»'),
              subtitle: const Text('Uno o più file'),
            ),
            ListTile(
              leading: const Icon(Icons.mic_none),
              title: const Text('Dagli appunti del corso'),
              subtitle: const Text(
                "Registrazioni, trascrizioni, riassunti, appunti, risposte dell'AI",
              ),
              onTap: () => Navigator.pop(c, _Source.notes),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('File dal dispositivo'),
              subtitle: const Text(
                'PDF, immagini, documenti: copiati nell\'app',
              ),
              onTap: () => Navigator.pop(c, _Source.device),
            ),
          ],
        ),
      ),
    ),
  );
  if (source == null || !context.mounted) return;
  final s = context.read<AppServices>();
  var added = 0;
  Set<AttachmentKind> kinds = const {};
  if (source == _Source.device) {
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(dialogTitle: 'Allega file');
    } catch (e) {
      if (context.mounted) showSnack(context, 'Selezione non riuscita: $e');
      return;
    }
    if (files.isEmpty || !context.mounted) return;
    // tipo del file (teoria, ripasso, esercizi), se non è «Non chiedere più»
    final chosen = await chooseAttachmentKinds(
      context,
      count: files.length,
      name: p.basenameWithoutExtension(files.first.name),
    );
    if (chosen == null) return;
    kinds = chosen;
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      try {
        final name = await s.attachmentsLibrary.store(path);
        await s.study.insertAttachment(
          Attachment(
            moduleId: topicId == null ? moduleId : null,
            topicId: topicId,
            title: p.basenameWithoutExtension(f.name),
            storedFile: name,
            createdAt: DateTime.now(),
            kinds: kinds,
          ),
        );
        added++;
      } catch (e) {
        if (context.mounted) showSnack(context, '${f.name}: $e');
      }
    }
  } else {
    final notes = await s.notes.list(course);
    if (!context.mounted) return;
    final picked = await showAppDialog<List<NoteFile>>(
      context: context,
      builder: (_) => _NotePicker(notes),
    );
    if (picked == null || picked.isEmpty || !context.mounted) return;
    final chosen = await chooseAttachmentKinds(
      context,
      count: picked.length,
      name: picked.first.title,
    );
    if (chosen == null) return;
    kinds = chosen;
    for (final n in picked) {
      await s.study.insertAttachment(
        Attachment(
          moduleId: topicId == null ? moduleId : null,
          topicId: topicId,
          title: '${n.folder.dirName} – ${n.title}',
          path: n.file.path,
          createdAt: DateTime.now(),
          kinds: kinds,
        ),
      );
      added++;
    }
  }
  s.revision.bump();
  if (context.mounted && added > 0) {
    final what = added == 1 ? 'Allegato aggiunto' : '$added allegati aggiunti';
    showSnack(
      context,
      kinds.isEmpty ? what : '$what: ${describeAttachmentKinds(kinds)}',
    );
  }
}

/// Ultimo tipo scelto per i file allegati (codifica di
/// [AttachmentKind.encode]; vuoto = nessun tipo). Senza scelte: Teoria.
const String kAttachmentKindLastKey = 'attachment_kind_last';

/// «Non chiedere più» il tipo del file: si usa l'ultimo tipo scelto. Le
/// domande con «Non chiedere più» hanno le chiavi che iniziano con
/// `dont_ask_` (per un ripristino unico dalle Impostazioni).
const String kAttachmentKindDontAskKey = 'dont_ask_attachment_kind';

/// Tipo predefinito, finché lo studente non ne sceglie uno.
const Set<AttachmentKind> kDefaultAttachmentKinds = {AttachmentKind.theory};

/// Ordine dei tipi nella domanda: teoria, ripasso, esercizi.
const List<AttachmentKind> kAttachmentKindOrder = [
  AttachmentKind.theory,
  AttachmentKind.review,
  AttachmentKind.exercises,
];

/// «Teoria», «Teoria e Ripasso», «Teoria, Ripasso ed Esercizi».
String describeAttachmentKinds(Set<AttachmentKind> kinds) {
  final labels = [
    for (final k in kAttachmentKindOrder)
      if (kinds.contains(k)) k.label,
  ];
  if (labels.length <= 1) return labels.join();
  final last = labels.removeLast();
  final and = RegExp('^[AEIOU]').hasMatch(last) ? 'ed' : 'e';
  return '${labels.join(', ')} $and $last';
}

/// Chiede il tipo dei file che si stanno allegando (teoria, ripasso,
/// esercizi; anche più di uno, o nessuno). Con «Non chiedere più» la
/// domanda non compare più e si usa l'ultimo tipo scelto (all'inizio
/// Teoria). null = annullato: non si allega niente.
Future<Set<AttachmentKind>?> chooseAttachmentKinds(
  BuildContext context, {
  required int count,
  String? name,
}) async {
  final s = context.read<AppServices>();
  final last = await s.settings.get(kAttachmentKindLastKey);
  final initial = last == null
      ? kDefaultAttachmentKinds
      : AttachmentKind.parse(last);
  if (await s.settings.get(kAttachmentKindDontAskKey) == '1') return initial;
  if (!context.mounted) return null;
  final r = await showAppDialog<(Set<AttachmentKind>, bool)>(
    context: context,
    builder: (_) => _KindDialog(initial: initial, count: count, name: name),
  );
  if (r == null) return null;
  await s.settings.set(
    kAttachmentKindLastKey,
    AttachmentKind.encode(r.$1) ?? '',
  );
  if (r.$2) await s.settings.set(kAttachmentKindDontAskKey, '1');
  return r.$1;
}

/// Domanda del tipo: tre caselle (Teoria, Ripasso, Esercizi, anche più di
/// una), «Non chiedere più», Annulla e Allega.
class _KindDialog extends StatefulWidget {
  const _KindDialog({required this.initial, required this.count, this.name});
  final Set<AttachmentKind> initial;
  final int count;
  final String? name;

  @override
  State<_KindDialog> createState() => _KindDialogState();
}

class _KindDialogState extends State<_KindDialog> {
  late final Set<AttachmentKind> _kinds = {...widget.initial};
  bool _dontAsk = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final what = widget.count == 1 && widget.name != null
        ? '«${widget.name}»'
        : '${widget.count} file';
    return AlertDialog(
      scrollable: true,
      key: const Key('attachment-kind-dialog'),
      title: Text(widget.count == 1 ? 'Che tipo di file è?' : 'Che file sono?'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$what: scegli uno o più tipi. Si possono cambiare anche dopo, '
              'dal menu del file.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in kAttachmentKindOrder)
                  FilterChip(
                    key: ValueKey('kind-${k.key}'),
                    avatar: Icon(k.icon, size: 18, color: k.colorOn(context)),
                    label: Text(k.label),
                    selected: _kinds.contains(k),
                    showCheckmark: false,
                    selectedColor: k.colorOn(context).withValues(alpha: 0.22),
                    side: BorderSide(
                      color: _kinds.contains(k)
                          ? k.colorOn(context)
                          : theme.colorScheme.outlineVariant,
                    ),
                    onSelected: (v) =>
                        setState(() => v ? _kinds.add(k) : _kinds.remove(k)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('kind-dont-ask'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _dontAsk,
              onChanged: (v) => setState(() => _dontAsk = v ?? false),
              title: const Text('Non chiedere più'),
              subtitle: const Text('I prossimi file avranno questo tipo.'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          key: const Key('kind-confirm'),
          onPressed: () => Navigator.pop(context, (
            Set<AttachmentKind>.of(_kinds),
            _dontAsk,
          )),
          child: const Text('Allega'),
        ),
      ],
    );
  }
}

class _NotePicker extends StatefulWidget {
  const _NotePicker(this.notes);
  final Map<NoteFolder, List<NoteFile>> notes;

  @override
  State<_NotePicker> createState() => _NotePickerState();
}

class _NotePickerState extends State<_NotePicker> {
  final _selected = <NoteFile>{};

  @override
  Widget build(BuildContext context) {
    final groups = widget.notes.entries.where((e) => e.value.isNotEmpty);
    return AlertDialog(
      title: const Text('Appunti del corso'),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 420,
        child: groups.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nessun appunto per questo corso: registra una lezione o '
                  'scrivi un appunto nella sezione Appunti.',
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final g in groups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                      child: Text(
                        g.key.dirName,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    for (final n in g.value)
                      CheckboxListTile(
                        dense: true,
                        value: _selected.contains(n),
                        title: Text(n.title),
                        secondary: Icon(
                          n.isAudio ? Icons.graphic_eq : Icons.article_outlined,
                        ),
                        onChanged: (v) => setState(
                          () => v == true
                              ? _selected.add(n)
                              : _selected.remove(n),
                        ),
                      ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected.toList()),
          child: Text(
            _selected.length <= 1 ? 'Allega' : 'Allega ${_selected.length}',
          ),
        ),
      ],
    );
  }
}

/// Icona e colore di Teoria, Esercizi e Ripasso (stessi in tutta l'app).
extension AttachmentKindStyle on AttachmentKind {
  IconData get icon => switch (this) {
    AttachmentKind.theory => Icons.menu_book_outlined,
    AttachmentKind.exercises => Icons.edit_note,
    AttachmentKind.review => Icons.replay,
  };

  Color get color => switch (this) {
    AttachmentKind.theory => const Color(0xFF1E88E5),
    AttachmentKind.exercises => const Color(0xFFF57C00),
    AttachmentKind.review => const Color(0xFF8E24AA),
  };

  /// Colore per il tema in uso: nel tema chiaro scurito quanto basta per
  /// 3:1 come icona (l'arancione degli esercizi sul bianco non ci arriva);
  /// nel tema scuro invariato.
  Color colorOn(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
      ? readableOn(color, Brightness.light, minRatio: 3)
      : color;
}

/// Segna o toglie un tipo (teoria, esercizi, ripasso) su un allegato.
Future<void> toggleAttachmentKind(
  BuildContext context,
  Attachment a,
  AttachmentKind kind,
) async {
  final s = context.read<AppServices>();
  final kinds = {...a.kinds};
  kinds.contains(kind) ? kinds.remove(kind) : kinds.add(kind);
  await s.study.setAttachmentKinds(a.id!, kinds);
  s.revision.bump();
}

enum _FileAction { remove }

/// Casella di un file allegato: icona del file, titolo (tocca per aprire),
/// icone dei tipi segnati (Teoria, Esercizi, Ripasso) e menu per segnare il
/// tipo o rimuovere il file. Con [editable] false solo apertura.
class AttachmentTile extends StatelessWidget {
  const AttachmentTile({
    super.key,
    required this.course,
    required this.attachment,
    this.editable = true,
    this.onOpen,
  });

  final Course course;
  final Attachment attachment;
  final bool editable;

  /// Apertura al tocco (null = [openAttachment]); la schermata Focus la usa
  /// per tenere il riquadro della sessione sopra il file aperto.
  final ValueChanged<Attachment>? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final a = attachment;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen != null
              ? () => onOpen!(a)
              : () => openAttachment(context, course, a),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(
                  attachmentIcon(a),
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    a.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                // tipi del file: solo quelli segnati, colorati
                for (final k in AttachmentKind.values)
                  if (a.kinds.contains(k))
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Tooltip(
                        message: k.label,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: k.colorOn(context).withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            k.icon,
                            size: 16,
                            color: k.colorOn(context),
                            semanticLabel: k.label,
                          ),
                        ),
                      ),
                    ),
                if (editable)
                  PopupMenuButton<Object>(
                    tooltip: 'Tipo del file e altro',
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (v) => switch (v) {
                      AttachmentKind k => toggleAttachmentKind(context, a, k),
                      _FileAction.remove => removeAttachment(context, a),
                      _ => null,
                    },
                    itemBuilder: (_) => [
                      for (final k in AttachmentKind.values)
                        CheckedPopupMenuItem<Object>(
                          value: k,
                          checked: a.kinds.contains(k),
                          child: Row(
                            children: [
                              Icon(k.icon, size: 18, color: k.colorOn(context)),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  k.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const PopupMenuDivider(),
                      const PopupMenuItem<Object>(
                        value: _FileAction.remove,
                        child: Text('Rimuovi file'),
                      ),
                    ],
                  )
                else
                  const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Elenco di allegati come caselle ([AttachmentTile]).
class AttachmentList extends StatelessWidget {
  const AttachmentList({
    super.key,
    required this.course,
    required this.attachments,
    this.editable = true,
    this.onOpen,
  });

  final Course course;
  final List<Attachment> attachments;
  final bool editable;
  final ValueChanged<Attachment>? onOpen;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final a in attachments)
        AttachmentTile(
          key: ValueKey('file-${a.id}'),
          course: course,
          attachment: a,
          editable: editable,
          onOpen: onOpen,
        ),
    ],
  );
}
