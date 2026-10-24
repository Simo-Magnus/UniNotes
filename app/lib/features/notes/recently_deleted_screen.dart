import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/undo_snack_bar.dart';
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

  /// Dopo un'operazione (anche a schermata già chiusa: niente setState).
  void _reload() {
    if (!mounted) return;
    setState(() {
      _items = _s.trash.list();
    });
  }

  /// Elementi in lavorazione (doppio tocco su «Ripristina»).
  final Set<String> _busy = {};

  Future<void> _restore(TrashEntry e) async {
    if (!_busy.add(e.id)) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final files = await _s.trash.restore(e);
      _s.revision.bump();
      if (messenger != null && messenger.mounted) {
        if (files.isEmpty) {
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(content: Text('Niente da ripristinare.')),
            );
        } else {
          showUndoSnackBar(
            context,
            '«${e.title}» ripristinato.',
            messenger: messenger,
            undoneMessage: '«${e.title}» di nuovo in «Eliminati di recente».',
            onUndo: () => _undoRestore(e, files),
          );
        }
      }
    } catch (err) {
      if (mounted) showSnack(context, 'Ripristino non riuscito: $err');
    } finally {
      _busy.remove(e.id);
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
    try {
      await _s.trash.deleteForever(e);
    } catch (err) {
      if (mounted) showSnack(context, 'Eliminazione non riuscita: $err');
    }
    _reload();
  }

  Future<void> _empty(List<TrashEntry> all) async {
    if (!await _confirm(
      'Svuotare «Eliminati di recente»?',
      'Tutti i file vengono cancellati subito e non si potranno recuperare.',
    )) {
      return;
    }
    var failed = 0;
    for (final e in all) {
      try {
        await _s.trash.deleteForever(e);
      } catch (_) {
        failed++;
      }
    }
    if (failed > 0 && mounted) {
      showSnack(context, 'Alcuni file non si sono potuti cancellare.');
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
              : (snap.hasError
                    // cestino illeggibile: si dice, non «nessun file»
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Impossibile leggere «Eliminati di recente»: '
                            '${snap.error}',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : _list(context, items)),
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
          // «Svuota» grande, sopra l'elemento eliminato per ultimo: colori
          // di errore del tema (fondo errorContainer, testo
          // onErrorContainer: contrasto AA in tema chiaro e scuro; prima il
          // testo rosso sul fondo tonale azzurro non si leggeva)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: FilledButton.icon(
              key: const Key('trash-empty'),
              style: emptyTrashButtonStyle(theme),
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

/// Stile di «Svuota»: pulsante pieno come gli altri dell'app, con i colori
/// di errore del tema (fondo [ColorScheme.errorContainer], testo e icona
/// [ColorScheme.onErrorContainer]) e un bordo sottile [ColorScheme.error]
/// che lo distingue dal fondo della pagina.
ButtonStyle emptyTrashButtonStyle(ThemeData theme) {
  final scheme = theme.colorScheme;
  return FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(52),
    backgroundColor: scheme.errorContainer,
    foregroundColor: scheme.onErrorContainer,
    iconColor: scheme.onErrorContainer,
    side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
    textStyle: theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
  );
}
