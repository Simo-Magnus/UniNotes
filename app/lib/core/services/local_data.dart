import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'windows_tools.dart';

/// Dove l'app tiene i suoi dati su ogni piattaforma, e come si eliminano.
///
/// - Database SQLite, libri, materiali, allegati, modelli Whisper, dati
///   dell'ateneo scaricati (`database_cache`), stato della sincronizzazione,
///   evidenziazioni, registrazione in corso: cartella di supporto dell'app
///   (Windows `%APPDATA%\UniNotes\UniNotes`; Android `files/`; iOS e macOS
///   `Library/Application Support` nel contenitore dell'app).
/// - Preferenze (shared_preferences): Windows `shared_preferences.json` nella
///   stessa cartella; Android `shared_prefs/`; iOS e macOS UserDefaults.
/// - Credenziali (refresh token di OneDrive, Google Drive, Outlook):
///   flutter_secure_storage. Windows: file cifrato nella cartella di supporto
///   più una chiave nel Gestore credenziali; Android: Keystore; iOS e macOS:
///   portachiavi, che **resta** anche dopo la disinstallazione.
/// - Cache: Windows `%LOCALAPPDATA%\UniNotes\UniNotes`; altrove la cache
///   dell'app. File temporanei: cartelle in [kTempFolders] (temp_files.dart).
/// - Appunti e registrazioni: Windows `Documenti\UniNotes\Corsi` (cartella
///   condivisa, resta dopo la disinstallazione se l'utente non la elimina);
///   altrove la cartella documenti dell'app, dentro il suo contenitore.
/// - Windows, build del Microsoft Store (MSIX): stessi percorsi per l'app,
///   ma Windows scrive i file nuovi di AppData nella cartella del pacchetto
///   `%LOCALAPPDATA%\Packages\<famiglia>\LocalCache\…` (vedi MsixPaths) e la
///   elimina alla disinstallazione; Documenti\UniNotes resta dov'è.
class LocalData {
  LocalData._();

  /// Parte comune dei nomi delle voci di flutter_secure_storage nel Gestore
  /// credenziali di Windows (`<nome dell'eseguibile>_<questo>`).
  static const windowsCredentialMark = 'VGhpcyBpcyB0aGUgcHJlZml4IGZv_';

  /// Nomi dell'eseguibile di Windows (attuale e precedente).
  static const windowsBinaryNames = ['uninotes', 'university_notes'];

  /// Cache dell'app (si svuotano con ogni eliminazione). Sul PC la cartella
  /// temporanea è quella di sistema, condivisa con gli altri programmi: lì
  /// si tolgono solo le cartelle dell'app (clearTempFiles).
  static Future<List<Directory>> cacheDirs() async {
    final out = <Directory>[];
    try {
      out.add(await getApplicationCacheDirectory());
    } catch (_) {}
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      try {
        out.add(await getTemporaryDirectory());
      } catch (_) {}
    }
    return out;
  }

  /// Elimina tutte le credenziali dell'app salvate con flutter_secure_storage
  /// (portachiavi, Keystore, file cifrato) e, su Windows, anche le voci del
  /// Gestore credenziali che il pacchetto lascia (la sua chiave di
  /// cifratura). Gli errori si ignorano.
  static Future<void> wipeSecrets() async {
    try {
      await const FlutterSecureStorage().deleteAll();
    } catch (_) {}
    if (Platform.isWindows) await _wipeWindowsCredentials();
  }

  /// Voci del Gestore credenziali scritte da flutter_secure_storage per
  /// questa app, lette da `cmdkey /list`.
  static List<String> windowsCredentialTargets(String cmdkeyList) {
    final out = <String>{};
    for (final m in RegExp(r'target=(\S+)').allMatches(cmdkeyList)) {
      final t = m[1]!;
      if (!t.contains(windowsCredentialMark)) continue;
      final name = t.startsWith('key_') ? t.substring(4) : t;
      if (windowsBinaryNames.any((b) => name.startsWith('${b}_'))) out.add(t);
    }
    return out.toList();
  }

  static Future<void> _wipeWindowsCredentials() async {
    final targets = <String>{
      // chiave AES del pacchetto: deleteAll non la toglie
      for (final b in windowsBinaryNames) 'key_${b}_$windowsCredentialMark',
    };
    try {
      final r = await Process.run(WindowsTools.cmdkey, ['/list']);
      targets.addAll(windowsCredentialTargets('${r.stdout}'));
    } catch (_) {}
    for (final t in targets) {
      try {
        await Process.run(WindowsTools.cmdkey, ['/delete:$t']);
      } catch (_) {}
    }
  }

  /// Svuota [dir] (la cartella resta). Un file bloccato non ferma gli altri.
  static Future<void> clearDirectory(Directory dir) async {
    if (!await dir.exists()) return;
    try {
      await for (final e in dir.list(followLinks: false)) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } on FileSystemException {
      // cartella sparita o illeggibile a metà (disco scollegato): quanto si
      // è potuto togliere basta, il resto si vedrà al prossimo controllo
    }
  }

  /// Elimina [dir] con il contenuto (nessun errore se manca o è in uso).
  static Future<void> deleteDirectory(Directory dir) async {
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      await clearDirectory(dir);
    }
  }

  /// Spazio occupato da [e] (file o cartella con il contenuto), in byte.
  static Future<int> sizeOf(FileSystemEntity e) async {
    try {
      if (e is File) return await e.exists() ? await e.length() : 0;
      if (e is! Directory || !await e.exists()) return 0;
      var total = 0;
      await for (final f in e.list(recursive: true, followLinks: false)) {
        if (f is File) {
          try {
            total += await f.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Elimina la cartella degli appunti [notesDir] e, se poi resta vuota, la
  /// cartella dell'app che la contiene (`Documenti\UniNotes` sul PC).
  static Future<void> deleteNotes(Directory notesDir) async {
    await clearDirectory(notesDir);
    try {
      await notesDir.delete(recursive: true);
    } catch (_) {}
    final parent = notesDir.parent;
    if (!notesParents.contains(p.basename(parent.path))) return;
    try {
      if (await parent.list().isEmpty) await parent.delete();
    } catch (_) {}
  }

  /// Nomi della cartella dell'app in Documenti sul PC (attuale e precedente).
  static const notesParents = {'UniNotes', 'University Notes'};

  /// [dir] contiene almeno un file (anche nelle sottocartelle).
  static Future<bool> hasFiles(Directory dir) async {
    try {
      if (!await dir.exists()) return false;
      return await dir
          .list(recursive: true, followLinks: false)
          .any((e) => e is File);
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------- installazione precedente

  /// Cartelle condivise che una nuova installazione rileggerebbe da sola:
  /// sul PC gli appunti nelle cartelle predefinite in Documenti (restano se
  /// alla disinstallazione l'utente li tiene). Sul telefono e sul Mac gli
  /// appunti sono nel contenitore dell'app: nessuna.
  static Future<List<Directory>> sharedNotesDirs() async {
    if (!Platform.isWindows) return const [];
    final docs = (await getApplicationDocumentsDirectory()).path;
    return [
      for (final name in notesParents) Directory(p.join(docs, name, 'Corsi')),
    ];
  }

  /// Fra [candidates], le cartelle che esistono e contengono file.
  static Future<List<Directory>> withFiles(List<Directory> candidates) async {
    final out = <Directory>[];
    for (final d in candidates) {
      if (await hasFiles(d)) out.add(d);
    }
    return out;
  }

  /// Suffisso delle cartelle messe da parte con «Ignora».
  static const ignoredSuffix = ' (installazione precedente)';

  /// «Ignora» i dati di un'installazione precedente: ogni cartella si
  /// rinomina accanto a sé (es. `Corsi (installazione precedente)`), così
  /// l'app riparte vuota e i file restano all'utente. Restituisce le
  /// cartelle che non si sono potute spostare (file in uso).
  static Future<List<Directory>> setAside(List<Directory> dirs) async {
    final failed = <Directory>[];
    for (final d in dirs) {
      if (!await d.exists()) continue;
      var target = '${d.path}$ignoredSuffix';
      for (
        var i = 2;
        await FileSystemEntity.type(target) != FileSystemEntityType.notFound;
        i++
      ) {
        target = '${d.path} (installazione precedente $i)';
      }
      try {
        await d.rename(target);
      } catch (_) {
        failed.add(d);
      }
    }
    return failed;
  }
}
