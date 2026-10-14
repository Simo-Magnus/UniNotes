import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/feedback/motion.dart';
import '../../../core/services/app_services.dart';
import '../../../models/study.dart';
import '../../../widgets/common.dart';
import '../../../widgets/glass.dart';
import '../study_stats.dart';
import 'focus_goal.dart';
import 'focus_plan.dart';
import 'focus_screen.dart';

/// Cambia l'obiettivo giornaliero: cursore da 30 minuti a 4 ore, Annulla e
/// Salva.
Future<void> editDailyGoal(BuildContext context) async {
  final f = context.read<AppServices>().focus;
  var value = f.dailyGoal.toDouble().clamp(
    kDailyGoalChoices.first.toDouble(),
    kDailyGoalChoices.last.toDouble(),
  );
  final v = await showDialog<int>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setLocal) => AlertDialog(
        title: const Text('Obiettivo giornaliero'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatMinutes(value.round()),
              style: Theme.of(c).textTheme.headlineMedium,
            ),
            Slider(
              value: value,
              min: kDailyGoalChoices.first.toDouble(),
              max: kDailyGoalChoices.last.toDouble(),
              divisions:
                  (kDailyGoalChoices.last - kDailyGoalChoices.first) ~/ 15,
              label: formatMinutes(value.round()),
              onChanged: (x) => setLocal(() => value = x),
            ),
            Text(
              'Contano tutte le sessioni di studio del giorno.',
              style: Theme.of(c).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, value.round()),
            child: const Text('Salva'),
          ),
        ],
      ),
    ),
  );
  if (v == null) return;
  await f.setDailyGoal(v);
  if (context.mounted) context.read<AppServices>().revision.bump();
}

/// Sessione Focus in corso: anello piccolo e «Apri la sessione».
class FocusRunningPanel extends StatelessWidget {
  const FocusRunningPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final focus = context.read<AppServices>().focus;
    return ListenableBuilder(
      listenable: focus.timer,
      builder: (context, _) {
        final p = focus.timer.position;
        final rest = p.phase == FocusPhase.rest;
        return Column(
          children: [
            FocusRing(
              size: 180,
              value: p.segmentProgress,
              rest: rest,
              dimmed: focus.timer.paused,
              label: rest ? 'Pausa' : 'Concentrazione',
              time: formatCountdown(p.segmentRemaining),
              caption: focus.current.label ?? 'Studio',
            ),
            const SizedBox(height: 16),
            Pressable(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () {
                  AppFeedback.of(context).tap();
                  openFocusScreen(context);
                },
                icon: const Icon(Icons.open_in_full_rounded),
                label: const Text('Apri la sessione'),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// «Focus questa settimana»: minuti di concentrazione e sessioni Focus
/// della settimana.
class FocusWeekCard extends StatelessWidget {
  const FocusWeekCard({super.key});

  @override
  Widget build(BuildContext context) {
    return RevisionBuilder<List<StudySession>>(
      load: (s) async => [
        for (final x in await s.study.sessions(from: weekStart(DateTime.now())))
          if (x.focus) x,
      ],
      builder: (context, week) {
        final theme = Theme.of(context);
        return GlassCard(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const CardHeader(
                  title: 'Focus questa settimana',
                  icon: Icons.insights_outlined,
                  padding: EdgeInsets.fromLTRB(0, 12, 0, 8),
                ),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    _Figure(
                      label: 'Concentrazione',
                      value: totalMinutes(week),
                      format: formatMinutes,
                    ),
                    _Figure(
                      label: 'Sessioni',
                      value: week.length,
                      format: (v) => '$v',
                    ),
                  ],
                ),
                if (week.isEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Le sessioni con il timer compariranno qui e nelle '
                    'statistiche di Studio.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    required this.format,
  });
  final String label;
  final int value;
  final String Function(int v) format;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
        AnimatedCount(
          value: value,
          format: format,
          semanticsLabel: label,
          style: theme.textTheme.titleLarge,
        ),
      ],
    );
  }
}
