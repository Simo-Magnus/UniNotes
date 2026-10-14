import 'package:flutter/material.dart';

import '../core/services/external_launcher.dart';
import 'common.dart';

/// true se il testo sembra un percorso locale (Windows, UNC, Unix, file://).
bool looksLikeLocalPath(String s) {
  final t = s.trim();
  return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(t) ||
      t.startsWith(r'\\') ||
      t.startsWith('/') ||
      t.startsWith('~/') ||
      t.startsWith('file://');
}

/// Percorso apribile da un elemento di "materiali da studiare".
String localPathOf(String s) {
  final t = s.trim();
  if (t.startsWith('file://')) {
    try {
      return Uri.parse(t).toFilePath();
    } catch (_) {
      return t;
    }
  }
  return t;
}

/// Ultimo segmento del percorso (nome del file o della cartella).
String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// Voce di "Materiali da studiare": se è un percorso locale è cliccabile e
/// apre il file (o la cartella) con l'app di sistema.
class StudyMaterialTile extends StatelessWidget {
  const StudyMaterialTile(this.material, {super.key, this.dense = true});

  final String material;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (!looksLikeLocalPath(material)) {
      return ListTile(
        dense: dense,
        visualDensity: VisualDensity.compact,
        leading: const Icon(Icons.check_box_outline_blank, size: 20),
        title: Text(material),
      );
    }
    final path = localPathOf(material);
    return ListTile(
      dense: dense,
      visualDensity: VisualDensity.compact,
      leading: Icon(
        Icons.insert_drive_file_outlined,
        size: 20,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(_basename(path)),
      subtitle: Text(path, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () async {
        final r = await ExternalLauncher.openPath(path);
        if (context.mounted) showLaunchResult(context, r);
      },
    );
  }
}
