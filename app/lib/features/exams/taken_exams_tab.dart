import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../models/exam.dart';
import '../../utils/grade_math.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../courses/course_ui.dart';
import 'exam_stats.dart';
import 'exam_tile.dart';
import 'exam_ui.dart';
import 'pending_exams_tab.dart';

/// Esito delle prove sostenute, scelto con il filtro a icona. Nessun esito
/// scelto = tutte le prove (non c'è l'opzione «Tutti»).
enum OutcomeFilter {
  passed('Superati', Icons.check_circle_outline),
  failed('Non superati', Icons.cancel_outlined),
  awaiting('In attesa', Icons.hourglass_bottom);

  const OutcomeFilter(this.label, this.icon);
  final String label;
  final IconData icon;

  bool matches(Exam e) => switch (this) {
    OutcomeFilter.passed => e.status == ExamStatus.passed,
    OutcomeFilter.failed =>
      e.status == ExamStatus.failed || e.status == ExamStatus.cancelled,
    OutcomeFilter.awaiting => e.status == ExamStatus.taken,
  };
}

/// Vero se [e] rientra negli esiti scelti (nessuno scelto = tutte).
bool matchesOutcomes(Set<OutcomeFilter> outcomes, Exam e) =>
    outcomes.isEmpty || outcomes.any((o) => o.matches(e));

/// Tab "Sostenuti": raggruppati per corso, con prove in itinere e loro media.
class TakenExamsTab extends StatefulWidget {
  const TakenExamsTab({
    super.key,
    required this.data,
    required this.selectedId,
    required this.onSelect,
  });

  final ExamsData data;
  final int? selectedId;
  final ValueChanged<Exam> onSelect;

  @override
  State<TakenExamsTab> createState() => _TakenExamsTabState();
}

class _TakenExamsTabState extends State<TakenExamsTab> {
  final Set<OutcomeFilter> _outcomes = {};
  KindFilter? _kind;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final taken = data.scopedExams
        .where((e) => kTakenStatuses.contains(e.status))
        .toList();
    final visible = taken.where(
      (e) => matchesOutcomes(_outcomes, e) && _kind.matches(e),
    );
    final groups = groupByCourse(visible, data.courses);

    int count(ExamStatus s) => taken.where((e) => e.status == s).length;

    final children = <Widget>[
      _OutcomeSummary(
        passed: count(ExamStatus.passed),
        failed: count(ExamStatus.failed),
        awaiting: count(ExamStatus.taken),
        cancelled: count(ExamStatus.cancelled),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        // «Esami» / «Itinere/esoneri» e, accanto, il filtro a icona degli
        // esiti (Superati, Non superati, In attesa)
        child: LayoutBuilder(
          builder: (context, c) => Row(
            children: [
              Flexible(
                child: KindFilterBar(
                  value: _kind,
                  onChanged: (k) => setState(() => _kind = k),
                  narrow: c.maxWidth < kNarrowFilters,
                ),
              ),
              const SizedBox(width: 8),
              OutcomeFilterButton(
                selected: _outcomes,
                onChanged: (o, on) =>
                    setState(() => on ? _outcomes.add(o) : _outcomes.remove(o)),
              ),
            ],
          ),
        ),
      ),
    ];

    if (groups.isEmpty) {
      children.add(
        const SizedBox(
          height: 300,
          child: EmptyState(
            icon: Icons.assignment_turned_in_outlined,
            message: 'Nessuna prova sostenuta con questi filtri.',
          ),
        ),
      );
    } else {
      for (final sg in groupBySemester(groups, (g) => g.course)) {
        children.add(SectionHeader(sg.label));
        for (final g in sg.items) {
          children.add(
            _CourseGroupCard(
              group: g,
              // La media in itinere usa tutte le prove del corso, non solo quelle filtrate.
              midtermAvg: midtermAverage(
                data.exams.where((e) => e.courseId == g.courseId),
              ),
              data: data,
              selectedId: widget.selectedId,
              onSelect: widget.onSelect,
            ),
          );
        }
      }
    }
    children.add(const SizedBox(height: 96));
    return ListView(children: children);
  }
}

class _OutcomeSummary extends StatelessWidget {
  const _OutcomeSummary({
    required this.passed,
    required this.failed,
    required this.awaiting,
    required this.cancelled,
  });
  final int passed;
  final int failed;
  final int awaiting;
  final int cancelled;

  @override
  Widget build(BuildContext context) {
    Widget tile(String label, int n, ExamStatus s) {
      final color = examStatusColor(context, s);
      return Expanded(
        child: GlassCard(
          color: color.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Column(
              children: [
                Icon(examStatusIcon(s), color: color),
                const SizedBox(height: 4),
                Text(
                  '$n',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(color: color),
                ),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Card della stessa altezza anche quando un'etichetta va a capo.
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            tile('Superati', passed, ExamStatus.passed),
            tile('Non superati', failed, ExamStatus.failed),
            tile('In attesa', awaiting, ExamStatus.taken),
            tile('Annullati', cancelled, ExamStatus.cancelled),
          ],
        ),
      ),
    );
  }
}

class _CourseGroupCard extends StatelessWidget {
  const _CourseGroupCard({
    required this.group,
    required this.midtermAvg,
    required this.data,
    required this.selectedId,
    required this.onSelect,
  });

  final CourseExamGroup group;
  final double? midtermAvg;
  final ExamsData data;
  final int? selectedId;
  final ValueChanged<Exam> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final course = group.course;
    // l'alone (bordo e intestazione) segue lo stato della prova, non
    // l'ateneo: superato verde, non superato rosso, in attesa viola…
    final headline = group.headlineStatus;
    final color = headline == null
        ? theme.colorScheme.outline
        : examStatusColor(context, headline);
    final passed = group.passedFinal;
    return GlassCard(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: color.withValues(alpha: 0.08),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                // solo il nome dell'insegnamento: niente pallino né sigla
                // dell'ateneo
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(group.name, style: theme.textTheme.titleMedium),
                      Text(
                        [
                          formatCfu(course?.cfu),
                          if (midtermAvg != null)
                            'Media prove in itinere: ${formatNumber(midtermAvg, decimals: 2)}',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (passed != null)
                  SmallBadge(
                    label: 'Voto finale ${gradeLabel(passed) ?? '—'}',
                    color: Colors.green.shade700,
                    icon: Icons.verified,
                  ),
              ],
            ),
          ),
          for (final e in group.finals)
            ExamTile(
              exam: e,
              course: course,
              showCourse: false,
              selected: e.id == selectedId,
              onTap: () => onSelect(e),
            ),
          if (group.midterms.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Prove in itinere e esoneri (${group.midterms.length})',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ),
            for (final e in group.midterms)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: ExamTile(
                  exam: e,
                  course: course,
                  showCourse: false,
                  dense: true,
                  selected: e.id == selectedId,
                  onTap: () => onSelect(e),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Filtro a icona degli esiti: si possono scegliere più esiti insieme; con
/// almeno uno scelto l'icona è piena e mostra quanti.
class OutcomeFilterButton extends StatelessWidget {
  const OutcomeFilterButton({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final Set<OutcomeFilter> selected;
  final void Function(OutcomeFilter outcome, bool on) onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = selected.isNotEmpty;
    return MenuAnchor(
      menuChildren: [
        for (final o in OutcomeFilter.values)
          CheckboxMenuButton(
            key: ValueKey('outcome-${o.name}'),
            value: selected.contains(o),
            // il menù resta aperto: si possono spuntare più esiti
            closeOnActivate: false,
            onChanged: (v) => onChanged(o, v ?? false),
            trailingIcon: Icon(o.icon, size: 18),
            child: Text(o.label),
          ),
      ],
      builder: (context, controller, _) => Badge(
        isLabelVisible: active,
        label: Text('${selected.length}'),
        child: IconButton(
          key: const Key('outcome-filter'),
          tooltip: active
              ? 'Esiti: ${[for (final o in OutcomeFilter.values)
                  if (selected.contains(o)) o.label].join(', ')}'
              : 'Filtra per esito',
          isSelected: active,
          style: active
              ? IconButton.styleFrom(
                  backgroundColor: scheme.secondaryContainer,
                  foregroundColor: scheme.onSecondaryContainer,
                )
              : null,
          icon: const Icon(Icons.filter_list),
          selectedIcon: const Icon(Icons.filter_alt),
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
      ),
    );
  }
}
