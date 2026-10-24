import 'dart:io' show Platform;

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
    required this.choices,
    required this.chosen,
    required this.exact,
  });
  final CalendarStatus status;
  final bool ics;

  /// Windows: l'ateneo ha bloccato l'account universitario (consenso
  /// dell'amministratore), anche per OneDrive.
  final bool adminBlocked;

  /// Windows: account Microsoft collegato (Collegamenti → OneDrive).
  final bool microsoftConnected;

  /// Calendari tra cui scegliere (vuoto se il calendario è spento o manca il
  /// permesso).
  final List<CalendarChoice> choices;

  /// Calendario scelto (null = predefinito).
  final String? chosen;

  /// Android: avvisi all'ora esatta consentiti.
  final bool exact;
}

/// «Calendario»: esami, prove in itinere ed esoneri (aggiunti a mano in
/// Esami o dal database) come eventi nel calendario vero dello studente
/// (Android: un calendario sincronizzato, di solito Google; iPhone, iPad e
/// Mac: il predefinito; Windows: Outlook dell'account Microsoft), con i
/// promemoria nativi e aggiornati da soli a ogni modifica. Si può scegliere
/// il calendario; senza un calendario utilizzabile le notifiche le manda
/// l'app («calendario interno», nessun calendario visibile). Con i dati
/// sincronizzati fra dispositivi scrive un solo dispositivo per account. Il
/// file .ics resta solo dove non c'è un calendario di sistema collegabile.
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
    // corpo a blocchi: una freccia restituirebbe il Future a setState
    // (errore «setState() callback argument returned a Future»)
    if (mounted) {
      setState(() {
        _future = _load();
      });
    }
  }

  Future<_CalendarData> _load() async {
    final outlook = _s.reminders.outlook;
    final status = await _s.reminders.calendar.status();
    var choices = const <CalendarChoice>[];
    if (status.enabled) {
      try {
        choices = await _s.reminders.calendarChoices();
      } catch (_) {}
    }
    return _CalendarData(
      status: status,
      ics: await CalendarExport(_s).enabled(),
      microsoftConnected: outlook == null
          ? true
          : await outlook.microsoftConnected(),
      adminBlocked: outlook != null && await _s.onedrive.adminConsentNeeded(),
      choices: choices,
      chosen: await _s.reminders.calendar.chosen(),
      exact: await _s.reminders.exactAlarmsAllowed(),
    );
  }

  Future<void> _toggle(bool on) async {
    // doppio tocco prima che l'interruttore si spenga: un solo collegamento
    if (_busy) return;
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
      if (!mounted) return;
      if (!st.working && st.error != null) {
        await showErrorDialog(context, 'Calendario non aggiornato', st.error!);
      } else if (st.working) {
        showSnack(context, calendarConnectedMessage(st));
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
    if (!await _blockedSheet() || !mounted || _busy) return;
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
          'Gratuito. Le prove saranno nel calendario Outlook dell\'account '
          'personale; OneDrive resta collegato come ora.',
    );
  }

  Future<void> _choose(String? id) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final st = await _s.reminders.chooseCalendar(id);
      if (mounted && st.working) {
        showSnack(context, calendarConnectedMessage(st));
      }
    } catch (e) {
      // prima l'errore non arrivava a nessuno: la scelta sembrava fatta
      if (mounted) {
        await showErrorDialog(context, 'Calendario non cambiato', e);
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
                            : 'Scrivi le prove nel tuo calendario',
                      ),
                      subtitle: Text(
                        windows
                            ? 'Esami, prove in itinere, esoneri e inizio delle '
                                  'sessioni come eventi nel calendario del tuo '
                                  'account Microsoft, con i promemoria. Si '
                                  'aggiornano da soli quando li modifichi.'
                            : 'Esami, prove in itinere, esoneri e inizio delle '
                                  'sessioni come eventi nel calendario che usi '
                                  '(Google, Samsung, iCloud…), con i '
                                  'promemoria. Si aggiornano da soli quando li '
                                  'modifichi.',
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
                    CalendarStatusLine(
                      status: st,
                      thisDevice: _s.onedrive.deviceName,
                    ),
                    if (d.choices.isNotEmpty && st.writtenBy == null) ...[
                      const SizedBox(height: 8),
                      _CalendarPicker(
                        choices: d.choices,
                        chosen: d.chosen,
                        current: st.calendarName,
                        enabled: !_busy,
                        onChanged: _choose,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      'Promemoria agli anticipi scelti in Notifiche → Prove '
                      'in arrivo (predefiniti: il giorno prima e un\'ora '
                      'prima). Con il calendario funzionante gli avvisi delle '
                      'prove arrivano da lì, non due volte.',
                      style: muted,
                    ),
                    ActionWrap(
                      children: [
                        if (st.writtenBy != null)
                          AsyncActionButton(
                            label: 'Aggiorna da questo dispositivo',
                            icon: Icons.devices_outlined,
                            errorTitle: 'Calendario non aggiornato',
                            onPressed: () async {
                              await _s.reminders.takeOverCalendar();
                              _reload();
                            },
                          ),
                        if (!st.working)
                          AsyncActionButton(
                            label: windows ? 'Ricollega' : 'Riprova',
                            icon: Icons.refresh,
                            errorTitle: 'Calendario non collegato',
                            onPressed: () async {
                              await _enable();
                              _reload();
                            },
                          ),
                        if (st.internal && Platform.isAndroid && !d.exact)
                          AsyncActionButton(
                            label: 'Avvisi puntuali',
                            icon: Icons.alarm_on_outlined,
                            onPressed: () async {
                              await _s.reminders.requestExactAlarms();
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

/// «Prove nel calendario «Calendario» · nome@gmail.com».
String calendarConnectedMessage(CalendarStatus st) {
  final where = [
    if (st.calendarName != null) '«${st.calendarName}»',
    if (st.account != null && st.account!.isNotEmpty) st.account!,
  ].join(' · ');
  return where.isEmpty
      ? 'Calendario collegato: le prove sono nel tuo calendario.'
      : 'Calendario collegato: le prove sono nel calendario $where.';
}

/// Scelta del calendario (nome, account e colore).
class _CalendarPicker extends StatelessWidget {
  const _CalendarPicker({
    required this.choices,
    required this.chosen,
    required this.current,
    required this.enabled,
    required this.onChanged,
  });
  final List<CalendarChoice> choices;
  final String? chosen;
  final String? current;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // il calendario usato ora: quello scelto o, senza scelta, quello con il
    // nome mostrato nello stato (il predefinito)
    final value = choices.any((c) => c.id == chosen)
        ? chosen
        : choices.where((c) => c.name == current).firstOrNull?.id ??
              choices.first.id;
    return DropdownButtonFormField<String>(
      key: const Key('calendar-choice'),
      isExpanded: true,
      initialValue: value,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: const InputDecoration(labelText: 'Calendario usato'),
      items: [
        for (final c in choices)
          DropdownMenuItem(
            value: c.id,
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 12,
                  color: c.color == null ? scheme.primary : Color(c.color!),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.primary ? '${c.label} (principale)' : c.label,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
      onChanged: enabled
          ? (id) {
              if (id != null && id != value) onChanged(id);
            }
          : null,
    );
  }
}

/// Stato del calendario: dove sono gli eventi e quando sono stati
/// aggiornati, chi li aggiorna (un altro dispositivo) o, se non funziona,
/// che le notifiche le manda l'app e perché.
class CalendarStatusLine extends StatelessWidget {
  const CalendarStatusLine({
    super.key,
    required this.status,
    this.thisDevice,
  });
  final CalendarStatus status;
  final String? thisDevice;

  /// Testo dello stato (anche per i test).
  static String text(CalendarStatus status, {String? thisDevice}) {
    final last = status.lastOk == null
        ? 'mai'
        : formatIsoDateTime(status.lastOk!.toIso8601String());
    final where = [
      if (status.calendarName != null) '«${status.calendarName}»',
      if (status.account != null && status.account!.isNotEmpty)
        status.account!,
    ].join(' · ');
    if (!status.working) {
      return 'Calendario interno: le notifiche di tutte le prove le manda '
          'l\'app (nessun calendario visibile). ${status.error ?? ''}'
          '\nUltimo aggiornamento riuscito del calendario: $last';
    }
    final by = status.writtenBy;
    if (by != null) {
      return 'Calendario aggiornato '
          '${calendarWriterLabel(by, thisDevice: thisDevice)}'
          '${where.isEmpty ? '' : ' ($where)'}: questo dispositivo non lo '
          'modifica, così non ci sono doppioni. Ultimo controllo: $last';
    }
    final n = status.written.length;
    final count = n == 1 ? '1 evento' : '$n eventi';
    return 'Collegamento funzionante · $count nel calendario '
        '${where.isEmpty ? 'scelto' : where} · aggiornato $last';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = status.working;
    final warning = status.warning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
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
                text(status, thisDevice: thisDevice),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        if (ok && warning != null) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.sync_problem_outlined,
                size: 18,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(warning, style: theme.textTheme.bodySmall),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
