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

/// Cartelle di lavoro create ogni volta con un nome casuale (conversioni
/// per la trascrizione, pezzi di audio, forma d'onda). Si cancellano da sole
/// a fine lavoro; se l'app si chiude di colpo o il telefono si spegne
/// restano nella cartella temporanea e, con registrazioni lunghe (centinaia
/// di MB di audio non compresso ciascuna), la riempiono a ogni chiusura
/// improvvisa. Non c'è `uninotes_cestino_`: ha dentro l'audio di una
/// registrazione eliminata a metà, che non va mai buttato.
const kTempWorkPrefixes = [
  'whisper_',
  'whisper_chunks_',
  'whisper_live_',
  'parakeet_',
  'uninotes_live_',
  'uninotes_onda_',
  'uninotes_taglio_',
];

/// Le cartelle di lavoro più vecchie di questo tempo sono rimaste da una
/// chiusura improvvisa (nessun lavoro dura così a lungo).
const kStaleTempAge = Duration(hours: 6);

/// Cartelle temporanee con l'audio di una registrazione eliminata a metà
/// (recording_save.dart): mai tolte dalla pulizia di ogni avvio, solo da
/// «Elimina tutti i dati» con le registrazioni ([clearTempFiles] con
/// `allWork`).
const kTempTrashPrefix = 'uninotes_cestino_';

/// Svuota le cartelle temporanee dell'app ([kTempFolders]) e le cartelle di
/// lavoro rimaste da più di [kStaleTempAge]. Con [allWork] («Elimina tutti
/// i dati» con le registrazioni) anche quelle recenti e quelle del cestino
/// ([kTempTrashPrefix]): contengono l'audio delle lezioni e sul PC la
/// cartella temporanea è quella di tutto il profilo, che resta dopo che
/// l'app si chiude.
Future<void> clearTempFiles({
  Directory? temp,
  DateTime Function()? now,
  bool allWork = false,
}) async {
  final root = temp ?? Directory.systemTemp;
  for (final name in kTempFolders) {
    try {
      final d = Directory(p.join(root.path, name));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // file in uso: si riprova al prossimo avvio
    }
  }
  final cutoff = (now ?? DateTime.now)().subtract(kStaleTempAge);
  try {
    await for (final e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      final name = p.basename(e.path);
      final trash = allWork && name.startsWith(kTempTrashPrefix);
      if (!trash && !kTempWorkPrefixes.any(name.startsWith)) continue;
      try {
        if (!allWork && (await e.stat()).modified.isAfter(cutoff)) continue;
        await e.delete(recursive: true);
      } catch (_) {
        // in uso o già tolta: si riprova al prossimo avvio
      }
    }
  } catch (_) {
    // cartella temporanea non leggibile: niente pulizia
  }
}
