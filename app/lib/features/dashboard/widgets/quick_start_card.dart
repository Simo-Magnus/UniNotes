import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/feedback/motion.dart';
import '../../../core/router/app_shell.dart';
import '../../../core/services/app_services.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../widgets/glass.dart';
import '../../notes/notes_screen.dart' show openRecorder;
import '../../study/focus/focus_cards.dart' show editDailyGoal;
import '../../study/focus/focus_screen.dart'
    show FocusStatsBuilder, openFocusScreen;
import '../../study/study_screen.dart';
import '../../study/study_timer.dart';
import '../dashboard_data.dart';

/// «Inizia»: quanto si è studiato oggi e le due cose che si fanno ogni
/// giorno, a un tocco dalla Home.
/// - Oggi: anello con l'avanzamento verso l'obiettivo giornaliero, minuti di
///   studio di oggi (tutte le sessioni salvate: cronometro, timer e
///   aggiunte a mano), quanto manca e la serie; toccandolo si cambia
///   l'obiettivo giornaliero;
/// - Sessione Studio: cronometro o timer (Studio → Sessioni Studio); con una
///   sessione in corso mostra il tempo e la riapre;
/// - Registra lezione: registrazione con la trascrizione istantanea; con
///   una registrazione in corso la riporta in primo piano.
/// Su schermi larghi i tre riquadri stanno su una riga, altrimenti uno
/// sotto l'altro.
class QuickStartCard extends StatelessWidget {
  const QuickStartCard({super.key, required this.data});

  final DashboardData data;

  void _openSessions(BuildContext context) {
    final s = context.read<AppServices>();
    if (s.focus.active) {
      openFocusScreen(context);
      return;
    }
    StudyScreen.initialTab = StudyScreen.focusTab;
    AppShell.goTo(context, 'Studio');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final t = context.tokens;
    final sw = StudyTimer.instance;
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardHeader(
              title: 'Inizia',
              icon: Icons.bolt_outlined,
              padding: const EdgeInsets.fromLTRB(4, 8, 0, 4),
            ),
            ListenableBuilder(
              listenable: Listenable.merge([s.focus, s.recorder, sw]),
              builder: (context, _) {
                final studying = s.focus.active || sw.isActive;
                final recording = s.recorder.active;
                final tiles = [
                  const _TodayTile(key: Key('home-today')),
                  _QuickTile(
                    key: const Key('home-study'),
                    icon: Icons.timer_outlined,
                    color: t.tintStudy,
                    title: 'Sessione Studio',
                    detail: s.focus.active
                        ? 'Timer in corso'
                        : (sw.isActive
                              ? 'Cronometro in corso'
                              : 'Cronometro o timer'),
                    live: studying,
                    onTap: () => _openSessions(context),
                  ),
                  _QuickTile(
                    key: const Key('home-record'),
                    icon: Icons.mic_none_outlined,
                    color: t.tintNotes,
                    title: 'Registra lezione',
                    detail: recording
                        ? 'Registrazione in corso'
                        : 'Con la trascrizione istantanea',
                    live: recording,
                    onTap: () => openRecorder(context),
                  ),
                ];
                return LayoutBuilder(
                  builder: (context, c) {
                    // tre colonne se c'è spazio (anche con i caratteri
                    // grandi), altrimenti uno sotto l'altro
                    final wide =
                        c.maxWidth >=
                        MediaQuery.textScalerOf(context).scale(170) * 3;
                    if (!wide) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, w) in tiles.indexed) ...[
                            if (i > 0) const SizedBox(height: 8),
                            w,
                          ],
                        ],
                      );
                    }
                    return IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, w) in tiles.indexed) ...[
                            if (i > 0) const SizedBox(width: 8),
                            Expanded(child: w),
                          ],
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Studio di oggi: anello verso l'obiettivo giornaliero, minuti di oggi,
/// quanto manca e la serie di giorni con l'obiettivo raggiunto. I minuti
/// vengono dalle sessioni salvate ([FocusStatsBuilder]) e si aggiornano a
/// ogni sessione salvata o cambio dell'obiettivo: nessun dato stimato.
class _TodayTile extends StatelessWidget {
  const _TodayTile({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    return GlassCard(
      inner: true,
      margin: EdgeInsets.zero,
      child: FocusStatsBuilder(
        builder: (context, stats) {
          final goal = formatMinutes(stats.goal);
          final reached = stats.today >= stats.goal;
          return Semantics(
            button: true,
            label:
                'Studio di oggi: ${formatMinutes(stats.today)}. '
                'Obiettivo $goal. ${stats.caption}',
            hint: "Tocca per cambiare l'obiettivo giornaliero",
            excludeSemantics: true,
            onTap: () => _editGoal(context),
            child: InkWell(
              key: const Key('home-goal-edit'),
              onTap: () => _editGoal(context),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
                child: Row(
                  children: [
                    // l'anello cresce con i caratteri grandi; la percentuale
                    // dentro cresce fino a 1,3× (il valore intero è nel testo
                    // accanto e nella semantica)
                    MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.3,
                      child: ProgressRing(
                        size: MediaQuery.textScalerOf(context)
                            .scale(56)
                            .clamp(56.0, 96.0),
                        value: stats.progress,
                        label: '${(stats.progress * 100).round()}%',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedCount(
                            value: stats.today,
                            format: (v) => 'Oggi ${formatMinutes(v)}',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: t.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            reached
                                ? '${stats.caption} ($goal)'
                                : '${stats.caption} · obiettivo $goal',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: reached ? t.cyanSoft : t.textMuted,
                            ),
                          ),
                          if (stats.streak > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.local_fire_department_outlined,
                                    size: 14,
                                    color: t.cyanSoft,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      'Serie: ${stats.streakText}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(color: t.textMuted),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    // si tocca per cambiare l'obiettivo (prima «Obiettivo»)
                    Icon(Icons.edit_outlined, size: 18, color: t.textMuted),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _editGoal(BuildContext context) {
    AppFeedback.of(context).tap();
    editDailyGoal(context);
  }
}

/// Riquadro interno toccabile: icona dell'area in un disco, titolo e una
/// riga di dettaglio. [live]: attività in corso (punto azzurro pulsante).
class _QuickTile extends StatelessWidget {
  const _QuickTile({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
    required this.onTap,
    this.live = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String detail;
  final VoidCallback onTap;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '$title. $detail',
      excludeSemantics: true,
      child: GlassCard(
        inner: true,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: () {
            AppFeedback.of(context).tap();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.16),
                    border: Border.all(color: color.withValues(alpha: 0.45)),
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: t.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (live) ...[
                            Icon(
                              Icons.fiber_manual_record,
                              size: 10,
                              color: t.cyanBright,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              detail,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: live ? t.cyanSoft : t.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
