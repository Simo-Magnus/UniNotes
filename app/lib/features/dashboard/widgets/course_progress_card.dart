import 'package:flutter/material.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/feedback/motion.dart';
import '../../../core/router/app_shell.dart';
import '../../../core/theme/app_tokens.dart';
import '../dashboard_data.dart';
import '../progress_groups.dart';
import 'dashboard_card.dart';

/// Moduli e argomenti: avanzamento degli insegnamenti di UNA suddivisione
/// alla volta (1° semestre, 2° semestre, annuale…; media degli stati degli
/// argomenti dei moduli, anche quelli dal database) e argomenti da
/// ripassare. Barra azzurra: valore calcolato dall'app.
///
/// La suddivisione si cambia con il selettore sotto il titolo. All'apertura
/// è quella dell'ultimo argomento cambiato, se recente e ancora in corso,
/// altrimenti il semestre in corso (vedi [initialProgressGroup]). La scelta
/// fatta a mano resta finché l'app è aperta, a meno che dopo di essa cambi
/// lo stato di un argomento: allora vale di nuovo la regola di apertura.
class CourseProgressCard extends StatefulWidget {
  const CourseProgressCard({super.key, required this.data});

  final DashboardData data;

  /// Suddivisione scelta a mano e quando (per la sessione dell'app).
  static ({String label, DateTime at})? _manual;

  /// Dimentica la scelta fatta a mano (test).
  @visibleForTesting
  static void resetSelection() => _manual = null;

  @override
  State<CourseProgressCard> createState() => _CourseProgressCardState();
}

class _CourseProgressCardState extends State<CourseProgressCard> {
  static const int _maxCourses = 8;

  /// Suddivisione mostrata: la scelta a mano se è più recente dell'ultimo
  /// cambio di stato di un argomento, altrimenti quella di apertura.
  String? _selected(List<ProgressGroup> groups) {
    final d = widget.data;
    final manual = CourseProgressCard._manual;
    final last = d.lastTopicChange;
    // scelta fatta con i nomi di una versione precedente («2° anno · 1°
    // semestre»): vale il nome senza l'anno
    final manualLabel = manual == null ? null : progressGroupName(manual.label);
    if (manual != null &&
        groups.any((g) => g.label == manualLabel) &&
        (last == null || manual.at.isAfter(last.at))) {
      return manualLabel;
    }
    return initialProgressGroup(groups, last: last, now: d.now);
  }

  void _choose(String label) {
    AppFeedback.of(context).toggle();
    setState(
      () => CourseProgressCard._manual = (label: label, at: DateTime.now()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.data.progressGroups;
    final selected = _selected(groups);
    final group = groups.where((g) => g.label == selected).firstOrNull;
    return DashboardCard(
      icon: Icons.account_tree_outlined,
      title: 'Moduli e argomenti',
      section: 'Studio',
      onTap: () => AppShell.goTo(context, 'Studio'),
      child: group == null
          ? const CardEmptyMessage(
              icon: Icons.checklist_outlined,
              message:
                  'Aggiungi moduli e argomenti ai corsi nella sezione Studio per '
                  'vedere qui il progresso.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _GroupSelector(
                      groups: groups,
                      selected: group.label,
                      onSelected: _choose,
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: motion(context, const Duration(milliseconds: 180)),
                  child: Padding(
                    key: ValueKey(group.label),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Column(
                      children: [
                        for (final p in group.items.take(_maxCourses))
                          _CourseProgressRow(info: p),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Selettore della suddivisione: pillola come quella dell'anno nella Home
/// (nome e freccia in giù) che apre il menu delle suddivisioni presenti.
/// Con una sola suddivisione resta il nome, senza menu.
class _GroupSelector extends StatelessWidget {
  const _GroupSelector({
    required this.groups,
    required this.selected,
    required this.onSelected,
  });

  final List<ProgressGroup> groups;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    final single = groups.length < 2;
    final pill = Container(
      padding: EdgeInsets.fromLTRB(12, 6, single ? 12 : 6, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: t.navGradient,
        ),
        border: Border.all(color: t.navBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              selected,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: t.textPrimary,
              ),
            ),
          ),
          if (!single)
            Icon(Icons.expand_more, size: 20, color: t.textSecondary),
        ],
      ),
    );
    if (single) {
      return Semantics(label: 'Suddivisione: $selected', child: pill);
    }
    // il pulsante (tocco e ruolo) è del menu; qui solo il nome letto
    return PopupMenuButton<String>(
      key: const Key('progress-group'),
      tooltip: 'Cambia suddivisione',
      initialValue: selected,
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final g in groups)
          CheckedPopupMenuItem(
            value: g.label,
            checked: g.label == selected,
            child: Text(g.label),
          ),
      ],
      // area di tocco alta almeno 44 px
      child: Semantics(
        label: 'Suddivisione: $selected',
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Align(widthFactor: 1, heightFactor: 1, child: pill),
        ),
      ),
    );
  }
}

/// Un insegnamento: nome, percentuale, barra e argomenti completati.
class _CourseProgressRow extends StatelessWidget {
  const _CourseProgressRow({required this.info});

  final CourseProgressInfo info;

  @override
  Widget build(BuildContext context) {
    final p = info;
    final theme = Theme.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  p.course.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Text(
                '${(p.progress * 100).round()}%',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: p.progress,
              minHeight: 8,
              color: t.cyan,
              backgroundColor: t.textPrimary.withValues(alpha: 0.09),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            [
              '${p.completed}/${p.topics} argomenti completati',
              if (p.toReview > 0) '${p.toReview} da ripassare',
            ].join(' · '),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
