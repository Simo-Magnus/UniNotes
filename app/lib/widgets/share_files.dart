import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../features/notes/ai_request_dialog.dart'
    show copyFilesToClipboard, revealInFolder;
import 'common.dart';

/// «Condividi» per uno o più file, da tutte le schermate:
/// - menu di condivisione del sistema (telefono, Mac, Windows 10/11), con la
///   posizione del pulsante (obbligatoria su iPad e Mac, senza il menu non si
///   apre);
/// - se il sistema non lo offre o fallisce (es. Linux, Windows vecchi): il
///   file viene copiato negli appunti di sistema, da incollare dove si vuole,
///   e mostrato nella sua cartella.
Future<void> shareFiles(
  BuildContext context,
  List<File> files, {
  String? subject,
}) async {
  if (files.isEmpty) return;
  final box = context.findRenderObject() as RenderBox?;
  final origin = box != null && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  try {
    final r = await SharePlus.instance.share(
      ShareParams(
        files: [for (final f in files) XFile(f.path)],
        subject: subject,
        sharePositionOrigin: origin,
      ),
    );
    if (r.status != ShareResultStatus.unavailable) return;
  } catch (_) {
    // si passa al ripiego qui sotto
  }
  if (!context.mounted) return;
  if (Platform.isAndroid || Platform.isIOS) {
    showSnack(context, 'Condivisione non disponibile su questo dispositivo.');
    return;
  }
  final copied = await copyFilesToClipboard(files);
  if (!context.mounted) return;
  showSnack(
    context,
    copied
        ? 'File copiato negli appunti: incollalo (Ctrl+V / ⌘V) dove vuoi condividerlo.'
        : 'Condivisione non disponibile: ecco il file nella sua cartella.',
  );
  await revealInFolder(context, files.first.path);
}
