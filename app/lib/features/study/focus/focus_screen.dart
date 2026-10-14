import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/feedback/motion.dart';
import '../../../core/services/app_services.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../models/study.dart';
import '../../../widgets/common.dart';
import '../../../widgets/glass.dart';
import '../study_stats.dart';
import 'focus_goal.dart';
import 'focus_plan.dart';
import 'focus_service.dart';
import 'focus_system.dart';
import 'focus_timer.dart';

/// Apre la schermata della sessione in corso.
Future<void> openFocusScreen(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const FocusScreen()));

enum FocusCloseChoice { save, discard, cancel }

/// «Terminare la sessione?»: il tempo fatto si salva (o si scarta). Due
/// sole scelte; toccando fuori (o Indietro) la sessione continua.
Future<FocusCloseChoice> askFinishFocus(BuildContext context) async {
  final r = await showDialog<FocusCloseChoice>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Terminare la sessione?'),
      content: const Text(
        'Il tempo di concentrazione fatto finora si salva nelle sessioni di '
        'studio. Tocca fuori per continuare.',
      ),
      actions: [
        TextButton(
          key: const Key('focus-discard'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(c).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(c, FocusCloseChoice.discard),
          child: const Text('Scarta'),
        ),
        FilledButton(
          key: const Key('focus-finish'),
          onPressed: () => Navigator.pop(c, FocusCloseChoice.save),
          child: const Text('Termina e salva'),
        ),
      ],
    ),
  );
  return r ?? FocusCloseChoice.cancel;
}

/// Termina la sessione dopo la domanda; true se è stata fermata.
Future<bool> finishFocusAsking(BuildContext context, FocusService f) async {
  final choice = await askFinishFocus(context);
  switch (choice) {
    case FocusCloseChoice.save:
      await f.finish();
      return true;
    case FocusCloseChoice.discard:
      await f.discard();
      return true;
    case FocusCloseChoice.cancel:
      return false;
  }
}

/// Sessione Focus a tutto schermo: anello grande con il tempo del tratto
/// in corso, tratti della sessione, pausa, «Salta pausa» e «Termina». Alla
/// fine il riepilogo con l'obiettivo del giorno.
class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  late final FocusService _f = context.read<AppServices>().focus;

  @override
  void initState() {
    super.initState();
    _f.screenVisible = true;
  }

  @override
  void dispose() {
    _f.screenVisible = false;
    super.dispose();
  }

  Future<void> _finish() async {
    final stopped = await finishFocusAsking(context, _f);
    // scartata: niente riepilogo, si torna indietro
    if (stopped && mounted && _f.completed.value == null) {
      await Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_f, _f.completed]),
      builder: (context, _) {
        final active = _f.active;
        final done = _f.completed.value;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              active ? (_f.current.label ?? 'Sessione Focus') : 'Focus',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: SafeArea(
            child: active
                ? _Running(focus: _f, onFinish: _finish)
                : done != null
                ? _Completed(result: done, focus: _f)
                : const Center(child: Text('Nessuna sessione in corso.')),
          ),
        );
      },
    );
  }
}

class _Running extends StatelessWidget {
  const _Running({required this.focus, required this.onFinish});
  final FocusService focus;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final timer = focus.timer;
    final p = timer.position;
    final rest = p.phase == FocusPhase.rest;
    final paused = timer.paused;
    final hm = DateFormat.Hm('it_IT');
    final segmentEnd = timer.now.add(p.segmentRemaining);
    final caption = paused
        ? 'In pausa · ${formatFocusLength(p.totalRemaining.inMinutes)} rimasti'
        : rest
        ? 'Si riparte alle ${hm.format(segmentEnd)}'
        : p.breaksLeft == 0
        ? 'Fine alle ${hm.format(segmentEnd)}'
        : 'Pausa alle ${hm.format(segmentEnd)}';
    final hint = focusSystemHint(
      focus.system.kind,
      windowsFailed: focus.windowsFailed,
      quiet: focus.systemQuiet,
    );
    final breaksLeft = switch (p.breaksLeft) {
      0 => 'nessuna pausa rimasta',
      1 => '1 pausa rimasta',
      final n => '$n pause rimaste',
    };
    return LayoutBuilder(
      builder: (context, c) {
        final ring = math.min(c.maxWidth - 48, 320.0).clamp(180.0, 320.0);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  FocusRing(
                    size: ring,
                    value: p.segmentProgress,
                    rest: rest,
                    label: rest ? 'Pausa' : 'Concentrazione',
                    time: formatCountdown(p.segmentRemaining),
                    caption: caption,
                    dimmed: paused,
                  ),
                  const SizedBox(height: 20),
                  _PlanStrip(plan: timer.plan, position: p),
                  const SizedBox(height: 8),
                  Text(
                    '${formatMinutes(p.focusDone.inMinutes)} di '
                    'concentrazione · $breaksLeft',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      // una sola azione arancione: Riprendi o Salta pausa
                      if (paused)
                        Pressable(
                          child: FilledButton.icon(
                            onPressed: () {
                              AppFeedback.of(context).tap();
                              focus.resume();
                            },
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Riprendi'),
                          ),
                        )
                      else ...[
                        if (rest)
                          Pressable(
                            child: FilledButton.icon(
                              key: const Key('focus-skip-break'),
                              onPressed: focus.skipBreak,
                              icon: const Icon(Icons.skip_next_rounded),
                              label: const Text('Salta pausa'),
                            ),
                          ),
                        Pressable(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              AppFeedback.of(context).tap();
                              focus.pause();
                            },
                            icon: const Icon(Icons.pause_rounded),
                            label: const Text('Pausa'),
                          ),
                        ),
                      ],
                      TextButton.icon(
                        key: const Key('focus-stop'),
                        onPressed: onFinish,
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('Termina'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _QuietInfo(focus: focus, hint: hint, color: t.textMuted),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Riga sul silenzio: avvisi dell'app in attesa, sistema silenziato o come
/// silenziarlo.
class _QuietInfo extends StatelessWidget {
  const _QuietInfo({
    required this.focus,
    required this.hint,
    required this.color,
  });
  final FocusService focus;
  final String? hint;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: color);
    final lines = <String?>[
      'Gli avvisi non urgenti di UniNotes arrivano a fine sessione.',
      if (focus.systemQuiet)
        switch (focus.system.kind) {
          FocusSystemKind.windowsFocus =>
            'Sessione di concentrazione di Windows attiva: notifiche delle '
                'altre app ferme.',
          FocusSystemKind.androidDnd =>
            'Non disturbare del telefono attivo fino alla fine: passano solo '
                'sveglie e chiamate importanti.',
          _ => null,
        },
      ?hint,
    ];
    return Column(
      children: [
        for (final l in lines.nonNulls)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.do_not_disturb_on_outlined, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(child: Text(l, style: style)),
              ],
            ),
          ),
        if (focus.windowsFailed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: focus.system.openWindowsNotificationSettings,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Apri le impostazioni delle notifiche'),
            ),
          ),
      ],
    );
  }
}

/// Tratti della sessione: barre per la concentrazione, puntini per le
/// pause; quelli fatti pieni, quello in corso a metà.
class _PlanStrip extends StatelessWidget {
  const _PlanStrip({required this.plan, required this.position});
  final List<FocusSegment> plan;
  final FocusPosition position;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final total = planLength(plan).inSeconds.clamp(1, 1 << 30);
    return Semantics(
      label:
          'Tratto ${math.min(position.index + 1, plan.length)} di '
          '${plan.length}',
      excludeSemantics: true,
      child: SizedBox(
        height: 10,
        child: LayoutBuilder(
          builder: (context, c) {
            final gap = 4.0;
            final usable = c.maxWidth - gap * (plan.length - 1);
            return Row(
              children: [
                for (var i = 0; i < plan.length; i++) ...[
                  if (i > 0) SizedBox(width: gap),
                  SizedBox(
                    width: math.max(
                      plan[i].phase == FocusPhase.rest ? 10.0 : 16.0,
                      usable * plan[i].length.inSeconds / total,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: LinearProgressIndicator(
                        minHeight: 10,
                        value: i < position.index
                            ? 1
                            : (i == position.index
                                  ? position.segmentProgress
                                  : 0),
                        color: plan[i].phase == FocusPhase.rest
                            ? t.cyanSoft.withValues(alpha: 0.7)
                            : t.cyan,
                        backgroundColor: t.textPrimary.withValues(alpha: 0.09),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Timer grande: anello di Design 3 (§7.2) in scala, tempo al centro.
/// Azzurro: il tempo lo conta la macchina; in pausa l'anello si attenua.
class FocusRing extends StatelessWidget {
  const FocusRing({
    super.key,
    required this.size,
    required this.value,
    required this.label,
    required this.time,
    required this.caption,
    this.rest = false,
    this.dimmed = false,
  });

  final double size;
  final double value;
  final String label;
  final String time;
  final String caption;
  final bool rest;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    final colors = rest
        ? [t.cyanSoft, const Color(0xFFBAE6FD)]
        : [const Color(0xFF0EA5E9), t.cyanBright];
    return Semantics(
      label: '$label, $time rimasti. $caption',
      liveRegion: false,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0.0, 1.0)),
          duration: motion(context, const Duration(milliseconds: 900)),
          builder: (context, v, child) => CustomPaint(
            painter: RingPainter(
              value: v,
              track: t.textPrimary.withValues(alpha: 0.09),
              colors: dimmed
                  ? [for (final c in colors) c.withValues(alpha: 0.45)]
                  : colors,
            ),
            child: child,
          ),
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(size * 0.16),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label.toUpperCase(),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: rest ? t.cyanSoft : t.textSecondary,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      time,
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w300,
                        color: dimmed ? t.textMuted : t.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      caption,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: t.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Riepilogo a sessione finita: minuti, obiettivo del giorno, serie.
class _Completed extends StatelessWidget {
  const _Completed({required this.result, required this.focus});
  final FocusResult result;
  final FocusService focus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            children: [
              const AnimatedCheck(size: 64),
              const SizedBox(height: 12),
              Text(
                result.completed ? 'Sessione completata' : 'Sessione terminata',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              AnimatedCount(
                value: result.focusMinutes,
                format: (v) => '${formatMinutes(v)} di concentrazione',
                style: theme.textTheme.titleMedium,
              ),
              if (result.focusMinutes < 1)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Meno di un minuto: la sessione non è stata salvata.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 24),
              const DailyGoalCard(margin: EdgeInsets.zero),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  Pressable(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Fatto'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Obiettivo giornaliero: anello con i minuti di oggi, serie di giorni.
/// Contano tutte le sessioni di studio (Focus, cronometro, a mano).
class DailyGoalCard extends StatelessWidget {
  const DailyGoalCard({super.key, this.margin, this.onEditGoal});
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onEditGoal;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return ListenableBuilder(
      listenable: s.focus,
      builder: (context, _) => FocusStatsBuilder(
        builder: (context, stats) => GlassCard(
          margin: margin,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CardHeader(
                  title: 'Obiettivo di oggi',
                  icon: Icons.flag_outlined,
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
                  trailing: onEditGoal == null
                      ? null
                      : TextButton(
                          onPressed: onEditGoal,
                          child: const Text('Cambia'),
                        ),
                ),
                Row(
                  children: [
                    ProgressRing(
                      // l'anello cresce con i caratteri grandi
                      size: MediaQuery.textScalerOf(
                        context,
                      ).scale(94).clamp(94.0, 160.0),
                      value: stats.progress,
                      label: '${(stats.progress * 100).round()}%',
                      caption: formatMinutes(stats.goal),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnimatedCount(
                            value: stats.today,
                            format: (v) => '${formatMinutes(v)} oggi',
                            semanticsLabel: 'Studio di oggi',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            stats.caption,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(
                                Icons.local_fire_department_outlined,
                                size: 18,
                                color: context.tokens.cyanSoft,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  stats.streak == 0
                                      ? 'Nessuna serie in corso'
                                      : 'Serie: ${stats.streakText}',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                          if (stats.best > stats.streak)
                            Text(
                              'Record: ${stats.bestText}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Carica le sessioni e calcola obiettivo e serie (si aggiorna a ogni
/// modifica dei dati).
class FocusStatsBuilder extends StatelessWidget {
  const FocusStatsBuilder({super.key, required this.builder});
  final Widget Function(BuildContext context, FocusStats stats) builder;

  @override
  Widget build(BuildContext context) {
    final goal = context.read<AppServices>().focus.dailyGoal;
    return RevisionBuilder<List<StudySession>>(
      deps: [goal],
      // poco più di un anno: basta per la serie e il record
      load: (s) => s.study.sessions(
        from: dayStart(DateTime.now()).subtract(const Duration(days: 400)),
      ),
      builder: (context, sessions) => builder(
        context,
        FocusStats.of(sessions, goal: goal, today: DateTime.now()),
      ),
    );
  }
}
