import 'package:flutter/material.dart';

import '../../../core/router/app_shell.dart';
import '../../../core/theme/app_tokens.dart';
import '../dashboard_data.dart';
import 'dashboard_card.dart';

/// Moduli e argomenti: avanzamento di ogni insegnamento in corso (media
/// degli stati degli argomenti dei moduli, anche quelli dal database) e
/// argomenti da ripassare. Barra azzurra: valore calcolato dall'app.
class CourseProgressCard extends StatelessWidget {
  const CourseProgressCard({super.key, required this.data});

  final DashboardData data;

  static const int _maxCourses = 8;

  @override
  Widget build(BuildContext context) {
    final items = data.progress;
    final theme = Theme.of(context);
    final t = context.tokens;
    return DashboardCard(
      icon: Icons.account_tree_outlined,
      title: 'Moduli e argomenti',
      actionLabel: 'Studio',
      onAction: () => AppShell.goTo(context, 'Studio'),
      child: items.isEmpty
          ? const CardEmptyMessage(
              icon: Icons.checklist_outlined,
              message:
                  'Aggiungi moduli e argomenti ai corsi nella sezione Studio per '
                  'vedere qui il progresso.',
            )
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Column(
                children: [
                  for (final p in items.take(_maxCourses))
                    Padding(
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
                              backgroundColor: t.textPrimary.withValues(
                                alpha: 0.09,
                              ),
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
                    ),
                ],
              ),
            ),
    );
  }
}
