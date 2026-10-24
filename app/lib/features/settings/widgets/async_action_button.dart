import 'package:flutter/material.dart';

import '../../../core/feedback/app_modals.dart';

/// Pulsante per operazioni asincrone: mostra un indicatore durante
/// l'esecuzione, impedisce doppi tocchi e mostra gli errori in un dialogo.
class AsyncActionButton extends StatefulWidget {
  const AsyncActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.filled = false,
    this.errorTitle = 'Operazione non riuscita',
  });

  final String label;
  final IconData icon;
  final Future<void> Function()? onPressed;
  final bool filled;
  final String errorTitle;

  @override
  State<AsyncActionButton> createState() => _AsyncActionButtonState();
}

class _AsyncActionButtonState extends State<AsyncActionButton> {
  bool _busy = false;

  Future<void> _run() async {
    // due tocchi nello stesso fotogramma (prima che il pulsante si spenga)
    // farebbero partire l'operazione due volte
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onPressed!();
    } catch (e) {
      if (mounted) await showErrorDialog(context, widget.errorTitle, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = _busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(widget.icon);
    final onPressed = _busy || widget.onPressed == null ? null : _run;
    // Impostazioni: nessuna azione arancione (non c'è un'azione principale
    // della schermata); "filled" evidenzia l'icona in azzurro.
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: widget.filled
          ? IconTheme.merge(
              data: IconThemeData(color: Theme.of(context).colorScheme.primary),
              child: icon,
            )
          : icon,
      label: Text(widget.label),
    );
  }
}

Future<void> showErrorDialog(
  BuildContext context,
  String title,
  Object error,
) => showAppDialog<void>(
  context: context,
  builder: (c) => AlertDialog(
    icon: const Icon(Icons.error_outline),
    title: Text(title),
    content: SingleChildScrollView(child: SelectableText(error.toString())),
    actions: [
      FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
    ],
  ),
);

/// Disposizione dei pulsanti di una sezione (vanno a capo su schermi stretti).
class ActionWrap extends StatelessWidget {
  const ActionWrap({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Wrap(spacing: 8, runSpacing: 8, children: children),
  );
}
