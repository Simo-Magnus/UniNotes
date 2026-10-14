import 'dart:io';

import 'package:path/path.dart' as p;

/// Cartelle temporanee dell'app con copie di dati personali (appunti uniti
/// per l'AI, file estratti dal lettore). Si svuotano all'avvio e con
/// «Elimina tutti i dati».
const kTempFolders = [
  'UniNotes AI',
  'University Notes AI',
  'university_notes_reader',
];

Future<void> clearTempFiles() async {
  for (final name in kTempFolders) {
    try {
      final d = Directory(p.join(Directory.systemTemp.path, name));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // file in uso: si riprova al prossimo avvio
    }
  }
}
