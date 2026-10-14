import 'package:flutter/material.dart';
import '../../../core/constants/text_limits.dart';

/// Dialogo con un campo di testo. Restituisce il testo confermato o null.
/// [validator] restituisce un messaggio d'errore o null se valido.
Future<String?> showTextEditDialog(
  BuildContext context, {
  required String title,
  required String initialValue,
  String? label,
  String? hint,
  String? helper,
  String? Function(String value)? validator,
  List<({String label, String value})> presets = const [],
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextEditDialog(
      title: title,
      initialValue: initialValue,
      label: label,
      hint: hint,
      helper: helper,
      validator: validator,
      presets: presets,
    ),
  );
}

class _TextEditDialog extends StatefulWidget {
  const _TextEditDialog({
    required this.title,
    required this.initialValue,
    this.label,
    this.hint,
    this.helper,
    this.validator,
    this.presets = const [],
  });

  final String title;
  final String initialValue;
  final String? label;
  final String? hint;
  final String? helper;
  final String? Function(String value)? validator;
  final List<({String label, String value})> presets;

  @override
  State<_TextEditDialog> createState() => _TextEditDialogState();
}

class _TextEditDialogState extends State<_TextEditDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initialValue);
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    final err = widget.validator?.call(v);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              inputFormatters: TextLimits.max(TextLimits.url),
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: widget.hint,
                helperText: widget.helper,
                helperMaxLines: 4,
                errorText: _error,
                errorMaxLines: 3,
              ),
              onSubmitted: (_) => _submit(),
            ),
            for (final p in widget.presets)
              TextButton(
                onPressed: () => setState(() {
                  _ctrl.text = p.value;
                  _error = null;
                }),
                child: Text(p.label),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
        FilledButton(onPressed: _submit, child: const Text('Salva')),
      ],
    );
  }
}
