import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../widgets/floating_pill.dart';
import '../../notes/recorder/recording_overlay.dart' show appNavigatorKey;
import 'focus_plan.dart';
import 'focus_screen.dart';
import 'focus_service.dart';

/// Riquadro della sessione Focus sopra le schermate (come quello della
/// registrazione): nome, tempo del tratto in corso, Pausa/Riprendi, «Salta
/// pausa» durante le pause e X per terminare. Tocco → schermata Focus.
class FocusPill extends StatelessWidget {
  const FocusPill({super.key, required this.focus, required this.onDrag});

  final FocusService focus;
  final ValueChanged<Offset> onDrag;

  BuildContext? get _nav => appNavigatorKey.currentContext;

  void _open() {
    final nav = _nav;
    if (nav != null) unawaited(openFocusScreen(nav));
  }

  Future<void> _close() async {
    final nav = _nav;
    if (nav == null) return;
    await finishFocusAsking(nav, focus);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final timer = focus.timer;
    final p = timer.position;
    final rest = p.phase == FocusPhase.rest;
    final paused = timer.paused;
    final name = focus.current.label ?? 'Sessione Focus';
    final status =
        '${formatCountdown(p.segmentRemaining)} · '
        '${paused ? 'In pausa' : (rest ? 'Pausa' : 'Concentrazione')}';
    return FloatingPill(
      semanticsLabel: 'Sessione Focus: $name, $status. Tocca per aprirla',
      leading: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(
          value: p.segmentProgress.clamp(0.0, 1.0),
          strokeWidth: 3,
          color: paused ? t.textMuted : t.cyan,
          backgroundColor: t.textPrimary.withValues(alpha: 0.12),
        ),
      ),
      title: name,
      status: status,
      onOpen: _open,
      onDrag: onDrag,
      actions: [
        if (rest && !paused)
          PillButton(
            icon: Icons.skip_next_rounded,
            label: 'Salta la pausa',
            color: t.cyan,
            onTap: focus.skipBreak,
          ),
        PillButton(
          icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          label: paused ? 'Riprendi la sessione' : 'Metti in pausa la sessione',
          onTap: focus.togglePause,
        ),
        PillButton(
          icon: Icons.close_rounded,
          label: 'Termina la sessione Focus',
          onTap: () => unawaited(_close()),
        ),
      ],
    );
  }
}
