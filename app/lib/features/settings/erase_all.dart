import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/services/temp_files.dart';

/// Impostazioni → Privacy → «Elimina tutti i dati»: cancella dal dispositivo
/// percorso, voti, libri, cache del database, modelli Whisper e accesso a
/// OneDrive e Google Drive; a scelta anche appunti e registrazioni. Poi l'app si
/// chiude e al prossimo avvio riparte dalla scelta dell'università.
Future<void> eraseAllData(BuildContext context) async {
  final s = context.read<AppServices>();
  final notesDir = await s.notes.root();
  if (!context.mounted) return;
  var withNotes = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text('Eliminare tutti i dati?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Si cancellano da questo dispositivo università e corso scelti, '
              'voti, esami, libri, sessioni di studio, modelli Whisper e '
              'l\'accesso a OneDrive e Google Drive.\n'
              'I file caricati su OneDrive e Google Drive rimangono lì.',
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: withNotes,
              onChanged: (v) => setState(() => withNotes = v ?? false),
              title: const Text('Elimina anche appunti e registrazioni'),
              subtitle: Text(notesDir.path),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Elimina tutto'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return;

  for (final c in s.clouds) {
    c.stopAutoSync();
  }
  // una sincronizzazione in corso finisce prima di cancellare (al massimo 30 s)
  for (var i = 0; i < 60 && s.clouds.any((c) => c.syncing); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  // notifiche pianificate, eventi dell'app nel calendario, widget
  try {
    await s.reminders.eraseAll();
  } catch (_) {}
  await s.database.close();
  await clearTempFiles();
  try {
    await const FlutterSecureStorage().deleteAll();
  } catch (_) {}
  for (final dir in [
    await getApplicationSupportDirectory(),
    if (withNotes) notesDir,
  ]) {
    await _clear(dir);
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      title: const Text('Dati eliminati'),
      content: Text(
        Platform.isIOS
            ? 'Chiudi l\'app e riaprila per ricominciare.'
            : 'L\'app ora si chiude: riaprila per ricominciare.',
      ),
      actions: [
        if (!Platform.isIOS)
          FilledButton(onPressed: () => exit(0), child: const Text('Chiudi')),
      ],
    ),
  );
}

/// Svuota [dir] (la cartella resta). Un file bloccato non ferma gli altri.
Future<void> _clear(Directory dir) async {
  if (!await dir.exists()) return;
  await for (final e in dir.list(followLinks: false)) {
    try {
      await e.delete(recursive: true);
    } catch (_) {}
  }
}
