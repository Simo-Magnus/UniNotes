import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../core/services/msix_paths.dart';
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
///
/// Windows: share_plus apre la finestra «Condividi» di Windows
/// (DataTransferManager, anche per l'app non pacchettizzata: non serve
/// pubblicarla né un MSIX) ma risponde sempre «non disponibile», anche
/// quando la finestra si è aperta. Prima l'app lo prendeva per un errore e
/// apriva subito Esplora file con il file selezionato: la finestra
/// «Condividi», che si chiude appena perde il focus, spariva all'istante e
/// sembrava che il tasto non funzionasse. Ora su Windows la risposta
/// «non disponibile» vale come finestra aperta ([systemShare]); il titolo,
/// obbligatorio per Windows, c'è sempre e i percorsi sono assoluti con «\»
/// (StorageFile non accetta altro).
Future<void> shareFiles(
  BuildContext context,
  List<File> files, {
  String? subject,
}) async {
  if (files.isEmpty) return;
  final shown = await systemShare(
    context,
    ShareParams(
      // Microsoft Store: percorsi veri per le app che ricevono il file
      files: [for (final f in files) XFile(sharePath(f.path))],
      subject: subject,
      title: subject ?? p.basename(files.first.path),
    ),
  );
  if (shown || !context.mounted) return;
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

/// Percorso da passare alle altre app: quello vero fuori dal pacchetto
/// MSIX e, su Windows, assoluto con «\».
String sharePath(String path, {bool? windows}) {
  final out = MsixPaths.forOtherApps(path);
  if (!(windows ?? Platform.isWindows)) return out;
  return p.windows.normalize(p.windows.absolute(out.replaceAll('/', r'\')));
}

/// Apre il menu di condivisione del sistema con [params] (posizione del
/// pulsante di [context]). true se il menu si è aperto (su Windows: se è
/// stato chiesto senza errori, perché il plugin risponde sempre «non
/// disponibile»); false se il sistema non lo offre e serve un ripiego.
///
/// Su Windows 10 1809 e successivi si chiama direttamente il canale nativo
/// di share_plus ([_windowsShare]): il plugin ricorda testo, indirizzo e
/// file della condivisione precedente quando non arrivano (es. un file
/// condiviso dopo un testo si portava dietro il testo), e share_plus non
/// permette di mandarli vuoti. Così ogni condivisione manda tutti i campi,
/// con il titolo obbligatorio.
Future<bool> systemShare(
  BuildContext context,
  ShareParams params, {
  bool? windows,
  int? windowsBuild,
}) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box != null && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  final win = windows ?? Platform.isWindows;
  try {
    if (win && (windowsBuild ?? currentWindowsBuild() ?? 0) >= 17763) {
      await _windowsShare.invokeMethod<String>('share', {
        'text': params.text ?? params.uri?.toString() ?? '',
        'subject': params.subject ?? '',
        'title': params.title ?? params.subject ?? 'Condividi da UniNotes',
        'uri': '',
        'paths': [for (final f in params.files ?? const <XFile>[]) f.path],
        'mimeTypes': [
          for (final f in params.files ?? const <XFile>[])
            f.mimeType ?? 'application/octet-stream',
        ],
      });
      return true;
    }
    final r = await SharePlus.instance.share(
      ShareParams(
        text: params.text,
        subject: params.subject,
        title: params.title,
        uri: params.uri,
        files: params.files,
        sharePositionOrigin: origin ?? params.sharePositionOrigin,
      ),
    );
    // Windows prima della 1809: share_plus apre un'email (solo testo)
    return win || r.status != ShareResultStatus.unavailable;
  } catch (_) {
    // es. Windows prima della 1809 con dei file, Linux con dei file
    return false;
  }
}

/// Canale nativo di share_plus su Windows (DataTransferManager).
const _windowsShare = MethodChannel('dev.fluttercommunity.plus/share');

/// Numero di build di Windows (es. 26100), null se non si legge.
int? currentWindowsBuild() {
  if (!Platform.isWindows) return null;
  final m = RegExp(r'Build (\d+)').firstMatch(Platform.operatingSystemVersion);
  return m == null ? null : int.tryParse(m.group(1)!);
}
