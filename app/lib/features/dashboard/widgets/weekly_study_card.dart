import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/router/app_shell.dart';
import '../../../utils/dates.dart';
import '../dashboard_data.dart';
import 'dashboard_card.dart';

/// Ore di studio della settimana corrente, con barre per giorno.
class WeeklyStudyCard extends StatelessWidget {
  const WeeklyStudyCard({super.key, required this.data});

  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perDay = data.minutesPerWeekday;
    final total = data.weekMinutes;
    final maxMinutes = math.max(60, perDay.reduce(math.max));
    final todayIndex = data.now.weekday - 1;
    final wd = DateFormat('EEEEE');

    return DashboardCard(
      icon: Icons.timer_outlined,
      title: 'Studio della settimana',
      section: 'Studio',
      onTap: () => AppShell.goTo(context, 'Studio'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatMinutes(total),
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      Text(
                        total == 0
                            ? 'Nessuna sessione registrata questa settimana'
                            : '${data.weekSessions.length} '
                                  '${data.weekSessions.length == 1 ? 'sessione' : 'sessioni'} questa settimana',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 96,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Tooltip(
                        message: formatMinutes(perDay[i]),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: FractionallySizedBox(
                                  heightFactor: math.max(
                                    0.04,
                                    perDay[i] / maxMinutes,
                                  ),
                                  widthFactor: 0.55,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: i == todayIndex
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.primary
                                                .withValues(
                                                  alpha: perDay[i] == 0
                                                      ? 0.12
                                                      : 0.45,
                                                ),
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(4),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              capitalize(wd.format(addDays(data.weekStart, i))),
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: i == todayIndex
                                    ? FontWeight.bold
                                    : null,
                              ),
                            ),
                          ],
                        ),
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
