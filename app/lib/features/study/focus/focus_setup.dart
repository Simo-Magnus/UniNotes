import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/feedback/motion.dart';
import '../../../core/services/app_services.dart';
import 'focus_plan.dart';
import 'focus_screen.dart';
import 'focus_service.dart';
import 'focus_system.dart';

/// Timer di studio (Sessioni Studio → Timer): durata, pause automatiche e
/// avvio della sessione Focus. Che cosa si studia lo sceglie la schermata
/// ([link]).
class FocusTimerSetup extends StatefulWidget {
  const FocusTimerSetup({super.key, required this.link, this.enabled = true});

  /// Collegamento della sessione (insegnamento, modulo, argomento, nomi).
  final Future<FocusLink> Function() link;

  /// false se non si può avviare (es. cronometro in corso).
  final bool enabled;

  @override
  State<FocusTimerSetup> createState() => _FocusTimerSetupState();
}

class _FocusTimerSetupState extends State<FocusTimerSetup> {
  late final AppServices _s = context.read<AppServices>();
  late FocusSettings _settings = _s.focus.settings;
  bool _starting = false;

  void _setMinutes(int m) {
    final v = m.clamp(FocusSettings.minMinutes, FocusSettings.maxMinutes);
    if (v == _settings.minutes) return;
    AppFeedback.of(context).toggle();
    setState(() => _settings = _settings.copyWith(minutes: v));
  }

  /// Passo dei pulsanti − e +: 5 minuti fino a un'ora, poi 15.
  int _step(bool up) {
    final m = _settings.minutes;
    return (up ? m >= 60 : m > 60) ? 15 : 5;
  }

  Future<void> _start() async {
    if (_starting) return;
    final focus = _s.focus;
    final link = await widget.link();
    if (!mounted) return;
    final quiet = await prepareSystemQuiet(context, focus);
    if (quiet == null || !mounted) return;
    setState(() => _starting = true);
    await focus.askNotificationPermissionOnce();
    await focus.start(_settings, link, systemDnd: quiet);
    if (!mounted) return;
    setState(() => _starting = false);
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const FocusScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = buildFocusPlan(_settings);
    final end = DateTime.now().add(planLength(plan));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Concentrati per il tempo scelto: l\'app fa le pause per te e '
          'silenzia le notifiche non vitali.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        // durata: − valore +
        Row(
          children: [
            IconButton.outlined(
              tooltip: 'Meno tempo',
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              onPressed: _settings.minutes > FocusSettings.minMinutes
                  ? () => _setMinutes(_settings.minutes - _step(false))
                  : null,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Column(
                children: [
                  Text(
                    formatFocusLength(_settings.minutes),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    '${describePlan(plan)} · fine alle '
                    '${DateFormat.Hm('it_IT').format(end)}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton.outlined(
              tooltip: 'Più tempo',
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              onPressed: _settings.minutes < FocusSettings.maxMinutes
                  ? () => _setMinutes(_settings.minutes + _step(true))
                  : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        Slider(
          value: _settings.minutes.toDouble(),
          min: FocusSettings.minMinutes.toDouble(),
          max: FocusSettings.maxMinutes.toDouble(),
          divisions: (FocusSettings.maxMinutes - FocusSettings.minMinutes) ~/ 5,
          label: formatFocusLength(_settings.minutes),
          semanticFormatterCallback: (v) =>
              'Durata ${formatFocusLength(v.round())}',
          onChanged: (v) => _setMinutes(v.round()),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Pause automatiche'),
          subtitle: Text(
            _settings.breaks
                ? 'Una pausa di ${_settings.breakMinutes} min ogni '
                      '${_settings.breakEvery} min di concentrazione'
                : 'Nessuna pausa durante la sessione',
          ),
          value: _settings.breaks,
          onChanged: (v) {
            AppFeedback.of(context).toggle();
            setState(() => _settings = _settings.copyWith(breaks: v));
          },
        ),
        if (_settings.breaks)
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _ChoicePill(
                label: 'Ogni',
                value: _settings.breakEvery,
                choices: FocusSettings.breakEveryChoices,
                onChanged: (v) => setState(
                  () => _settings = _settings.copyWith(breakEvery: v),
                ),
              ),
              _ChoicePill(
                label: 'Pausa di',
                value: _settings.breakMinutes,
                choices: FocusSettings.breakLengthChoices,
                onChanged: (v) => setState(
                  () => _settings = _settings.copyWith(breakMinutes: v),
                ),
              ),
            ],
          ),
        const SizedBox(height: 20),
        Pressable(
          feedback: FeedbackEvent.tap,
          child: FilledButton.icon(
            key: const Key('focus-start'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _starting || !widget.enabled ? null : _start,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Avvia il timer'),
          ),
        ),
      ],
    );
  }
}

/// Scelta compatta «Ogni 30 min» con menu.
class _ChoicePill extends StatelessWidget {
  const _ChoicePill({
    required this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  final String label;
  final int value;
  final List<int> choices;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final all = {...choices, value}.toList()..sort();
    return PopupMenuButton<int>(
      tooltip: '$label $value minuti',
      initialValue: value,
      onSelected: (v) {
        AppFeedback.of(context).toggle();
        onChanged(v);
      },
      itemBuilder: (_) => [
        for (final c in all) PopupMenuItem(value: c, child: Text('$c min')),
      ],
      child: Chip(
        label: Text('$label $value min'),
        avatar: const Icon(Icons.expand_more, size: 18),
      ),
    );
  }
}

/// Silenzio del sistema all'avvio di una sessione (Impostazioni → Focus e
/// Non disturbare). Restituisce se attivarlo, o null se l'avvio è annullato.
/// Android senza «Accesso a Non disturbare»: spiega a che cosa serve e apre
/// la pagina del sistema (poi si avvia di nuovo) oppure si parte senza.
Future<bool?> prepareSystemQuiet(
  BuildContext context,
  FocusService focus,
) async {
  if (!focus.systemQuietEnabled) return false;
  if (focus.system.kind != FocusSystemKind.androidDnd) return true;
  if (await focus.system.hasDndAccess()) return true;
  if (!context.mounted) return null;
  final grant = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.do_not_disturb_on_outlined),
      title: const Text('Silenziare il telefono?'),
      content: const Text(
        'Durante la sessione il Non disturbare blocca le notifiche di tutte '
        'le app: passano solo sveglie, chiamate ripetute e chiamate dai '
        'contatti preferiti. Alla fine torna tutto come prima.\n\n'
        'Per attivarlo Android chiede l\'«Accesso a Non disturbare»: si apre '
        'la pagina del sistema, scegli UniNotes, poi torna qui e avvia. '
        'Puoi spegnerlo in Impostazioni → Focus e Non disturbare.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Avvia senza'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Concedi l\'accesso'),
        ),
      ],
    ),
  );
  if (grant == null) return null;
  if (!grant) return false;
  await focus.system.openDndAccessSettings();
  // l'utente torna e avvia di nuovo, questa volta con il permesso
  return null;
}
