import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/reminders/system_calendar.dart';
import '../../../core/router/app_shell.dart';
import '../../../core/services/app_services.dart';
import '../../../core/services/calendar_export.dart';
import '../../../widgets/common.dart';
import '../../cloud/microsoft_admin_consent.dart';
import '../../links/microsoft_consent_sheet.dart';
import '../logic/formatting.dart';
import '../widgets/async_action_button.dart';
import '../widgets/settings_card.dart';

/// Stato mostrato dalla sezione.
class _CalendarData {
  const _CalendarData({
    required this.status,
    required this.ics,
    required this.microsoftConnected,
    required this.adminBlocked,
  });
  final CalendarStatus status;
  final bool ics;

  /// Windows: l'ateneo ha bloccato l'account universitario (consenso
  /// dell'amministratore), anche per OneDrive.
  final bool adminBlocked;

  /// Windows: account Microsoft collegato (Collegamenti → OneDrive).
  final bool microsoftConnected;
}

/// «Calendario»: esami, prove in itinere ed esoneri (aggiunti a mano in
/// Esami o dal database) nel calendario di sistema (Android, iOS, macOS:
/// calendario del dispositivo; Windows: Outlook dell'account Microsoft),
/// aggiornati da soli a ogni modifica. Il file .ics resta solo dove non c'è
/// un calendario di sistema collegabile (nessuna delle quattro piattaforme
/// dell'app).
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
      adminBlocked: outlook != null && await _s.onedrive.adminConsentNeeded(),
    );
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    try {
      if (on) {
        await _enable();
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

  /// Attiva il calendario. Su Windows, se l'ateneo blocca l'account
  /// universitario, mostra la scheda «Il tuo ateneo deve approvare
  /// UniNotes» al posto dell'errore; con [chooseAccount] l'accesso parte
  /// dalla scelta dell'account (account Microsoft personale).
  Future<void> _enable({bool chooseAccount = false}) async {
    final outlook = _s.reminders.outlook;
    try {
      if (chooseAccount) await outlook?.connect(chooseAccount: true);
      final st = await _s.reminders.enableCalendar();
      if (mounted && !st.working && st.error != null) {
        await showErrorDialog(context, 'Calendario non aggiornato', st.error!);
      }
    } catch (e) {
      if (outlook == null || !MicrosoftAdminConsent.isAdminConsentError(e)) {
        rethrow;
      }
      await _s.onedrive.setAdminConsentNeeded(true);
      if (await _blockedSheet(error: e)) await _enable(chooseAccount: true);
    }
  }

  /// Link «Perché non riesco a collegare l'account universitario?».
  Future<void> _openBlockedHelp() async {
    if (!await _blockedSheet() || !mounted) return;
    setState(() => _busy = true);
    try {
      await _enable(chooseAccount: true);
    } catch (e) {
      if (mounted) {
        await showErrorDialog(context, 'Calendario non collegato', e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _reload();
    }
  }

  Future<bool> _blockedSheet({Object? error}) async {
    final id = await _s.onedrive.clientId();
    if (!mounted) return false;
    return showUniversityBlockedSheet(
      context,
      clientId: id,
      declined: MicrosoftAdminConsent.isDeclined(error),
      personalHint:
          'Gratuito. Il calendario «UniNotes» sarà nell\'Outlook dell\'account '
          'personale; OneDrive resta collegato come ora.',
    );
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
                  if (windows &&
                      d.microsoftConnected &&
                      d.adminBlocked &&
                      !(st.enabled && st.working))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _busy ? null : _openBlockedHelp,
                        icon: const Icon(Icons.help_outline, size: 18),
                        label: const Text(kUniversityAccountHelp),
                      ),
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
                              await _enable();
                              _reload();
                            },
                          ),
                        ],
                      ),
                  ],
                ],
                // file .ics solo senza calendario di sistema collegabile
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
