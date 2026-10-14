import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../models/attachment.dart';
import '../../models/course.dart';
import '../../models/study.dart';
import '../../widgets/math_text.dart';
import 'attachments.dart';
import 'study_widgets.dart';

enum _TopicAction { focus, ai, delete, note }

/// Riga di un argomento: pallino dello stato (tocca per cambiarlo) a
/// sinistra, nome, menu. Sotto, rientrati: la nota, i file allegati (ognuno
/// con le icone Teoria/Esercizi/Ripasso) e «Aggiungi file».
/// Toccando l'argomento si apre la nota. Per spostarlo: tieni premuto e
/// trascina (vedi ModuleCard).
class TopicTile extends StatelessWidget {
  const TopicTile({
    super.key,
    required this.topic,
    required this.course,
    required this.onChanged,
    required this.onNote,
    required this.onDelete,
    this.attachments = const [],
    this.onAddFile,
    this.onAskAi,
    this.onFocus,
  });

  final Topic topic;
  final Course course;
  final List<Attachment> attachments;

  /// Stato cambiato dal pallino.
  final ValueChanged<Topic> onChanged;

  /// Nota (e nome) dell'argomento.
  final VoidCallback onNote;
  final VoidCallback onDelete;
  final VoidCallback? onAddFile;
  final VoidCallback? onAskAi;

  /// Sessione Focus collegata all'argomento.
  final VoidCallback? onFocus;

  /// Rientro di nota, file e «Aggiungi file»: allineati al nome.
  static double indent(BuildContext context) => _touch(context) + 4;

  /// Telefono: area di tocco di 44 px; PC: compatta.
  static double _touch(BuildContext context) {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS
        ? 44.0
        : 36.0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statusColor = topic.status.color(scheme);
    final notes = topic.notes?.trim().isEmpty ?? true ? null : topic.notes!;
    final touch = _touch(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onNote,
            child: Row(
              children: [
                // stato: il pallino a sinistra del nome
                PopupMenuButton<TopicStatus>(
                  tooltip: 'Stato: ${topic.status.label}',
                  padding: EdgeInsets.zero,
                  initialValue: topic.status,
                  onSelected: (st) => onChanged(topic.copyWith(status: st)),
                  itemBuilder: (_) => [
                    for (final st in TopicStatus.values)
                      PopupMenuItem(
                        value: st,
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.circle,
                            size: 14,
                            color: st.color(scheme),
                          ),
                          title: Text(st.label),
                        ),
                      ),
                  ],
                  child: SizedBox(
                    width: touch,
                    height: touch,
                    child: Center(
                      child: Icon(
                        Icons.circle,
                        size: 12,
                        color: statusColor,
                        semanticLabel: 'Stato: ${topic.status.label}',
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: MathText(topic.name),
                  ),
                ),
                _menu(),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(left: indent(context), right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (notes != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: MathText(
                      notes,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                if (attachments.isNotEmpty)
                  AttachmentList(course: course, attachments: attachments),
                if (onAddFile != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: onAddFile,
                      icon: const Icon(Icons.attach_file, size: 18),
                      label: const Text('Aggiungi file'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _menu() => PopupMenuButton<_TopicAction>(
    tooltip: 'Altre azioni',
    onSelected: (a) => switch (a) {
      _TopicAction.focus => onFocus?.call(),
      _TopicAction.ai => onAskAi?.call(),
      _TopicAction.delete => onDelete(),
      _TopicAction.note => onNote(),
    },
    itemBuilder: (_) => [
      if (onFocus != null)
        const PopupMenuItem(
          value: _TopicAction.focus,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.center_focus_strong_outlined),
            title: Text('Sessione focus sull\'argomento'),
          ),
        ),
      if (onAskAi != null)
        const PopupMenuItem(
          value: _TopicAction.ai,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.auto_awesome_outlined),
            title: Text('Revisiona con AI'),
          ),
        ),
      const PopupMenuItem(
        value: _TopicAction.delete,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.delete_outline),
          title: Text('Elimina argomento'),
        ),
      ),
      const PopupMenuItem(
        value: _TopicAction.note,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.sticky_note_2_outlined),
          title: Text('Nota'),
        ),
      ),
    ],
  );
}
