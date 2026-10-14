import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/build_flags.dart';
import '../../../core/reminders/notification_prefs.dart';
import '../../../core/reminders/system_calendar.dart';
import '../../../core/services/app_services.dart';
import '../../../widgets/common.dart';
import '../widgets/async_action_button.dart';
import '../widgets/settings_card.dart';

class _NotificationsData {
  const _NotificationsData(this.prefs, this.permission, this.calendar);
  final NotificationPrefs prefs;
  final bool permission;
  final CalendarStatus calendar;
}

/// «Notifiche»: consenso (con la richiesta del permesso del sistema), un
/// interruttore per tipo, anticipi degli avvisi delle prove e una notifica
/// di prova. Recensione e sostegno sono inviti facoltativi, spegnibili qui.
class NotificationsSection extends StatefulWidget {
  const NotificationsSection({super.key});

  @override
  State<NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<NotificationsSection> {
  late final AppServices _s = context.read<AppServices>();
  late Future<_NotificationsData> _future = _load();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _s.reminders.addListener(_reload);
  }

  @override
  void dispose() {
    _s.reminders.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  Future<_NotificationsData> _load() async {
    final prefs = await NotificationPrefs.load(_s.settings);
    return _NotificationsData(
      prefs,
      prefs.consent && await _s.reminders.permissionGranted(),
      await _s.reminders.calendar.status(),
    );
  }

  Future<void> _consent(bool on) async {
    setState(() => _busy = true);
    try {
      if (on) {
        final ok = await _s.reminders.enableNotifications();
        if (!ok && mounted) {
          showSnack(
            context,
            'Permesso non concesso: puoi attivare le notifiche di UniNotes '
            'nelle impostazioni del sistema.',
          );
        }
      } else {
        await _s.reminders.disableNotifications();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _reload();
    }
  }

  Future<void> _set(String key, bool v) async {
    await _s.settings.set(key, v ? '1' : '0');
    _reload();
    await _s.reminders.refresh();
  }

  Future<void> _setOffsets(List<int> v) async {
    await _s.settings.set(
      NotificationKeys.examOffsets,
      NotificationPrefs.formatOffsets(v),
    );
    _reload();
    await _s.reminders.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SettingsCard(
      title: 'Notifiche',
      icon: Icons.notifications_outlined,
      children: [
        if (!_s.reminders.notificationsSupported)
          Text(
            'Le notifiche non sono disponibili su questo sistema.',
            style: muted,
          )
        else
          FutureBuilder<_NotificationsData>(
            future: _future,
            builder: (context, snap) {
              final d = snap.data;
              if (d == null) return const SizedBox(height: 48);
              final p = d.prefs;
              Widget toggle(String key, String title, String sub, bool v) =>
                  SwitchListTile(
                    key: Key('notif-$key'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(title),
                    subtitle: Text(sub),
                    value: v,
                    onChanged: (x) => _set(key, x),
                  );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    key: const Key('notifications-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Notifiche di UniNotes'),
                    subtitle: Text(
                      !p.consent
                          ? 'Avvisi delle prove, delle sessioni e dei '
                                'collegamenti. Tutto è pianificato sul '
                                'dispositivo, senza server.'
                          : d.permission
                          ? 'Attive.'
                          : 'Il sistema non permette di mostrarle: '
                                'attivale nelle sue impostazioni.',
                    ),
                    value: p.consent,
                    onChanged: _busy ? null : _consent,
                  ),
                  if (p.consent) ...[
                    toggle(
                      NotificationKeys.exams,
                      'Prove in arrivo',
                      'Esami, prove in itinere ed esoneri.',
                      p.exams,
                    ),
                    if (p.exams)
                      _OffsetsPicker(
                        selected: p.examOffsets,
                        onChanged: _setOffsets,
                      ),
                    toggle(
                      NotificationKeys.sessions,
                      'Inizio sessione d\'esame',
                      'Il giorno prima dell\'inizio di ogni sessione del tuo '
                          'corso.',
                      p.sessions,
                    ),
                    toggle(
                      NotificationKeys.outcome,
                      'Com\'è andata?',
                      'Il giorno dopo una prova, per registrare voto o esito.',
                      p.outcome,
                    ),
                    toggle(
                      NotificationKeys.links,
                      'Collegamento interrotto',
                      'Se OneDrive, Google Drive o il calendario chiedono di '
                          'ricollegarsi.',
                      p.links,
                    ),
                    toggle(
                      NotificationKeys.review,
                      'Richiesta di recensione',
                      'Una sola richiesta, dopo almeno due settimane d\'uso.',
                      p.review,
                    ),
                    if (kShowDonationLink)
                      toggle(
                        NotificationKeys.donation,
                        'Sostieni il progetto',
                        'Invito facoltativo, al massimo ogni 6 mesi: '
                            'l\'app resta gratuita e completa.',
                        p.donation,
                      ),
                    if (d.calendar.working) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Il calendario è collegato: per le prove e le sessioni '
                        'scritte nel calendario gli avvisi arrivano da lì, '
                        'non dall\'app.',
                        style: muted,
                      ),
                    ],
                    ActionWrap(
                      children: [
                        AsyncActionButton(
                          label: 'Prova una notifica',
                          icon: Icons.notifications_active_outlined,
                          errorTitle: 'Notifica non mostrata',
                          onPressed: _s.reminders.testNotification,
                        ),
                        if (!d.permission)
                          AsyncActionButton(
                            label: 'Impostazioni del sistema',
                            icon: Icons.open_in_new,
                            onPressed: _s.reminders.platform.openSystemSettings,
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

/// Anticipi degli avvisi delle prove (giorni prima).
class _OffsetsPicker extends StatelessWidget {
  const _OffsetsPicker({required this.selected, required this.onChanged});
  final List<int> selected;
  final ValueChanged<List<int>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final d in kExamOffsetChoices)
            FilterChip(
              label: Text(d == 1 ? 'Il giorno prima' : '$d giorni prima'),
              selected: selected.contains(d),
              onSelected: (on) => onChanged([
                for (final x in selected)
                  if (x != d) x,
                if (on) d,
              ]),
            ),
        ],
      ),
    );
  }
}
