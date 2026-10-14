import 'package:flutter/material.dart';

import '../../core/constants/text_limits.dart';

/// Nome e nota scelti nel dialogo «Nota».
typedef NameNote = ({String name, String note});

/// «Nota» di un argomento o di un modulo: il nome (per correggerlo) e la
/// nota. Due soli pulsanti: Annulla e Salva. Restituisce null se annullato
/// o se il nome è vuoto; la nota vuota toglie la nota.
Future<NameNote?> showNoteDialog(
  BuildContext context, {
  required String title,
  required String name,
  String? note,
}) => showDialog<NameNote>(
  context: context,
  builder: (_) => _NoteDialog(title: title, name: name, note: note ?? ''),
);

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({
    required this.title,
    required this.name,
    required this.note,
  });

  final String title;
  final String name;
  final String note;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final _note = TextEditingController(text: widget.note);

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop<NameNote>(context, (name: name, note: _note.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: TextLimits.max(TextLimits.topicName),
                decoration: const InputDecoration(labelText: 'Nome'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('note-field'),
                controller: _note,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                maxLength: TextLimits.notes,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Nota',
                  alignLabelWithHint: true,
                  hintText: 'Cosa ricordare, dubbi, pagine da rivedere…',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(onPressed: _save, child: const Text('Salva')),
      ],
    );
  }
}
