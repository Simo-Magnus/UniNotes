import 'package:flutter/material.dart';

import '../../../core/router/app_shell.dart';
import '../../../core/theme/app_tokens.dart';
import '../../books/book_filters.dart' show readingProgress;
import '../../books/book_opener.dart';
import '../dashboard_data.dart';
import 'dashboard_card.dart';

/// Libri dei corsi: quanti sono scaricati, quanti obbligatori mancano e
/// l'ultimo letto, da riprendere dalla pagina dove ci si era fermati.
class BooksCard extends StatelessWidget {
  const BooksCard({super.key, required this.data});

  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    final b = data.books;
    final t = context.tokens;
    final theme = Theme.of(context);
    final last = b.lastRead;
    return DashboardCard(
      icon: Icons.menu_book_outlined,
      title: 'Libri',
      actionLabel: 'Libri',
      onAction: () => AppShell.goTo(context, 'Libri'),
      child: b.isEmpty
          ? const CardEmptyMessage(
              icon: Icons.menu_book_outlined,
              message:
                  'Nessun libro per i tuoi insegnamenti: aggiungili dalla '
                  'sezione Libri.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: _Figure(
                          value: b.downloaded,
                          label: 'scaricati',
                          color: t.cyanSoft,
                        ),
                      ),
                      Expanded(
                        child: _Figure(
                          value: b.toProcure,
                          label: 'obbligatori da procurare',
                          color: b.toProcure > 0 ? t.tintBooks : t.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (last != null)
                  ListTile(
                    key: const Key('home-last-book'),
                    leading: Icon(
                      Icons.auto_stories_outlined,
                      color: t.tintBooks,
                    ),
                    title: Text(
                      last.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        'Riprendi la lettura',
                        ?readingProgress(last),
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openBook(context, last),
                  ),
              ],
            ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.value,
    required this.label,
    required this.color,
  });
  final int value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$value',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
