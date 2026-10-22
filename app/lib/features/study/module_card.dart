import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ViewportOffset;
import 'package:provider/provider.dart';

import '../../core/feedback/feedback_service.dart';
import '../../core/feedback/motion.dart';
import '../../core/services/app_services.dart';
import '../../models/attachment.dart';
import '../../models/course.dart';
import '../../models/study.dart';
import '../../utils/grade_math.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/math_text.dart';
import 'attachments.dart';
import 'reorder_lift.dart';
import 'study_ai.dart';
import 'study_sessions_tab.dart' show openStudySession;
import 'study_widgets.dart';
import 'topic_dialog.dart';
import 'topic_logic.dart';
import 'topic_tile.dart';

enum _ModuleAction { focus, ai, deleteTopics, delete, note }

/// Modulo con il suo avanzamento e la lista degli argomenti.
///
/// Gli argomenti si spostano tenendo premuta la loro riga e trascinando: la
/// riga si solleva, le altre scorrono per farle posto e, vicino ai bordi
/// dello schermo, la pagina scorre da sola (più veloce quanto più si va
/// oltre il bordo). Tenendo premuto il nome del modulo si apre l'ordine dei
/// moduli ([onArrange]).
class ModuleCard extends StatefulWidget {
  const ModuleCard({
    super.key,
    required this.course,
    required this.module,
    required this.topics,
    required this.color,
    this.attachments = const [],
    this.onArrange,
  });

  final Course course;
  final StudyModule module;
  final List<Topic> topics;
  final Color color;

  /// Allegati del modulo e dei suoi argomenti.
  final List<Attachment> attachments;

  /// Apre l'ordine dei moduli (tenendo premuto il nome del modulo).
  final VoidCallback? onArrange;

  @override
  State<ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<ModuleCard> {
  /// Ordine mostrato degli argomenti: cambia subito al rilascio, poi si
  /// salva.
  late List<Topic> _topics = widget.topics;

  /// Gli argomenti stanno in un viewport senza scorrimento proprio: così la
  /// lista riordinabile usa lo scorrimento della pagina e la fa scorrere da
  /// sola quando si trascina un argomento vicino ai bordi.
  final ViewportOffset _fixed = ViewportOffset.zero();

  @override
  void dispose() {
    _fixed.dispose();
    super.dispose();
  }

  StudyModule get module => widget.module;
  Course get course => widget.course;

  @override
  void didUpdateWidget(ModuleCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.topics, widget.topics)) _topics = widget.topics;
  }

  Future<void> _write(Future<void> Function(AppServices s) op) async {
    final s = context.read<AppServices>();
    try {
      await op(s);
    } catch (e) {
      // la lista si ricarica comunque: mostra quello che c'è davvero
      if (mounted) showSnack(context, 'Modifica non salvata: $e');
    }
    s.revision.bump();
  }

  Future<void> _note() async {
    final r = await showNoteDialog(
      context,
      title: 'Nota del modulo',
      name: module.name,
      note: module.notes,
    );
    if (r == null || !mounted) return;
    await _write(
      (s) => s.study.updateModule(module.copyWith(name: r.name, notes: r.note)),
    );
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(
      context,
      'Eliminare il modulo?',
      'Verranno eliminati anche i ${_topics.length} argomenti di '
          '"${module.name}" e gli allegati.',
    );
    if (!ok || !mounted) return;
    await _write((s) async {
      await removeStoredAttachments(s, moduleId: module.id);
      await s.study.deleteModule(module.id!);
    });
  }

  /// Elimina tutti gli argomenti del modulo (e i loro file); il modulo resta.
  Future<void> _deleteTopics() async {
    final topics = [..._topics];
    if (topics.isEmpty) return;
    final ok = await confirmDialog(
      context,
      'Eliminare tutti gli argomenti?',
      topics.length == 1
          ? 'L\'argomento di "${module.name}" verrà eliminato con i suoi '
                'allegati. Il modulo resta; le sessioni di studio collegate '
                'restano, senza argomento.'
          : 'I ${topics.length} argomenti di "${module.name}" verranno '
                'eliminati con i loro allegati. Il modulo resta; le sessioni '
                'di studio collegate restano, senza argomento.',
    );
    if (!ok || !mounted) return;
    await _write((s) async {
      for (final t in topics) {
        await removeStoredAttachments(s, topicId: t.id);
        await s.study.deleteTopic(t.id!);
      }
    });
  }

  Future<void> _addTopic() async {
    final name = await promptText(
      context,
      title: 'Nuovo argomento',
      label: 'Nome',
    );
    if (name == null || !mounted) return;
    await _write((s) async {
      final sort = await s.study.nextTopicSort(module.id!);
      await s.study.insertTopic(
        Topic(moduleId: module.id!, name: name, sort: sort),
      );
    });
  }

  Future<void> _topicNote(Topic topic) async {
    final r = await showNoteDialog(
      context,
      title: 'Nota dell\'argomento',
      name: topic.name,
      note: topic.notes,
    );
    if (r == null || !mounted) return;
    await _write(
      (s) => s.study.updateTopic(withNameNote(topic, r.name, r.note)),
    );
  }

  Future<void> _deleteTopic(Topic topic) async {
    final ok = await confirmDialog(
      context,
      'Eliminare l\'argomento?',
      '"${topic.name}" verrà eliminato con i suoi allegati. Le sessioni di '
          'studio collegate restano, senza argomento.',
    );
    if (!ok || !mounted) return;
    await _write((s) async {
      await removeStoredAttachments(s, topicId: topic.id);
      await s.study.deleteTopic(topic.id!);
    });
  }

  void _reorder(int from, int to) {
    final next = reorderList(_topics, from, to);
    if (next == null) return;
    AppFeedback.of(context).toggle();
    setState(() => _topics = next);
    _write((s) => s.study.reorderTopics([for (final t in next) t.id!]));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topics = _topics;
    final progress = courseProgress(topics.map((t) => t.status));
    final done = topics.where((t) => t.status.progressWeight >= 1).length;
    final notes = module.notes?.trim().isEmpty ?? true ? null : module.notes!;
    final own = [
      for (final a in widget.attachments)
        if (a.moduleId == module.id && a.topicId == null) a,
    ];
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: ValueKey('module-name-${module.id}'),
              borderRadius: BorderRadius.circular(8),
              onTap: _note,
              // tieni premuto il nome: ordine dei moduli al centro
              onLongPress: widget.onArrange == null
                  ? null
                  : () {
                      AppFeedback.of(context).tap();
                      widget.onArrange!();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: MathText(
                  module.name,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
          ),
          AnimatedCount(
            value: done,
            format: (v) => '$v/${topics.length}',
            semanticsLabel: 'Argomenti completati',
            style: theme.textTheme.bodySmall,
          ),
          _menu(),
        ],
      ),
    );
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ProgressRow(value: progress),
          ),
          if (notes != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: MathText(
                notes,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (own.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: AttachmentList(course: course, attachments: own),
            ),
          const SizedBox(height: 4),
          ShrinkWrappingViewport(
            offset: _fixed,
            slivers: [
              SliverReorderableList(
                autoScrollerVelocityScalar: kReorderAutoScrollVelocity,
                itemCount: topics.length,
                onReorderStart: (_) => AppFeedback.of(context).tap(),
                onReorderItem: _reorder,
                proxyDecorator: liftProxy,
                itemBuilder: (context, i) {
                  final t = topics[i];
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey('topic-${t.id}'),
                    index: i,
                    child: TopicTile(
                      topic: t,
                      attachments: [
                        for (final a in widget.attachments)
                          if (a.topicId == t.id) a,
                      ],
                      course: course,
                      onAddFile: () => attachTo(
                        context,
                        course,
                        topicId: t.id,
                        targetName: t.name,
                      ),
                      onAskAi: () =>
                          askAiStudy(context, course, module: module, topic: t),
                      onChanged: (next) {
                        // argomento appena completato: conferma con suono e
                        // vibrazione; gli altri cambi vibrano appena
                        final before = t.status.progressWeight >= 1;
                        final after = next.status.progressWeight >= 1;
                        final fb = AppFeedback.of(context);
                        after && !before ? fb.complete() : fb.toggle();
                        _write((s) => s.study.updateTopic(next));
                      },
                      onNote: () => _topicNote(t),
                      onDelete: () => _deleteTopic(t),
                      onFocus: () => openStudySession(
                        context,
                        courseId: course.id!,
                        moduleId: module.id,
                        topicId: t.id,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TextButton.icon(
                onPressed: _addTopic,
                icon: const Icon(Icons.add),
                label: const Text('Aggiungi argomento'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _menu() => PopupMenuButton<_ModuleAction>(
    tooltip: 'Altre azioni',
    onSelected: (a) => switch (a) {
      _ModuleAction.focus => openStudySession(
        context,
        courseId: course.id!,
        moduleId: module.id,
      ),
      _ModuleAction.ai => askAiStudy(context, course, module: module),
      _ModuleAction.deleteTopics => _deleteTopics(),
      _ModuleAction.delete => _delete(),
      _ModuleAction.note => _note(),
    },
    itemBuilder: (_) => [
      const PopupMenuItem(
        value: _ModuleAction.focus,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.center_focus_strong_outlined),
          title: Text('Sessione focus sul modulo'),
        ),
      ),
      const PopupMenuItem(
        value: _ModuleAction.ai,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.auto_awesome_outlined),
          title: Text('Revisiona con AI'),
        ),
      ),
      if (_topics.isNotEmpty)
        const PopupMenuItem(
          value: _ModuleAction.deleteTopics,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.playlist_remove_rounded),
            title: Text('Elimina tutti gli argomenti'),
          ),
        ),
      const PopupMenuItem(
        value: _ModuleAction.delete,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.delete_outline),
          title: Text('Elimina modulo'),
        ),
      ),
      const PopupMenuItem(
        value: _ModuleAction.note,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.sticky_note_2_outlined),
          title: Text('Nota'),
        ),
      ),
    ],
  );
}
