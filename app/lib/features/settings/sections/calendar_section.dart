import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/reminders/system_calendar.dart';
import '../../../core/router/app_shell.dart';
import '../../../core/services/app_services.dart';
import '../../../core/services/calendar_export.dart';
import '../../../widgets/common.dart';
import '../logic/formatting.dart';
import '../widgets/async_action_button.dart';
import '../widgets/settings_card.dart';

/// Stato mostrato dalla sezione.
class _CalendarData {
  const _CalendarData({
    required this.status,
    required this.ics,
    required this.microsoftConnected,
  });
  final CalendarStatus status;
  final bool ics;

  /// Windows: account Microsoft collegato (Collegamenti → OneDrive).
  final bool microsoftConnected;
}

/// «Calendario»: esami, prove in itinere ed esoneri (aggiunti a mano in
/// Esami o dal database) nel calendario di sistema (Android, iOS:
/// calendario del dispositivo; Windows: Outlook dell'account Microsoft),
/// aggiornati da soli a ogni modifica. Il file .ics resta solo su macOS,
/// dove il calendario di sistema non si collega e l'esportazione .ics è
/// l'unico modo.
class CalendarSection extends StatefulWidget {
  const CalendarSection({super.key});

  @override
  State<CalendarSection> createState() => _CalendarSectionState();
}

class _CalendarSectionState extends State<CalendarSection> {
  late final AppServices _s = context.read<AppServices>();
  late Future<_CalendarData> _future = _load();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _s.reminders.addListener(_reload);
    _s.revision.addListener(_reload);
  }

  @override
  void dispose() {
    _s.reminders.removeListener(_reload);
    _s.revision.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  Future<_CalendarData> _load() async {
    final outlook = _s.reminders.outlook;
    return _CalendarData(
      status: await _s.reminders.calendar.status(),
      ics: await CalendarExport(_s).enabled(),
      microsoftConnected: outlook == null
          ? true
          : await outlook.microsoftConnected(),
    );
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    try {
      if (on) {
        final st = await _s.reminders.enableCalendar();
        if (mounted && !st.working && st.error != null) {
          await showErrorDialog(
            context,
            'Calendario non aggiornato',
            st.error!,
          );
        }
      } else {
        await _s.reminders.disableCalendar();
      }
    } catch (e) {
      if (mounted) {
        await showErrorDialog(context, 'Calendario non collegato', e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final sync = _s.reminders.calendar;
    final windows = _s.reminders.outlook != null;
    return SettingsCard(
      title: 'Calendario',
      icon: Icons.event_outlined,
      children: [
        FutureBuilder<_CalendarData>(
          future: _future,
          builder: (context, snap) {
            final d = snap.data;
            if (d == null) return const SizedBox(height: 48);
            final st = d.status;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!sync.supported)
                  Text(
                    'Su questo sistema le prove si aggiungono al calendario '
                    'con un file .ics, che l\'app di calendario importa e '
                    'aggiorna senza doppioni.',
                    style: muted,
                  )
                else ...[
                  if (windows && !d.microsoftConnected) ...[
                    Text(
                      'Per scrivere le prove nel calendario Outlook serve '
                      'l\'account Microsoft collegato in Collegamenti → '
                      'OneDrive.',
                      style: muted,
                    ),
                    ActionWrap(
                      children: [
                        OutlinedButton.icon(
                          onPressed: () =>
                              AppShell.goTo(context, 'Collegamenti'),
                          icon: const Icon(Icons.link),
                          label: const Text('Collega l\'account Microsoft'),
                        ),
                      ],
                    ),
                  ] else
                    SwitchListTile(
                      key: const Key('system-calendar-switch'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        windows
                            ? 'Scrivi le prove nel calendario Outlook'
                            : 'Scrivi le prove nel calendario del dispositivo',
                      ),
                      subtitle: const Text(
                        'Esami, prove in itinere, esoneri e inizio delle '
                        'sessioni nel calendario «UniNotes», con i '
                        'promemoria. Si aggiornano da soli quando li modifichi.',
                      ),
                      value: st.enabled,
                      onChanged: _busy ? null : _toggle,
                    ),
                  if (st.enabled) ...[
                    const SizedBox(height: 4),
                    _StatusLine(status: st),
                    if (!st.working)
                      ActionWrap(
                        children: [
                          AsyncActionButton(
                            label: windows ? 'Ricollega' : 'Riprova',
                            icon: Icons.refresh,
                            errorTitle: 'Calendario non collegato',
                            onPressed: () async {
                              await _s.reminders.enableCalendar();
                              _reload();
                            },
                          ),
                        ],
                      ),
                  ],
                ],
                // solo macOS: file .ics, l'unico modo senza calendario di
                // sistema
                if (!sync.supported) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const Key('calendar-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Aggiungi esami, prove in itinere ed esoneri al calendario',
                    ),
                    subtitle: const Text(
                      'Con un file .ics quando aggiungi una prova.',
                    ),
                    value: d.ics,
                    onChanged: (v) async {
                      await CalendarExport(_s).setEnabled(v);
                      _s.revision.bump();
                    },
                  ),
                  ActionWrap(
                    children: [
                      AsyncActionButton(
                        label: 'Aggiungi ora tutte le prove con una data',
                        icon: Icons.event_available_outlined,
                        errorTitle: 'Calendario non aggiornato',
                        onPressed: () async {
                          final cal = CalendarExport(_s);
                          final r = await cal.open(await cal.pendingWithDate());
                          if (context.mounted) showLaunchResult(context, r);
                        },
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

/// «Collegamento funzionante · ultima sincronizzazione …» o l'errore.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status});
  final CalendarStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = status.working;
    final last = status.lastOk == null
        ? 'mai'
        : formatIsoDateTime(status.lastOk!.toIso8601String());
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? Icons.check_circle_outline : Icons.error_outline,
          size: 18,
          color: ok ? theme.colorScheme.primary : theme.colorScheme.error,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ok
                ? 'Collegamento funzionante · ultima sincronizzazione $last'
                : 'Collegamento non funzionante: le notifiche dell\'app '
                      'avvisano di tutte le prove. '
                      '${status.error ?? ''}\nUltima sincronizzazione '
                      'riuscita: $last',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
