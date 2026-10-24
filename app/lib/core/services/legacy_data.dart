import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';
import 'msix_paths.dart';

/// Dati lasciati da versioni precedenti in un'altra posizione.
///
/// Windows: fino al 10/10/2026 l'eseguibile si chiamava `university_notes` e
/// il suo file delle informazioni diceva «University Notes» come azienda e
/// come prodotto, quindi la cartella dei dati (database, libri, materiali,
/// modelli, cache, stato della sincronizzazione) era
/// `%APPDATA%\University Notes\University Notes`. Con il nome nuovo il
/// sistema dà all'app `%APPDATA%\UniNotes\UniNotes`: senza questo passaggio
/// chi aggiorna si ritrova l'app vuota (i dati restano sul disco, ma
/// l'app non li guarda più).
class LegacyData {
  LegacyData._();

  /// Nome di azienda e prodotto delle versioni precedenti.
  static const legacyName = 'University Notes';

  /// File che non si portano nella cartella nuova: le credenziali
  /// (`flutter_secure_storage.dat`) sono cifrate con una chiave che
  /// Windows tiene sotto il nome del vecchio eseguibile, nella cartella
  /// nuova non si potrebbero leggere (serve ricollegare gli account); le
  /// preferenze sono quelle del controllo dell'installazione, che riparte.
  static const notMoved = {
    'flutter_secure_storage.dat',
    'shared_preferences.json',
  };

  /// Cartella dei dati delle versioni precedenti accanto a [current] (la
  /// cartella dei dati di adesso, `…\UniNotes\UniNotes`).
  static Directory legacyDirFor(Directory current) => Directory(
    p.join(p.dirname(p.dirname(current.path)), legacyName, legacyName),
  );

  /// Porta nella cartella dei dati attuale quanto le versioni precedenti
  /// avevano nella loro, se il database di quella c'è e quello attuale no.
  /// Non unisce mai due database: se ce n'è già uno attuale non tocca nulla.
  /// Le voci si spostano (stesso disco: istantaneo, niente doppia copia di
  /// libri e modelli); se non si può si copia il file, e una cartella che non
  /// si sposta resta dov'è. Restituisce quante voci sono state portate; non
  /// lancia mai errori (si riprova al prossimo avvio).
  static Future<int> migrateWindowsSupportDir({
    Directory? current,
    Directory? legacy,
    bool? windows,
  }) async {
    try {
      if (!(windows ?? Platform.isWindows)) return 0;
      // nel pacchetto del Microsoft Store i percorsi sono virtualizzati e
      // quella versione non è mai uscita con il nome vecchio
      if (current == null && MsixPaths.packageFamilyName() != null) return 0;
      final now = current ?? await getApplicationSupportDirectory();
      final old = legacy ?? legacyDirFor(now);
      if (p.equals(old.path, now.path)) return 0;
      final oldDb = File(p.join(old.path, AppDatabase.fileName));
      if (!await oldDb.exists() || await oldDb.length() == 0) return 0;
      if (await File(p.join(now.path, AppDatabase.fileName)).exists()) return 0;
      await now.create(recursive: true);
      var moved = 0;
      // il database per ultimo: se l'app si chiude a metà, al riavvio manca
      // ancora e si riprende da dove era arrivata
      final entries = [await for (final e in old.list(followLinks: false)) e]
        ..sort((a, b) => _isDb(a).compareTo(_isDb(b)));
      for (final e in entries) {
        final name = p.basename(e.path);
        if (notMoved.contains(name)) continue;
        final target = p.join(now.path, name);
        if (await FileSystemEntity.type(target) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        try {
          await e.rename(target);
          moved++;
        } on FileSystemException {
          if (e is! File) continue;
          try {
            await e.copy(target);
            moved++;
          } on FileSystemException catch (err) {
            debugPrint('Dati precedenti non portati ($name): $err');
          }
        }
      }
      return moved;
    } catch (e) {
      debugPrint('Dati delle versioni precedenti non portati: $e');
      return 0;
    }
  }

  /// Il resto per primo, poi il giornale del database, infine il file del
  /// database (è quello che dice «già portato»).
  static int _isDb(FileSystemEntity e) {
    final name = p.basename(e.path);
    if (name == AppDatabase.fileName) return 2;
    return name.startsWith(AppDatabase.fileName) ? 1 : 0;
  }
}
