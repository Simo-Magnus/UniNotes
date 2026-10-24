import 'package:flutter/material.dart';

import '../../../core/feedback/app_modals.dart';
import '../logic/exclusion_cleanup.dart';

/// Conferma prima di nascondere gli elementi esclusi, con l'elenco completo.
Future<bool> showExclusionConfirmDialog(
  BuildContext context,
  ExclusionMatches m,
) async {
  final theme = Theme.of(context);
  Widget group(String title, Iterable<String> lines) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('• $l', style: theme.textTheme.bodySmall),
          ),
      ],
    ),
  );

  final r = await showAppDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.visibility_off_outlined),
      title: Text('Nascondere ${m.total} elementi?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'I seguenti elementi, insieme a moduli, argomenti e materiali '
                'collegati saranno rimossi',
              ),
              if (m.courses.isNotEmpty)
                group(
                  'Corsi (${m.courses.length})',
                  m.courses.map((c) => c.label),
                ),
              if (m.events.isNotEmpty)
                group(
                  'Eventi / lezioni (${m.events.length})',
                  m.eventTitleCounts.entries.map(
                    (e) => e.value > 1 ? '${e.key}  ×${e.value}' : e.key,
                  ),
                ),
              if (m.exams.isNotEmpty)
                group(
                  'Esami / prove (${m.exams.length})',
                  m.exams.map((x) => x.label),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Annulla'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Nascondi'),
        ),
      ],
    ),
  );
  return r ?? false;
}
