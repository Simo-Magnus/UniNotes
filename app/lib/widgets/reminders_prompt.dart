import 'package:flutter/material.dart';

import '../core/constants/build_flags.dart';
import '../core/reminders/notification_prefs.dart';
import '../core/services/app_services.dart';
import 'common.dart';

/// Richiesta contestuale delle notifiche per chi non ha risposto nel passo
/// «Vuoi gli avvisi?» dell'onboarding (es. onboarding fatto con una versione
/// precedente): la prima volta che si salva una prova con una data (mai
/// all'avvio). Una sola volta: poi si decide da Impostazioni → Notifiche.
Future<void> offerExamReminders(BuildContext context, AppServices s) async {
  final r = s.reminders;
  if (!r.started || !r.notificationsSupported) return;
  if (await s.settings.get(NotificationKeys.consent) != null ||
      await s.settings.get(NotificationKeys.asked) != null) {
    return;
  }
  if (!context.mounted) return;
  final yes = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Vuoi un avviso prima delle prove?'),
      content: const Text(
        'UniNotes può ricordarti esami, prove in itinere ed esoneri 7 giorni '
        'prima e il giorno prima, e l\'inizio delle sessioni d\'esame. Una '
        'sola volta potrà anche chiederti una recensione'
        '${kShowDonationLink ? ' e, al massimo ogni sei mesi, invitarti a '
                  'sostenere il progetto (è facoltativo)' : ''}. '
        'Puoi cambiare tutto in Impostazioni, Notifiche.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Non ora'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Attiva gli avvisi'),
        ),
      ],
    ),
  );
  await s.settings.set(NotificationKeys.asked, '1');
  if (yes != true) return;
  final ok = await r.enableNotifications();
  if (!ok && context.mounted) {
    showSnack(
      context,
      'Permesso non concesso: puoi attivare le notifiche dalle impostazioni '
      'del sistema.',
    );
  }
}
