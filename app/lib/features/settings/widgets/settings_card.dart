import 'package:flutter/material.dart';

import '../../../widgets/glass.dart';

/// Riquadro di una sezione delle impostazioni.
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final List<Widget> children;

  /// Azione accanto al titolo (es. «Cambia corso» in Il mio percorso).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (trailing case final action?)
              // con i caratteri grandi il pulsante si restringe (il testo va
              // a capo) invece di uscire dalla card
              Row(
                children: [
                  Expanded(
                    child: CardHeader(
                      title: title,
                      icon: icon,
                      padding: const EdgeInsets.only(bottom: 4),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(child: action),
                ],
              )
            else
              CardHeader(
                title: title,
                icon: icon,
                padding: const EdgeInsets.only(bottom: 4),
              ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Riga "etichetta: valore" compatta.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
