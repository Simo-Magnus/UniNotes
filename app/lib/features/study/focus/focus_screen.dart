import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/feedback/motion.dart';
import '../../../core/services/app_services.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../models/attachment.dart';
import '../../../models/course.dart';
import '../../../models/study.dart';
import '../../../widgets/common.dart';
import '../../../widgets/glass.dart';
import '../attachments.dart' show openAttachment;
import '../study_stats.dart';
import 'focus_context.dart';
import 'focus_goal.dart';
import 'focus_plan.dart';
import 'focus_service.dart';
import 'focus_system.dart';
import 'focus_timer.dart';

/// Apre la schermata della sessione in corso. Se è già aperta sotto un
/// file aperto da lì (riquadro della sessione sopra il lettore) si torna a
/// quella, senza aprirne una seconda.
Future<void> openFocusScreen(BuildContext context) async {
  final open = FocusScreen.openRoute;
  if (open != null && open.isActive && open.navigator != null) {
    open.navigator!.popUntil((r) => r == open);
    return;
  }
  await Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const FocusScreen()));
}

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

/// Sessione Focus a tutto schermo. In alto che cosa si studia
/// (insegnamento, modulo, argomento, attività), al centro il protagonista:
/// l'anello grande con il tempo del tratto in corso, i tratti della
/// sessione, pausa, «Salta pausa» e «Termina»; poi i file del modulo, da
/// aprire con un tocco senza fermare il timer (su schermi larghi in un
/// pannello a destra). Alla fine il riepilogo con l'obiettivo del giorno.
class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  /// Pagina della schermata aperta (null = chiusa): vedi [openFocusScreen].
  static ModalRoute<Object?>? openRoute;

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  late final AppServices _s = context.read<AppServices>();
  late final FocusService _f = _s.focus;

  /// Insegnamento, modulo, argomento e file della sessione (null mentre si
  /// carica).
  FocusContext? _ctx;
  Object? _ctxKey;
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    _f.screenVisible = true;
    _s.revision.addListener(_reloadContext);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    FocusScreen.openRoute = _route;
  }

  @override
  void dispose() {
    _s.revision.removeListener(_reloadContext);
    if (FocusScreen.openRoute == _route) FocusScreen.openRoute = null;
    _f.screenVisible = false;
    super.dispose();
  }

  /// Ricarica nomi e file se cambia il collegamento della sessione.
  void _syncContext() {
    final l = _f.current;
    final key = (l.courseId, l.moduleId, l.topicId);
    if (key == _ctxKey) return;
    _ctxKey = key;
    _reloadContext();
  }

  Future<void> _reloadContext() async {
    final key = _ctxKey;
    final FocusContext ctx;
    try {
      ctx = await FocusContext.load(_s, _f.current);
    } catch (_) {
      return; // dati non leggibili (es. app in chiusura): resta l'ultimo
    }
    if (mounted && key == _ctxKey) setState(() => _ctx = ctx);
  }

  /// Apre un file della sessione: la sessione continua e, finché il file è
  /// aperto, il riquadro della sessione resta sopra il lettore (tocco =
  /// ritorno qui). «Non disturbare» non cambia.
  Future<void> _openFile(Course course, Attachment a) async {
    AppFeedback.of(context).tap();
    _f.screenVisible = false;
    try {
      await openAttachment(context, course, a);
    } finally {
      if (mounted) _f.screenVisible = true;
    }
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
        if (active) _syncContext();
        final ctx = _ctx;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              active ? 'Sessione Focus' : 'Focus',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: SafeArea(
            child: active
                ? _Running(
                    focus: _f,
                    onFinish: _finish,
                    header: FocusContextHeader(ctx: ctx, link: _f.current),
                    files: ctx?.course == null
                        ? null
                        : FocusFilesPanel(ctx: ctx!, onOpen: _openFile),
                  )
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
  const _Running({
    required this.focus,
    required this.onFinish,
    required this.header,
    required this.files,
  });
  final FocusService focus;
  final VoidCallback onFinish;

  /// Che cosa si studia (sopra l'anello).
  final Widget header;

  /// Pannello dei file (null senza insegnamento).
  final Widget? files;

  /// Da questa larghezza i file stanno in un pannello a destra del timer.
  static const double sidePanelFrom = 900;
  static const double sidePanelWidth = 400;

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
      failure: focus.quietFailure,
      quiet: focus.systemQuiet,
    );
    final breaksLeft = switch (p.breaksLeft) {
      0 => 'nessuna pausa rimasta',
      1 => '1 pausa rimasta',
      final n => '$n pause rimaste',
    };
    return LayoutBuilder(
      builder: (context, c) {
        final files = this.files;
        final side = files != null && c.maxWidth >= sidePanelFrom;
        // con il pannello a destra il timer ha la sua colonna
        final timerWidth = side ? c.maxWidth - sidePanelWidth : c.maxWidth;
        // anello grande quanto la larghezza permette (fino a 380 px)
        final ring = math.min(timerWidth - 48, 380.0).clamp(200.0, 380.0);
        final column = SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  header,
                  const SizedBox(height: 20),
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
                  // schermi stretti: i file sotto i comandi, prima delle
                  // righe sul silenzio
                  if (files != null && !side) ...[
                    const SizedBox(height: 24),
                    files,
                  ],
                  const SizedBox(height: 24),
                  _QuietInfo(focus: focus, hint: hint, color: t.textMuted),
                ],
              ),
            ),
          ),
        );
        if (!side) return column;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: column),
            const VerticalDivider(width: 1),
            SizedBox(
              width: sidePanelWidth - 1,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                child: files,
              ),
            ),
          ],
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
            // tanti tratti (4 ore, pause ogni 20 minuti) su un telefono
            // stretto: spazi e larghezze minime si riducono per stare nella
            // riga invece di sforarla
            final max = c.maxWidth.isFinite ? c.maxWidth : 0.0;
            final n = plan.length;
            final gap = n > 1 ? math.min(4.0, max * 0.25 / (n - 1)) : 0.0;
            final usable = math.max(0.0, max - gap * (n - 1));
            final widths = [
              for (final seg in plan)
                math.max(
                  seg.phase == FocusPhase.rest ? 10.0 : 16.0,
                  usable * seg.length.inSeconds / total,
                ),
            ];
            final sum = widths.fold(0.0, (a, b) => a + b);
            final k = sum > usable && sum > 0 ? usable / sum * 0.999 : 1.0;
            return Row(
              children: [
                for (var i = 0; i < plan.length; i++) ...[
                  if (i > 0) SizedBox(width: gap),
                  SizedBox(
                    width: widths[i] * k,
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
///
/// Le cifre sono grandi e in proporzione all'anello (circa un quinto del
/// diametro), semigrassetto e a larghezza fissa (le cifre non ballano a ogni
/// secondo); si rimpiccioliscono solo loro se non ci stanno. Etichetta e
/// riga sotto hanno una larghezza propria e vanno a capo o si accorciano,
/// senza rimpicciolire il tempo.
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
            child: _RingFace(
              size: size,
              label: label,
              time: time,
              caption: caption,
              rest: rest,
              dimmed: dimmed,
            ),
          ),
        ),
      ),
    );
  }
}

/// Testo al centro dell'anello: etichetta, tempo, riga sotto.
class _RingFace extends StatelessWidget {
  const _RingFace({
    required this.size,
    required this.label,
    required this.time,
    required this.caption,
    required this.rest,
    required this.dimmed,
  });

  final double size;
  final String label;
  final String time;
  final String caption;
  final bool rest;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    // dentro l'anello (raggio interno ~0,38 del lato): il tempo occupa la
    // corda centrale, etichetta e riga sotto una corda più corta
    final timeWidth = size * 0.64;
    final textWidth = size * 0.54;
    // «25:00» più grande di «1:05:09»
    final digits = size * (time.length > 5 ? 0.17 : 0.215);
    // caratteri grandi: etichetta e riga sotto crescono, ma restano
    // dentro l'anello
    final scaler = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: size >= 260 ? 1.4 : 1.2);
    final timeColor = dimmed ? t.textSecondary : t.textPrimary;
    return SizedBox.square(
      dimension: size * 0.7,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: textWidth,
              child: Text(
                label.toUpperCase(),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: scaler,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: rest ? t.cyanSoft : t.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                ),
              ),
            ),
            SizedBox(height: size * 0.015),
            SizedBox(
              key: const Key('focus-ring-time'),
              width: timeWidth,
              height: digits * 1.1,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  time,
                  maxLines: 1,
                  // cifre già in proporzione all'anello
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontSize: digits,
                    height: 1.05,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -digits * 0.02,
                    color: timeColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            SizedBox(height: size * 0.02),
            SizedBox(
              width: textWidth,
              child: Text(
                caption,
                textAlign: TextAlign.center,
                maxLines: size >= 240 ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                textScaler: scaler,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: t.textSecondary,
                  height: 1.3,
                ),
              ),
            ),
          ],
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
              if (result.focusMinutes >= 1 && focus.saveError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'La sessione non è stata salvata: ${focus.saveError}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
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
                      size: MediaQuery.textScalerOf(context)
                          .scale(94)
                          .clamp(94.0, 160.0),
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
