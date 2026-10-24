import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/feedback/app_modals.dart';
import '../../core/services/app_services.dart';

/// Impostazione «Non chiedere più» della conferma di «Elimina libri non
/// salvati» (le chiavi `dont_ask_` si ripristinano tutte da Impostazioni →
/// «Ripristina le domande»).
const String kDontAskDeleteUnsavedBooksKey = 'dont_ask_delete_unsaved_books';

/// Conferma di «Elimina libri non salvati» per l'insegnamento [course]
/// ([count] libri): Annulla ed Elimina, più la casella «Non chiedere più».
/// Con la casella spuntata le volte successive si elimina subito.
Future<bool> confirmDeleteUnsavedBooks(
  BuildContext context, {
  required String course,
  required int count,
}) async {
  final settings = context.read<AppServices>().settings;
  try {
    if (await settings.get(kDontAskDeleteUnsavedBooksKey) == '1') return true;
  } catch (_) {
    // impostazioni non leggibili: si chiede
  }
  if (!context.mounted) return false;
  final what = count == 1
      ? 'Il libro proposto per «$course» senza la spunta verde viene tolto '
            'dai tuoi libri: lo ritrovi in «Libri rimossi», da dove puoi '
            'ripristinarlo.'
      : 'I $count libri proposti per «$course» senza la spunta verde '
            'vengono tolti dai tuoi libri: li ritrovi in «Libri rimossi», da '
            'dove puoi ripristinarli.';
  var dontAsk = false;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (c) {
      final scheme = Theme.of(c).colorScheme;
      return StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          scrollable: true,
          icon: Icon(Icons.delete_sweep_outlined, color: scheme.error),
          title: const Text('Elimina libri non salvati?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$what I libri salvati, gli obbligatori e quelli con un file '
                'restano; nessun file viene eliminato.',
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('unsaved-books-dont-ask'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                value: dontAsk,
                onChanged: (v) => setLocal(() => dontAsk = v ?? false),
                title: const Text('Non chiedere più'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              key: const Key('unsaved-books-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Elimina'),
            ),
          ],
        ),
      );
    },
  );
  if (ok == true && dontAsk) {
    try {
      await settings.set(kDontAskDeleteUnsavedBooksKey, '1');
    } catch (_) {}
  }
  return ok == true;
}
