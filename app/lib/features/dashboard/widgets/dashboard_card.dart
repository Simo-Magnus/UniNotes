import 'package:flutter/material.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../widgets/glass.dart';

/// Card della Home con intestazione (icona, titolo, widget opzionale).
/// Con [onTap] la card intera porta alla sua sezione ([section], es.
/// «Esami»): niente più pulsante con il nome della sezione nell'intestazione;
/// al tocco c'è l'increspatura della card e la vibrazione/suono del tocco.
/// Gli elementi toccabili dentro la card (una prova, una registrazione, il
/// selettore della suddivisione) restano loro: il tocco va a loro.
class DashboardCard extends StatelessWidget {
  const DashboardCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.onTap,
    this.section,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;

  /// Apre la sezione della card.
  final VoidCallback? onTap;

  /// Nome della sezione aperta da [onTap] (per i lettori di schermo).
  final String? section;

  /// Widget extra nell'intestazione (es. un selettore).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardHeader(title: title, icon: icon, trailing: trailing),
          child,
        ],
      ),
    );
    final tap = onTap;
    return GlassCard(
      child: tap == null
          ? content
          : Semantics(
              container: true,
              button: true,
              hint: section == null ? null : 'Apri la sezione $section',
              child: InkWell(
                onTap: () {
                  AppFeedback.of(context).tap();
                  tap();
                },
                child: content,
              ),
            ),
    );
  }
}

/// Messaggio discreto per una card senza contenuti.
class CardEmptyMessage extends StatelessWidget {
  const CardEmptyMessage({
    super.key,
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
