import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/services/external_launcher.dart';
import '../../widgets/common.dart';
import '../reader/reader_screen.dart';
import 'exam_ui.dart';
import '../../core/constants/text_limits.dart';

/// Editor della lista "Materiali da studiare": righe di testo libero oppure
/// percorsi locali scelti con il selettore file.
class StudyMaterialsEditor extends StatefulWidget {
  const StudyMaterialsEditor({
    super.key,
    required this.items,
    required this.onChanged,
    this.showTitle = true,
  });

  final List<String> items;
  final ValueChanged<List<String>> onChanged;

  /// Titolo «Materiali da studiare» sopra la lista (no nel dettaglio della
  /// prova, dove c'è già l'intestazione della sezione).
  final bool showTitle;

  @override
  State<StudyMaterialsEditor> createState() => _StudyMaterialsEditorState();
}

class _StudyMaterialsEditorState extends State<StudyMaterialsEditor> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _addText() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    widget.onChanged([...widget.items, t]);
    _ctrl.clear();
  }

  Future<void> _pickFiles() async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Scegli i materiali da studiare',
      );
      final paths = files.map((f) => f.path).whereType<String>().toList();
      if (paths.isEmpty) return;
      widget.onChanged([
        ...widget.items,
        ...paths.where((p) => !widget.items.contains(p)),
      ]);
    } catch (e) {
      if (mounted) showSnack(context, 'Impossibile scegliere i file: $e');
    }
  }

  void _remove(int i) {
    final list = [...widget.items]..removeAt(i);
    widget.onChanged(list);
  }

  void _move(int from, int to) {
    final list = [...widget.items];
    final item = list.removeAt(from);
    list.insert(to, item);
    widget.onChanged(list);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTitle) ...[
          Text('Materiali da studiare', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
        ],
        for (var i = 0; i < widget.items.length; i++)
          _MaterialRow(
            text: widget.items[i],
            onRemove: () => _remove(i),
            onUp: i > 0 ? () => _move(i, i - 1) : null,
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _ctrl,
          inputFormatters: TextLimits.max(TextLimits.materialLine),
          decoration: const InputDecoration(
            labelText: 'Aggiungi materiale',
            hintText: 'es. Lezioni 1-8 (slide): premi Invio per aggiungerlo',
            isDense: true,
          ),
          onSubmitted: (_) => _addText(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _pickFiles,
            icon: const Icon(Icons.attach_file),
            label: const Text('Scegli file dal dispositivo'),
          ),
        ),
      ],
    );
  }
}

class _MaterialRow extends StatelessWidget {
  const _MaterialRow({required this.text, required this.onRemove, this.onUp});
  final String text;
  final VoidCallback onRemove;
  final VoidCallback? onUp;

  @override
  Widget build(BuildContext context) {
    final isPath = looksLikePath(text);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(isPath ? Icons.insert_drive_file_outlined : Icons.notes),
      title: Text(isPath ? pathBaseName(text) : text),
      subtitle: isPath
          ? Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      onTap: isPath ? () => openStudyFile(context, text) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onUp != null)
            IconButton(
              tooltip: 'Sposta su',
              onPressed: onUp,
              icon: const Icon(Icons.arrow_upward),
            ),
          IconButton(
            tooltip: 'Rimuovi',
            onPressed: onRemove,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// Apre un file dei materiali: nel lettore dell'app (che legge PDF, Office,
/// ODF, EPUB, immagini, audio e video…; per gli altri formati propone «Apri
/// con…»); se il file non c'è più, il messaggio del sistema.
Future<void> openStudyFile(BuildContext context, String path) async {
  if (!await File(path).exists()) {
    final r = await ExternalLauncher.openPath(path);
    if (context.mounted) showLaunchResult(context, r);
    return;
  }
  if (context.mounted) {
    await openInReader(context, path, title: pathBaseName(path));
  }
}

/// Lista in sola lettura dei materiali, con apertura dei percorsi locali.
/// Con [onEdit] le righe di testo aprono la modifica della lista (i file si
/// aprono comunque toccandoli).
class StudyMaterialsList extends StatelessWidget {
  const StudyMaterialsList(this.items, {super.key, this.onEdit});
  final List<String> items;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in items)
          if (looksLikePath(m))
            ListTile(
              dense: true,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(pathBaseName(m)),
              subtitle: Text(m, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => openStudyFile(context, m),
            )
          else
            ListTile(
              dense: true,
              leading: const Icon(Icons.notes),
              title: Text(m),
              onTap: onEdit,
            ),
        if (onEdit != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.add),
            title: const Text('Aggiungi o togli materiali'),
            onTap: onEdit,
          ),
      ],
    );
  }
}
