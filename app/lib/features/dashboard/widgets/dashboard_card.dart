import 'package:flutter/material.dart';

import '../../../widgets/glass.dart';

/// Card della Home con intestazione (icona, titolo, azione opzionale).
class DashboardCard extends StatelessWidget {
  const DashboardCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.actionLabel,
    this.onAction,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Widget extra nell'intestazione (es. un totale).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardHeader(
              title: title,
              icon: icon,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?trailing,
                  if (actionLabel != null && onAction != null)
                    TextButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ),
            ),
            child,
          ],
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
