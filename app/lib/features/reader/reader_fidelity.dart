/// Resa parziale nel lettore: quando un file non si può mostrare come
/// nell'originale (formato a resa parziale, [ReaderFormat.limited], o parti
/// del singolo file non disegnate, [RDoc.limits]) all'apertura si chiede se
/// aprirlo con l'app di riferimento o vedere l'anteprima semplificata.
///
/// La scelta con «Non chiedere più» vale per l'estensione e si salva in
/// `dont_ask_reader_partial_<estensione>`: "external" (si apre subito con
/// l'app predefinita del sistema) o "preview" (si mostra l'anteprima senza
/// chiedere). Impostazioni → «Ripristina le domande» la cancella.
library;

import 'package:flutter/material.dart';

import '../../repositories/settings_repository.dart';
import 'reader_formats.dart';
import 'reader_loader.dart';

/// Prefisso delle scelte salvate (una per estensione).
const String kReaderPartialPrefix = 'dont_ask_reader_partial_';

/// Scelta per un file a resa parziale.
enum PartialViewChoice {
  /// «Apri con un'altra app».
  external,

  /// «Vedi anteprima semplificata».
  preview,
}

/// Cosa manca nella resa di [content] (formato [format]), o null se l'app
/// lo mostra per intero. Per i file che il lettore non mostra affatto
/// ([InfoContent]) non si chiede: la loro pagina ha già «Apri con…».
String? readerShortfall(ReaderFormat format, ReaderContent content) {
  if (content is InfoContent) return null;
  final parts = <String>[
    ?format.limited,
    if (content is DocContent) ...content.doc.limits,
  ];
  if (parts.isEmpty) return null;
  return _joinItalian(parts.toSet().toList());
}

String _joinItalian(List<String> parts) {
  if (parts.length == 1) return parts.first;
  return '${parts.sublist(0, parts.length - 1).join(', ')} e ${parts.last}';
}

String _key(ReaderFormat format) {
  final ext = format.extension.startsWith('.')
      ? format.extension.substring(1)
      : format.extension;
  return '$kReaderPartialPrefix${ext.isEmpty ? 'senza_estensione' : ext}';
}

/// Scelta salvata con «Non chiedere più» per il formato, o null.
Future<PartialViewChoice?> savedPartialChoice(
  SettingsRepository? settings,
  ReaderFormat format,
) async {
  if (settings == null) return null;
  try {
    return switch (await settings.get(_key(format))) {
      'external' => PartialViewChoice.external,
      'preview' => PartialViewChoice.preview,
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

/// Finestra «Anteprima semplificata»: due pulsanti («Vedi anteprima
/// semplificata», «Apri con un'altra app») e la casella «Non chiedere più»
/// per questo tipo di file. null se l'utente chiude la finestra (si resta
/// nell'anteprima).
Future<PartialViewChoice?> askPartialView(
  BuildContext context, {
  required ReaderFormat format,
  required String missing,
  SettingsRepository? settings,
}) async {
  var dontAsk = false;
  final choice = await showDialog<PartialViewChoice>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setLocal) => AlertDialog(
        icon: const Icon(Icons.preview_outlined),
        title: const Text('Anteprima semplificata'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'L\'app mostra questo file (${format.label}) in forma '
              'semplificata. Non mostra: $missing. Per vederlo com\'è, '
              'aprilo con la sua app di riferimento.',
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('reader-partial-dont-ask'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: dontAsk,
              onChanged: (v) => setLocal(() => dontAsk = v ?? false),
              title: const Text('Non chiedere più'),
              subtitle: Text('Per i file ${format.extension}'),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('reader-partial-preview'),
            onPressed: () => Navigator.pop(c, PartialViewChoice.preview),
            child: const Text('Vedi anteprima semplificata'),
          ),
          FilledButton(
            key: const Key('reader-partial-external'),
            onPressed: () => Navigator.pop(c, PartialViewChoice.external),
            child: const Text('Apri con un\'altra app'),
          ),
        ],
      ),
    ),
  );
  if (choice != null && dontAsk && settings != null) {
    try {
      await settings.set(
        _key(format),
        choice == PartialViewChoice.external ? 'external' : 'preview',
      );
    } catch (_) {}
  }
  return choice;
}
