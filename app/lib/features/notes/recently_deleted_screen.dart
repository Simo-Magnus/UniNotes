import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import 'recycle_bin.dart';

/// «Eliminati di recente»: registrazioni e appunti eliminati negli ultimi
/// 30 giorni, da ripristinare (con «Annulla» nell'avviso, che li rimette
/// qui) o cancellare per sempre. «Svuota» è un pulsante grande sopra
/// l'elemento eliminato per ultimo.
class RecentlyDeletedScreen extends StatefulWidget {
  const RecentlyDeletedScreen({super.key});

  @override
  State<RecentlyDeletedScreen> createState() => _RecentlyDeletedScreenState();
}

class _RecentlyDeletedScreenState extends State<RecentlyDeletedScreen> {
  late final AppServices _s = context.read<AppServices>();
  late Future<List<TrashEntry>> _items = _s.trash.list();

  void _reload() => setState(() => _items = _s.trash.list());

  Future<void> _restore(TrashEntry e) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final files = await _s.trash.restore(e);
      _s.revision.bump();
      if (messenger != null && messenger.mounted) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                files.isEmpty
                    ? 'Niente da ripristinare.'
                    : '«${e.title}» ripristinato.',
              ),
              action: files.isEmpty
                  ? null
                  : SnackBarAction(
                      label: 'Annulla',
                      onPressed: () => _undoRestore(e, files),
                    ),
            ),
          );
      }
    } catch (err) {
      if (mounted) showSnack(context, 'Ripristino non riuscito: $err');
    }
    _reload();
  }

  /// «Annulla» dell'avviso: l'elemento torna in «Eliminati di recente».
  Future<void> _undoRestore(TrashEntry e, List<File> files) async {
    try {
      await _s.trash.undoRestore(e, files);
    } catch (err) {
      if (mounted) showSnack(context, 'Non riuscito: $err');
    }
    _s.revision.bump();
    if (mounted) _reload();
  }

  Future<void> _delete(TrashEntry e) async {
    if (!await _confirm(
      'Eliminare per sempre «${e.title}»?',
      'Il file viene cancellato subito e non si potrà recuperare.',
    )) {
      return;
    }
    await _s.trash.deleteForever(e);
    _reload();
  }

  Future<void> _empty(List<TrashEntry> all) async {
    if (!await _confirm(
      'Svuotare «Eliminati di recente»?',
      'Tutti i file vengono cancellati subito e non si potranno recuperare.',
    )) {
      return;
    }
    for (final e in all) {
      await _s.trash.deleteForever(e);
    }
    _reload();
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) {
        final scheme = Theme.of(c).colorScheme;
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Elimina'),
            ),
          ],
        );
      },
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<TrashEntry>>(
      future: _items,
      builder: (context, snap) {
        final items = snap.data ?? const <TrashEntry>[];
        return Scaffold(
          appBar: AppBar(title: const Text('Eliminati di recente')),
          body: snap.connectionState != ConnectionState.done
              ? const Center(child: CircularProgressIndicator())
              : _list(context, items),
        );
      },
    );
  }

  Widget _list(BuildContext context, List<TrashEntry> items) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final date = DateFormat('d MMM', 'it_IT');
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Text(
            'Le registrazioni e gli appunti eliminati restano qui 30 giorni, '
            'poi vengono cancellati.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: EmptyState(
              icon: Icons.delete_outline,
              message: 'Nessun file eliminato di recente.',
            ),
          )
        else ...[
          // «Svuota» grande, sopra l'elemento eliminato per ultimo
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: FilledButton.tonalIcon(
              key: const Key('trash-empty'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                foregroundColor: theme.colorScheme.error,
                textStyle: theme.textTheme.titleMedium,
              ),
              onPressed: () => _empty(items),
              icon: const Icon(Icons.delete_sweep_outlined),
              label: Text(
                items.length == 1 ? 'Svuota' : 'Svuota (${items.length})',
              ),
            ),
          ),
          GlassCard(
            child: Column(
              children: [
                for (final e in items)
                  ListTile(
                    leading: Icon(
                      e.isAudio ? Icons.graphic_eq : Icons.article_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(e.title),
                    subtitle: Text(
                      [
                        ?e.course,
                        'eliminato il ${date.format(e.deletedAt)}',
                        _left(RecycleBin.daysLeft(e.deletedAt, now)),
                      ].join(' · '),
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Azioni',
                      onSelected: (v) =>
                          v == 'ripristina' ? _restore(e) : _delete(e),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'ripristina',
                          child: Text('Ripristina'),
                        ),
                        PopupMenuItem(
                          value: 'elimina',
                          child: Text('Elimina per sempre'),
                        ),
                      ],
                    ),
                    onTap: () => _restore(e),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String _left(int days) => switch (days) {
    0 => 'cancellato oggi',
    1 => 'resta 1 giorno',
    _ => 'restano $days giorni',
  };
}
