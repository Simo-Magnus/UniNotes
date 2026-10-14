import 'package:flutter/material.dart';

import '../../../core/constants/enums.dart';
import '../../../core/router/app_shell.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../models/exam.dart';
import '../../exams/exam_detail.dart';
import '../../../utils/dates.dart';
import '../../../widgets/study_material_tile.dart';
import '../dashboard_data.dart';
import 'dashboard_card.dart';

/// Prossime prove (esami, prove in itinere, esoneri) con lo stato
/// semplificato («Da prenotare», «Prenotato»), il conto alla rovescia e i
/// materiali da studiare. Toccando una prova si apre il suo dettaglio.
class UpcomingExamsCard extends StatelessWidget {
  const UpcomingExamsCard({super.key, required this.data});

  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    final exams = data.exams;
    return DashboardCard(
      icon: Icons.assignment_outlined,
      title: 'Prossime prove',
      actionLabel: 'Esami',
      onAction: () => AppShell.goTo(context, 'Esami'),
      child: exams.isEmpty
          ? const CardEmptyMessage(
              icon: Icons.celebration_outlined,
              message:
                  'Nessun esame in programma. Aggiungili dalla sezione Esami.',
            )
          : Column(
              children: [
                for (var i = 0; i < exams.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  _ExamItem(exam: exams[i], data: data),
                ],
              ],
            ),
    );
  }
}

class _ExamItem extends StatelessWidget {
  const _ExamItem({required this.exam, required this.data});

  final Exam exam;
  final DashboardData data;

  static const int _maxMaterials = 3;

  @override
  Widget build(BuildContext context) {
    final x = exam;
    final theme = Theme.of(context);
    final t = context.tokens;
    final course = data.courseOf(x.courseId);
    final midterm = x.kind == ExamKind.midterm;
    // colore del tipo di prova (non dell'ateneo): esame viola, prova in
    // itinere azzurra
    final color = midterm ? t.cyanSoft : t.tintExams;
    final when = x.dateTime;
    final days = when == null ? null : daysBetween(data.now, when);
    final urgent = days != null && days <= 7;
    final booked = x.status == ExamStatus.booked;

    return InkWell(
      onTap: x.id == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ExamDetailScreen(examId: x.id!),
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: entryTint(context, color),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: color, width: 2),
                  ),
                  child: Icon(
                    midterm ? Icons.quiz : Icons.assignment,
                    color: color,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        x.title ?? course?.name ?? x.kind.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        [
                          x.kind.label,
                          if (course != null && x.title != null) course.name,
                          if (x.examType != null) x.examType!,
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      _StatusChip(
                        label: x.status.label,
                        icon: booked
                            ? Icons.event_available_outlined
                            : Icons.edit_calendar_outlined,
                        color: booked ? t.cyanSoft : t.textMuted,
                      ),
                      if (when != null)
                        Text(
                          capitalize(formatShortWeekdayDmy(when)) +
                              (x.time != null ? ' ${formatTime(when)}' : '') +
                              (x.location != null ? ' · ${x.location}' : ''),
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (when != null)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: urgent
                          ? theme.colorScheme.errorContainer
                          : theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Text(
                          days! <= 0 ? 'Oggi' : '$days',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: urgent
                                ? theme.colorScheme.onErrorContainer
                                : theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                        if (days > 0)
                          Text(
                            days == 1 ? 'giorno' : 'giorni',
                            style: theme.textTheme.labelSmall,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            if (x.studyMaterials.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Materiali da studiare',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              for (final m in x.studyMaterials.take(_maxMaterials))
                StudyMaterialTile(m),
              if (x.studyMaterials.length > _maxMaterials)
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(
                    '… e altri ${x.studyMaterials.length - _maxMaterials}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ] else if (x.topics != null) ...[
              const SizedBox(height: 6),
              Text(
                'Argomenti: ${x.topics}',
                style: theme.textTheme.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Stato della prova (da prenotare / prenotato) come piccola etichetta.
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.icon,
    required this.color,
  });
  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
