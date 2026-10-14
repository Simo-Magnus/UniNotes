import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/router/app_shell.dart';
import '../../../core/services/app_services.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../widgets/glass.dart';
import '../../notes/ai_request_dialog.dart' show openReferenceAi;
import '../../notes/notes_screen.dart' show openRecorder;
import '../../study/focus/focus_screen.dart' show openFocusScreen;
import '../../study/study_screen.dart';
import '../../study/study_timer.dart';
import '../dashboard_data.dart';

/// «Inizia»: le tre cose che si fanno ogni giorno, a un tocco dalla Home.
/// - Sessione Studio: cronometro o timer (Studio → Sessioni Studio); con una
///   sessione in corso mostra il tempo e la riapre;
/// - Registra lezione: registrazione con la trascrizione istantanea; con
///   una registrazione in corso la riporta in primo piano;
/// - la propria AI di riferimento (ChatGPT, Claude…), aperta con l'account
///   dello studente.
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
            const CardHeader(
              title: 'Inizia',
              icon: Icons.bolt_outlined,
              padding: EdgeInsets.fromLTRB(4, 14, 0, 8),
            ),
            ListenableBuilder(
              listenable: Listenable.merge([s.focus, s.recorder, sw]),
              builder: (context, _) {
                final studying = s.focus.active || sw.isActive;
                final recording = s.recorder.active;
                final tiles = [
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
                  _QuickTile(
                    key: const Key('home-ai'),
                    icon: Icons.psychology_alt_outlined,
                    color: t.cyanSoft,
                    title: 'Apri ${data.ai.label}',
                    detail: 'La tua AI di riferimento',
                    onTap: () => openReferenceAi(context, data.ai),
                  ),
                ];
                return LayoutBuilder(
                  builder: (context, c) {
                    // tre colonne se c'è spazio (anche con i caratteri
                    // grandi), altrimenti una sotto l'altra
                    final wide =
                        c.maxWidth >=
                        MediaQuery.textScalerOf(context).scale(150) * 3;
                    if (!wide) {
                      return Column(
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
