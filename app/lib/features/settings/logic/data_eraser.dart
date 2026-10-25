import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/schema.dart';
import '../../../core/services/app_services.dart';
import '../../../core/services/book_library.dart';
import '../../../core/services/error_log.dart';
import '../../../core/services/local_data.dart';
import '../../../core/services/temp_files.dart';
import '../../cloud/cloud_drive_service.dart';
import '../../cloud/onedrive_service.dart';
import '../../notes/notes_store.dart';
import '../../notes/recycle_bin.dart';

/// Voci di «Elimina tutti i dati» → «Scegli cosa eliminare».
enum EraseItem {
  profile('Profilo, corso scelto e impostazioni'),
  database('Database: insegnamenti, esami, studio'),
  recordings('Registrazioni e trascrizioni'),
  notes('Appunti'),
  books('Libri e materiali scaricati'),
  whisper('Modelli di Whisper'),
  catalog('Dati dell\'ateneo scaricati (cache)'),
  onedrive('Cartelle UniNotes su OneDrive'),
  googleDrive('Cartelle UniNotes su Google Drive'),
  onenote('Blocchi o sezioni creati in OneNote'),
  calendar('Eventi aggiunti al calendario'),
  accounts('Account collegati (accessi salvati)');

  const EraseItem(this.label);
  final String label;
}

/// Una voce dell'elenco: se c'è qualcosa da eliminare, quanto occupa e dove.
class EraseOption {
  const EraseOption(
    this.item, {
    this.available = true,
    this.bytes,
    this.detail,
  });
  final EraseItem item;

  /// false = niente da eliminare (voce mostrata spenta, con il motivo).
  final bool available;

  /// Spazio occupato sul dispositivo (null = non calcolabile, es. il cloud).
  final int? bytes;

  /// Cartella, account o motivo.
  final String? detail;
}

/// Esito dell'eliminazione: le parti non riuscite (cloud, calendario).
class EraseReport {
  final List<String> problems = [];
  int cloudFolders = 0;
  bool calendarRemoved = false;
}

/// Cartelle degli appunti di un corso per le due voci «Registrazioni e
/// trascrizioni» e «Appunti».
const _recordingFolders = [
  NoteFolder.recordings,
  NoteFolder.transcripts,
  NoteFolder.summaries,
];
const _noteFolders = [NoteFolder.notes, NoteFolder.ai];

/// Eliminazione dei dati dell'app, unica per «Elimina tutti i dati»
/// (Impostazioni) e la schermata di disinstallazione di Windows
/// (`uninotes.exe --disinstalla`, avviato dal disinstallatore).
///
/// Fuori dal dispositivo tocca solo ciò che l'app ha creato: le sue
/// sottocartelle nella cartella scelta su OneDrive e Google Drive (nel
/// cestino del servizio) e gli eventi con il suo riferimento nel calendario.
/// OneNote si legge soltanto (permesso `Notes.Read`): l'app non vi crea
/// nulla, quindi lì non c'è niente da togliere.
class DataEraser {
  DataEraser(
    this.s, {
    Future<Directory> Function()? supportDir,
    Future<List<Directory>> Function()? cacheDirs,
    Future<void> Function()? wipeSecrets,
    Future<void> Function()? clearPrefs,
    Directory Function()? tempDir,
    this.syncWait = const Duration(seconds: 30),
  }) : _supportDir = supportDir ?? getApplicationSupportDirectory,
       _cacheDirs = cacheDirs ?? LocalData.cacheDirs,
       _wipeSecrets = wipeSecrets ?? LocalData.wipeSecrets,
       _clearPrefs = clearPrefs ?? _clearSharedPreferences,
       _tempDir = tempDir ?? (() => Directory.systemTemp);

  final AppServices s;
  final Future<Directory> Function() _supportDir;

  /// Cartella temporanea di sistema (nei test una cartella a parte).
  final Directory Function() _tempDir;
  final Future<List<Directory>> Function() _cacheDirs;
  final Future<void> Function() _wipeSecrets;
  final Future<void> Function() _clearPrefs;

  /// Attesa massima di una sincronizzazione in corso prima di cancellare.
  final Duration syncWait;

  static Future<void> _clearSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  /// Tutti i dati sul dispositivo (niente cloud né calendario): dati
  /// rimasti da un'installazione precedente. Con [sharedNotes] (PC) gli
  /// appunti in Documenti restano: per quelli c'è una domanda a parte.
  static Set<EraseItem> deviceItems({required bool sharedNotes}) => {
    EraseItem.profile,
    EraseItem.database,
    if (!sharedNotes) ...{EraseItem.recordings, EraseItem.notes},
    EraseItem.books,
    EraseItem.whisper,
    EraseItem.catalog,
    EraseItem.accounts,
  };

  /// Tabelle della voce «Profilo, corso scelto e impostazioni».
  static const profileTables = ['profile', 'plan_years', 'app_settings'];

  Future<Directory> _sub(String name) async =>
      Directory(p.join((await _supportDir()).path, name));

  Future<List<Directory>> _libraryDirs() async => [
    for (final f in const [
      BookLibrary.booksFolder,
      BookLibrary.materialsFolder,
      BookLibrary.attachmentsFolder,
    ])
      await _sub(f),
  ];

  /// Cartelle dei corsi nella cartella degli appunti.
  Future<List<Directory>> _courseDirs(Directory root) async {
    if (!await root.exists()) return const [];
    return _dirsOf(
      root,
      (e) => e is Directory && !p.basename(e.path).startsWith('.'),
    );
  }

  /// Le cartelle di [root] che passano [keep]; con la cartella sparita o
  /// illeggibile a metà (disco scollegato) restano quelle già lette.
  Future<List<Directory>> _dirsOf(
    Directory root,
    bool Function(FileSystemEntity) keep,
  ) async {
    final out = <Directory>[];
    try {
      await for (final e in root.list(followLinks: false)) {
        if (e is Directory && keep(e)) out.add(e);
      }
    } on FileSystemException {
      // vedi sopra
    }
    return out;
  }

  /// Sottocartelle [folders] di ogni corso.
  Future<List<Directory>> _noteDirs(
    Directory root,
    List<NoteFolder> folders,
  ) async => [
    for (final c in await _courseDirs(root))
      for (final f in folders) Directory(p.join(c.path, f.dirName)),
  ];

  /// Cestini nascosti della cartella appunti («Eliminati di recente» e i
  /// file eliminati su un altro dispositivo).
  Future<List<Directory>> _hiddenTrash(Directory root) async {
    if (!await root.exists()) return const [];
    return _dirsOf(
      root,
      (e) =>
          p.basename(e.path) == RecycleBin.dirName ||
          p.basename(e.path).startsWith('.cestino'),
    );
  }

  Future<int> _size(List<FileSystemEntity> items) async {
    var total = 0;
    for (final e in items) {
      total += await LocalData.sizeOf(e);
    }
    return total;
  }

  /// Le voci dell'elenco, con dimensioni e disponibilità.
  Future<List<EraseOption>> options() async {
    final root = await s.notes.root();
    final out = <EraseOption>[];
    for (final item in EraseItem.values) {
      switch (item) {
        case EraseItem.profile:
          out.add(const EraseOption(EraseItem.profile));
        case EraseItem.database:
          int? size;
          try {
            size = await LocalData.sizeOf(File(s.database.db.path));
          } catch (_) {}
          out.add(EraseOption(item, bytes: size));
        case EraseItem.recordings:
          out.add(
            EraseOption(
              item,
              bytes: await _size(await _noteDirs(root, _recordingFolders)),
              detail: root.path,
            ),
          );
        case EraseItem.notes:
          out.add(
            EraseOption(
              item,
              bytes: await _size([
                ...await _noteDirs(root, _noteFolders),
                ...await _hiddenTrash(root),
              ]),
              detail: root.path,
            ),
          );
        case EraseItem.books:
          out.add(EraseOption(item, bytes: await _size(await _libraryDirs())));
        case EraseItem.whisper:
          out.add(
            EraseOption(item, bytes: await _size([await _sub('whisper')])),
          );
        case EraseItem.catalog:
          out.add(
            EraseOption(
              item,
              bytes: await _size([await _sub('database_cache')]),
            ),
          );
        case EraseItem.onedrive:
          out.add(await _cloudOption(item, s.onedrive));
        case EraseItem.googleDrive:
          out.add(await _cloudOption(item, s.googleDrive));
        case EraseItem.onenote:
          out.add(
            const EraseOption(
              EraseItem.onenote,
              available: false,
              detail:
                  'Niente da eliminare: l\'app legge soltanto i tuoi blocchi '
                  'appunti e non ne crea.',
            ),
          );
        case EraseItem.calendar:
          var linked = false;
          String? label;
          try {
            linked = await s.reminders.calendarLinked();
            label = s.reminders.calendar.backend?.label;
          } catch (_) {}
          out.add(
            EraseOption(
              item,
              available: linked,
              detail: linked
                  ? 'Solo gli eventi dell\'app nel ${label ?? 'calendario'}'
                  : 'Calendario non collegato',
            ),
          );
        case EraseItem.accounts:
          final names = <String>[];
          for (final c in s.clouds) {
            if (await _connected(c)) names.add(c.serviceName);
          }
          out.add(
            EraseOption(item, detail: names.isEmpty ? null : names.join(', ')),
          );
      }
    }
    return out;
  }

  static Future<bool> _connected(CloudDriveService c) async {
    try {
      return await c.connected();
    } catch (_) {
      return false;
    }
  }

  Future<EraseOption> _cloudOption(EraseItem item, CloudDriveService c) async {
    if (!await _connected(c)) {
      return EraseOption(
        item,
        available: false,
        detail: '${c.serviceName} non collegato',
      );
    }
    final account = (await c.account())?.trim();
    final who = (account == null || account.isEmpty || account == 'collegato')
        ? ''
        : ' ($account)';
    return EraseOption(
      item,
      detail: 'Cartella «${await c.folder()}»$who, nel cestino del servizio',
    );
  }

  /// Elimina le voci [items]. Dopo, il database è chiuso: l'app va chiusa
  /// (e riaperta). [onStep]: testo per l'avanzamento.
  Future<EraseReport> run(
    Set<EraseItem> items, {
    void Function(String step)? onStep,
  }) async {
    // nessuna sincronizzazione parte da qui in poi (timer, ritorno
    // nell'app, lavoro periodico di Android che chiede all'app di
    // sincronizzare): ripartirebbe a metà cancellazione
    CloudDriveService.hold = true;
    try {
      return await _run(items, onStep);
    } catch (_) {
      // eliminazione interrotta: l'app resta usabile
      CloudDriveService.hold = false;
      rethrow;
    }
  }

  /// Sincronizzazione in corso nell'app o nel motore senza interfaccia di
  /// Android (lavoro periodico avviato ad app chiusa, che continua se nel
  /// frattempo l'app si apre: stesso database, stessi file).
  Future<bool> _syncBusy() async =>
      s.clouds.any((c) => c.syncing) ||
      await CloudDriveService.busyElsewhereNow();

  Future<EraseReport> _run(
    Set<EraseItem> items,
    void Function(String step)? onStep,
  ) async {
    final report = EraseReport();
    final root = await s.notes.root();
    for (final c in s.clouds) {
      c.stopAutoSync();
    }
    // una sincronizzazione in corso finisce prima di cancellare
    final until = DateTime.now().add(syncWait);
    while (await _syncBusy() && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    // 1. fuori dal dispositivo, finché ci sono accessi e impostazioni
    for (final (item, c) in [
      (EraseItem.onedrive, s.onedrive),
      (EraseItem.googleDrive, s.googleDrive),
    ]) {
      if (!items.contains(item) || !await _connected(c)) continue;
      onStep?.call('Elimino le cartelle dell\'app su ${c.serviceName}…');
      try {
        report.cloudFolders += await c.deleteRemoteAppData();
      } catch (e) {
        report.problems.add('${c.serviceName}: $e');
      }
    }
    if (items.contains(EraseItem.calendar)) {
      onStep?.call('Tolgo gli eventi dell\'app dal calendario…');
      try {
        await s.reminders.removeCalendarData();
        report.calendarRemoved = true;
      } catch (e) {
        report.problems.add('Calendario: $e');
      }
    }

    // 2. sul dispositivo
    onStep?.call('Elimino i dati dal dispositivo…');
    final profile = items.contains(EraseItem.profile);
    final database = items.contains(EraseItem.database);
    final accounts = items.contains(EraseItem.accounts);
    if (profile || database) {
      // notifiche pianificate e widget (riferiti a dati che non ci sono più)
      try {
        await s.reminders.eraseAll(calendarEvents: false, disconnect: accounts);
      } catch (_) {}
    } else if (accounts) {
      try {
        await s.reminders.outlook?.disconnect();
      } catch (_) {}
    }
    if (accounts && !(profile && database)) {
      // senza accesso l'account non risulta più collegato
      for (final c in s.clouds) {
        try {
          await s.settings.set(c.accountKey, null);
        } catch (_) {}
      }
    }
    if (!profile || !database) await _deleteRows(profile, database);
    try {
      await s.database.close();
    } catch (_) {}
    if (profile && database) await _deleteDatabaseFile();
    if (profile) {
      try {
        await _clearPrefs();
      } catch (_) {}
    }
    if (accounts) {
      try {
        await _wipeSecrets();
      } catch (_) {}
    }

    final recordings = items.contains(EraseItem.recordings);
    final notes = items.contains(EraseItem.notes);
    if (recordings && notes) {
      await LocalData.deleteNotes(root);
    } else {
      final dirs = [
        if (recordings) ...await _noteDirs(root, _recordingFolders),
        if (notes) ...await _noteDirs(root, _noteFolders),
        if (notes) ...await _hiddenTrash(root),
      ];
      for (final d in dirs) {
        await LocalData.deleteDirectory(d);
      }
      if (recordings && !notes) await _deleteTrashedRecordings(root);
    }
    if (recordings) {
      // registrazione rimasta a metà (WAV di lavoro)
      await LocalData.deleteDirectory(await _sub('registrazioni_in_corso'));
    }
    if (profile || database) {
      // copie dei dati fuori dal database: backup JSON di ogni dispositivo
      // scaricati dalla sincronizzazione (`onedrive_backup`, `gdrive_backup`)
      // e file .ics con le prove esportate nel calendario
      await _deleteDatabaseCopies();
    }
    if (items.contains(EraseItem.books)) {
      for (final d in await _libraryDirs()) {
        await LocalData.deleteDirectory(d);
      }
    }
    if (items.contains(EraseItem.whisper)) {
      await LocalData.deleteDirectory(await _sub('whisper'));
    }
    if (items.contains(EraseItem.catalog)) {
      await LocalData.deleteDirectory(await _sub('database_cache'));
    }
    // Stato della sincronizzazione: dopo un'eliminazione locale la prossima
    // sincronizzazione riparte da capo e riscarica dal cloud invece di
    // propagare l'eliminazione (i file nel cloud si tolgono solo con le
    // voci apposite).
    await _deleteSyncState();
    // Tutto scelto: via anche ciò che resta nella cartella dell'app
    // (evidenziazioni, file del calendario, backup locali) e le cache.
    if (profile &&
        database &&
        recordings &&
        notes &&
        items.contains(EraseItem.books) &&
        items.contains(EraseItem.whisper) &&
        items.contains(EraseItem.catalog)) {
      await LocalData.clearDirectory(await _supportDir());
    }
    // con le registrazioni anche le cartelle di lavoro recenti (pezzi di
    // audio della trascrizione, registrazione eliminata a metà): sul PC la
    // cartella temporanea è del profilo e resta dopo la chiusura dell'app
    await clearTempFiles(temp: _tempDir(), allWork: recordings);
    for (final d in await _cacheDirs()) {
      await LocalData.clearDirectory(d);
    }
    return report;
  }

  /// Voce «Registrazioni e trascrizioni» senza «Appunti»: dai cestini
  /// nascosti della cartella degli appunti si tolgono anche registrazioni,
  /// trascrizioni e riassunti eliminati di recente («Eliminati di recente»)
  /// o eliminati su un altro dispositivo (`.cestino-onedrive`…); gli
  /// appunti eliminati restano, con la loro voce.
  Future<void> _deleteTrashedRecordings(Directory root) async {
    final names = {for (final f in _recordingFolders) f.dirName};
    final bin = RecycleBin(() async => root);
    try {
      for (final e in await bin.list()) {
        if (e.isAudio ||
            e.files.any((f) => names.contains(p.basename(p.dirname(f.$2))))) {
          await bin.deleteForever(e);
        }
      }
    } catch (_) {}
    for (final d in await _hiddenTrash(root)) {
      if (p.basename(d.path) == RecycleBin.dirName) continue;
      try {
        await for (final f in d.list(recursive: true, followLinks: false)) {
          if (f is! File) continue;
          if (!p.split(p.relative(f.path, from: d.path)).any(names.contains)) {
            continue;
          }
          try {
            await f.delete();
          } catch (_) {}
        }
      } on FileSystemException {
        // cestino illeggibile a metà: quanto si è potuto togliere basta
      }
    }
  }

  /// Copie dei dati del database fuori dal file del database: backup JSON
  /// della sincronizzazione (`<servizio>_backup`, anche quelli degli altri
  /// dispositivi) e file del calendario esportati (`calendario`).
  Future<void> _deleteDatabaseCopies() async {
    final dir = await _supportDir();
    if (!await dir.exists()) return;
    final found = await _dirsOf(dir, (e) {
      final name = p.basename(e.path);
      return name == 'calendario' || RegExp(r'^\w+_backup$').hasMatch(name);
    });
    for (final d in found) {
      await LocalData.deleteDirectory(d);
    }
  }

  /// Voce sola (profilo o database): si svuotano le sue tabelle. Il
  /// database pubblico dei corsi (atenei, corsi di laurea) resta.
  Future<void> _deleteRows(bool profile, bool database) async {
    if (!profile && !database) return;
    try {
      final db = s.database.db;
      final existing = {
        for (final r in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        ))
          '${r['name']}',
      };
      final tables = [
        if (profile) ...profileTables,
        if (database) ...[
          for (final t in kPersonalTables)
            if (!profileTables.contains(t)) t,
          for (final t in existing)
            if (t.startsWith('mail_')) t,
        ],
      ];
      await db.execute('PRAGMA foreign_keys = OFF');
      for (final t in tables) {
        if (existing.contains(t)) await db.delete(t);
      }
      await db.execute('PRAGMA foreign_keys = ON');
    } catch (_) {}
  }

  Future<void> _deleteDatabaseFile() async {
    final path = p.join((await _supportDir()).path, AppDatabase.fileName);
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      try {
        final f = File('$path$suffix');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    // copie danneggiate messe da parte all'avvio e registro locale degli
    // errori (AppDatabase.open, ErrorLog): anche loro sono dati dell'app
    try {
      final dir = await _supportDir();
      if (!await dir.exists()) return;
      await for (final e in dir.list(followLinks: false)) {
        final name = p.basename(e.path);
        if (e is File &&
            (name.startsWith('${AppDatabase.fileName}.danneggiato-') ||
                name == ErrorLog.fileName ||
                name == '${ErrorLog.fileName}.1')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _deleteSyncState() async {
    final dir = await _supportDir();
    if (!await dir.exists()) return;
    try {
      await for (final e in dir.list(followLinks: false)) {
        final name = p.basename(e.path);
        final sync =
            (e is File && RegExp(r'^\w+_sync_.*\.json').hasMatch(name)) ||
            // copie locali dei registri dei dati (OneDrive, Google Drive)
            (e is Directory && RegExp(r'^\w+_dati$').hasMatch(name));
        if (sync) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } on FileSystemException {
      // cartella illeggibile a metà: il resto si pulisce alla prossima volta
    }
  }
}
