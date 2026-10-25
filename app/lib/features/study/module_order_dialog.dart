import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/feedback/app_modals.dart';
import '../../core/feedback/feedback_service.dart';
import '../../core/services/app_services.dart';
import '../../models/study.dart';
import '../../widgets/math_text.dart';
import 'reorder_lift.dart';
import 'topic_logic.dart';

/// Ordine dei moduli: finestra di vetro al centro con tutti i moduli
/// dell'insegnamento. Si tiene premuto un modulo (o si trascina la
/// maniglia a destra) e lo si porta nella posizione voluta; l'ordine si
/// salva a ogni spostamento. [selectedId] è il modulo tenuto premuto
/// (evidenziato).
Future<void> showModuleOrderDialog(
  BuildContext context, {
  required List<StudyModule> modules,
  int? selectedId,
}) =>
    // come le altre finestre (molla di iOS); prima aveva una transizione
    // propria che creava una curva nuova a ogni fotogramma
    showAppDialog<void>(
      context: context,
      builder: (c) =>
          _ModuleOrderDialog(modules: modules, selectedId: selectedId),
    );

class _ModuleOrderDialog extends StatefulWidget {
  const _ModuleOrderDialog({required this.modules, this.selectedId});
  final List<StudyModule> modules;
  final int? selectedId;

  @override
  State<_ModuleOrderDialog> createState() => _ModuleOrderDialogState();
}

class _ModuleOrderDialogState extends State<_ModuleOrderDialog> {
  late List<StudyModule> _modules = [...widget.modules];

  Future<void> _reorder(int from, int to) async {
    final next = reorderList(_modules, from, to);
    if (next == null) return;
    AppFeedback.of(context).toggle();
    setState(() => _modules = next);
    final s = context.read<AppServices>();
    await s.study.reorderModules([for (final m in next) m.id!]);
    s.revision.bump();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    // altezza: tutti i moduli se ci stanno, altrimenti la lista scorre
    final listHeight = (_modules.length * 60.0).clamp(60.0, size.height * 0.4);
    return AlertDialog(
      key: const Key('module-order-dialog'),
      // la finestra scorre se è bassa o i caratteri sono grandi (la lista ha
      // un'altezza propria e non deve spingere fuori il resto)
      scrollable: true,
      title: const Text('Ordine dei moduli'),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'Tieni premuto un modulo e trascinalo nella posizione che '
                'vuoi. L\'ordine si salva subito.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: listHeight,
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                autoScrollerVelocityScalar: kReorderAutoScrollVelocity,
                itemCount: _modules.length,
                onReorderStart: (_) => AppFeedback.of(context).tap(),
                onReorderItem: _reorder,
                proxyDecorator: liftProxy,
                itemBuilder: (context, i) {
                  final m = _modules[i];
                  final selected = m.id == widget.selectedId;
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey('order-module-${m.id}'),
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Material(
                        color: selected
                            ? scheme.primary.withValues(alpha: 0.12)
                            : scheme.surfaceContainerHighest.withValues(
                                alpha: 0.35,
                              ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: selected
                                ? scheme.primary.withValues(alpha: 0.5)
                                : scheme.outlineVariant,
                          ),
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 52),
                          child: Row(
                            children: [
                              const SizedBox(width: 12),
                              _Position(i + 1, selected: selected),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: MathText(
                                    m.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyLarge,
                                  ),
                                ),
                              ),
                              // maniglia: trascina subito, anche con il mouse
                              ReorderableDragStartListener(
                                index: i,
                                child: Tooltip(
                                  message: 'Trascina per spostare',
                                  child: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: Icon(
                                      Icons.drag_indicator_rounded,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fatto'),
        ),
      ],
    );
  }
}

/// Numero della posizione del modulo (1, 2, 3…).
class _Position extends StatelessWidget {
  const _Position(this.n, {required this.selected});
  final int n;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? scheme.primary
            : scheme.primary.withValues(alpha: 0.14),
      ),
      child: Text(
        '$n',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: selected ? scheme.onPrimary : scheme.primary,
        ),
      ),
    );
  }
}
