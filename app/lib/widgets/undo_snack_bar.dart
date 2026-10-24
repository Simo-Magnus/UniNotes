import 'dart:async';

import 'package:flutter/material.dart';

import 'app_snack_action.dart';

/// Durata degli avvisi con «Annulla»: abbastanza per leggere e premere.
const kUndoSnackDuration = Duration(seconds: 6);

/// Avviso in basso per un'azione reversibile (eliminazione, spostamento nel
/// cestino, rimozione, archiviazione, cambio di stato) con il pulsante
/// «Annulla», che esegue [onUndo] e lo conferma con [undoneMessage].
///
/// [onCommit] (facoltativo) si esegue quando l'avviso si chiude senza
/// «Annulla» (tempo scaduto, nuovo avviso, chiusura): serve alle azioni
/// che completano qualcosa di non recuperabile solo alla fine (es. togliere
/// il file dal disco), così «Annulla» le ripristina per intero.
///
/// Il messaggero si prende subito: l'avviso funziona anche se la pagina che
/// l'ha mostrato nel frattempo si chiude. L'avviso si chiude da solo dopo
/// [kUndoSnackDuration] anche se ha un pulsante.
void showUndoSnackBar(
  BuildContext context,
  String message, {
  required FutureOr<void> Function() onUndo,
  FutureOr<void> Function()? onCommit,
  String undoneMessage = 'Modifica annullata.',
  ScaffoldMessengerState? messenger,
  Duration duration = kUndoSnackDuration,
}) => showUndoSnackBarOn(
  messenger ?? ScaffoldMessenger.maybeOf(context),
  message,
  onUndo: onUndo,
  onCommit: onCommit,
  undoneMessage: undoneMessage,
  duration: duration,
);

/// Come [showUndoSnackBar], con il messaggero già preso (azioni che
/// finiscono dopo la chiusura della pagina).
void showUndoSnackBarOn(
  ScaffoldMessengerState? m,
  String message, {
  required FutureOr<void> Function() onUndo,
  FutureOr<void> Function()? onCommit,
  String undoneMessage = 'Modifica annullata.',
  Duration duration = kUndoSnackDuration,
}) {
  if (m == null || !m.mounted) {
    // senza un posto dove mostrarlo: l'azione resta fatta
    if (onCommit != null) unawaited(Future.sync(onCommit));
    return;
  }
  var undone = false;
  m.hideCurrentSnackBar();
  final controller = m.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      persist: false,
      action: AppSnackBarAction(
        label: 'Annulla',
        onPressed: () async {
          undone = true;
          try {
            await onUndo();
            if (m.mounted) {
              m.showSnackBar(
                SnackBar(content: Text(undoneMessage), persist: false),
              );
            }
          } catch (e) {
            if (m.mounted) {
              m.showSnackBar(
                SnackBar(
                  content: Text('Annullamento non riuscito: $e'),
                  persist: false,
                ),
              );
            }
          }
        },
      ),
    ),
  );
  if (onCommit != null) {
    unawaited(
      controller.closed.then((reason) async {
        if (undone || reason == SnackBarClosedReason.action) return;
        try {
          await onCommit();
        } catch (_) {}
      }),
    );
  }
}
