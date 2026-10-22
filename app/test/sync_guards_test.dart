import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/database/sync_schema.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/repositories/settings_repository.dart';
import 'package:university_notes/core/services/portable_path.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/cloud/onedrive_sync.dart';
import 'package:university_notes/features/reader/reader_store.dart';

import 'support/fake_drive.dart';

/// Libro PDF rovinato fra Windows e Android (22/10/2026): sul telefono era
/// comparso «Principi di Chimica.pdf» vuoto (0 byte), caricato su OneDrive e
/// Google Drive; il PC, che aveva il file vero, l'ha visto come conflitto e
/// l'ha rinominato «(conflitto PC …)», poi ha scaricato quello vuoto: il
/// lettore dava l'errore del PDF. Ora un documento vuoto non si carica mai,
/// non crea conflitti, si ripara da solo e i download incompleti non
/// sostituiscono il file buono.
void main() {
  late Directory tmp;
  late FakeDrive drive;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('um_guards_');
    drive = FakeDrive();
  });
  tearDown(() => tmp.delete(recursive: true));

  OneDriveSync device(String name) => OneDriveSync(
    graph: GraphClient(() async => 'token', transport: drive.call),
    localRoot: Directory(p.join(tmp.path, name, 'libri')),
    remoteFolder: 'UniNotes/Libri',
    stateFile: File(p.join(tmp.path, name, 'state.json')),
    deviceName: name,
    now: () => DateTime(2026, 10, 22, 0, 15),
  );

  File f(OneDriveSync d, String rel) =>
      File(p.joinAll([d.localRoot.path, ...rel.split('/')]));

  Future<void> write(OneDriveSync d, String rel, List<int> bytes) async {
    final file = f(d, rel);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    await file.setLastModified(DateTime.now().add(Duration(seconds: bytes.length)));
  }

  final book = List<int>.generate(5000, (i) => i % 251);
  const name = 'Principi di Chimica.pdf';

  test('PDF vuoto sul telefono: non si carica, si riprende quello pieno',
      () async {
    final pc = device('PC');
    final phone = device('telefono');
    await write(pc, name, book);
    await pc.run();
    await write(phone, name, const []);
    final r = await phone.run();
    expect(r.uploaded, 0);
    expect(r.conflicts, 0);
    expect(await f(phone, name).length(), book.length);
    expect(drive.files['UniNotes/Libri/$name']!.length, book.length);
  });

  test('PDF vuoto sul servizio: vince la copia piena, nessun conflitto',
      () async {
    final pc = device('PC');
    await write(pc, name, book);
    drive.put('UniNotes/Libri/$name', '');
    final r = await pc.run();
    expect(r.conflicts, 0);
    expect(drive.files['UniNotes/Libri/$name']!.length, book.length);
    expect(await f(pc, name).length(), book.length);
  });

  test('riparazione: la copia «(conflitto …)» piena torna al suo nome',
      () async {
    final pc = device('PC');
    const copy = 'Principi di Chimica (conflitto PC 2026-10-22 00.15).pdf';
    // stato lasciato dalla versione precedente: entrambi sincronizzati
    await write(pc, name, const [1]);
    await write(pc, copy, book);
    await pc.run();
    await write(pc, name, const []);
    drive.put('UniNotes/Libri/$name', '');
    final r = await pc.run();
    expect(r.errors, isEmpty);
    expect(await f(pc, name).length(), book.length);
    expect(await f(pc, copy).exists(), isFalse);
    expect(drive.files['UniNotes/Libri/$name']!.length, book.length);
    expect(drive.files.containsKey('UniNotes/Libri/$copy'), isFalse);
  });

  test('solo i documenti devono avere contenuto; copie di conflitto', () {
    expect(FolderSync.damaged('a.pdf', 0), isTrue);
    expect(FolderSync.damaged('a.PDF', 0), isTrue);
    expect(FolderSync.damaged('appunti.md', 0), isFalse);
    expect(FolderSync.damaged('a.pdf', 10), isFalse);
    expect(
      FolderSync.conflictCopiesOf('x/a.pdf', [
        'x/a (conflitto PC 2026-10-22 00.15).pdf',
        'x/a (2).pdf',
        'a (conflitto PC 1).pdf',
      ]),
      ['x/a (conflitto PC 2026-10-22 00.15).pdf'],
    );
  });

  test('download incompleto: errore, il file buono resta', () async {
    final part = File(p.join(tmp.path, 'x.part'))..writeAsBytesSync([1, 2]);
    await expectLater(
      FolderSync.checkDownloaded(part, 10),
      throwsA(isA<FileSystemException>()),
    );
    await FolderSync.checkDownloaded(part, 2);
    await FolderSync.checkDownloaded(part, 0);
  });

  group('sincronizzare tutto', () {
    test('«Controlla le novità ogni» comprende 2 minuti', () {
      expect(CloudDriveService.intervals.first, 2);
    });

    test('impostazioni sincronizzate: lettore, «Non chiedere più», notifiche, '
        'ordine di Studio; mai account, token e stato dei servizi', () {
      for (final k in [
        'reader:0123456789abcdef0123',
        'dont_ask_delete_exam',
        'notif_exam_offsets',
        'notif_exam_hours',
        'study_course_order',
        'syscal_writers',
        'focus_settings',
      ]) {
        expect(SyncSchema.isSyncedSetting(k), isTrue, reason: k);
      }
      for (final k in [
        'onedrive_account',
        'onedrive_folder',
        'gdrive_last_result',
        'notif_consent',
        'notif_scheduled',
        'reader_recent',
        'theme_mode',
        'install_id',
        'syscal_chosen',
      ]) {
        expect(SyncSchema.isSyncedSetting(k), isFalse, reason: k);
      }
      expect(SyncSchema.syncedSettingSql('key'), contains("substr(key, 1, 7) = 'reader:'"));
    });

    test('inventario: ogni tabella del database è sincronizzata o esclusa '
        'per scelta', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final tables = {
        for (final r in await db.db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT "
          "LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
        ))
          r['name'] as String,
      };
      final synced = {for (final s in SyncSchema.tables) s.table};
      // dati pubblici del catalogo (si reimportano), email (con credenziali)
      // e il registro delle eliminazioni stesso
      const notSynced = {
        'universities',
        'degrees',
        'places',
        'place_categories',
        'benefits',
        'mail_accounts',
        'mail_messages',
        'mail_state',
        SyncSchema.tombstones,
      };
      final unknown = tables.difference(synced).difference(notSynced);
      expect(unknown, isEmpty, reason: 'tabelle da classificare: $unknown');
    });

    test('cartelle dell\'app sul servizio: anche le evidenziazioni', () {
      expect(CloudDriveService.appSubfolders, contains('Evidenziazioni'));
    });

    test('chiave del lettore uguale su tutti i dispositivi per i libri', () async {
      final pc = Directory(p.join(tmp.path, 'pc'))..createSync();
      final phone = Directory(p.join(tmp.path, 'tel'))..createSync();
      final old = portableBase;
      addTearDown(() => portableBase = old);
      for (final d in [pc, phone]) {
        File(p.join(d.path, 'libri', 'Analisi.pdf'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(book);
      }
      portableBase = pc.path;
      final a = await ReaderStore.keyOf(p.join(pc.path, 'libri', 'Analisi.pdf'));
      portableBase = phone.path;
      final b = await ReaderStore.keyOf(
        p.join(phone.path, 'libri', 'Analisi.pdf'),
      );
      expect(a, b);
      expect(portablePath(p.join(phone.path, 'libri', 'Analisi.pdf')),
          'app:libri/Analisi.pdf');
    });

    test('stati spostati quando la cartella dell\'app si rinomina', () async {
      final state = Directory(p.join(tmp.path, 'stato'))..createSync();
      File(p.join(state.path, 'onedrive_sync_libri.json')).writeAsStringSync(
        jsonEncode({'remoteFolder': 'UniNotes/Libri', 'files': {}}),
      );
      File(p.join(state.path, 'gdrive_sync_libri.json')).writeAsStringSync(
        jsonEncode({'remoteFolder': 'UniNotes/Libri', 'files': {}}),
      );
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      final od = OneDriveService(
        settings,
        NotesStore(settings),
        secrets: MemoryCloudSecrets(),
        stateDir: () async => state,
      );
      await od.moveSyncStates('UniNotes', 'Università');
      Map<String, Object?> read(String n) =>
          (jsonDecode(File(p.join(state.path, n)).readAsStringSync()) as Map)
              .cast<String, Object?>();
      expect(read('onedrive_sync_libri.json')['remoteFolder'], 'Università/Libri');
      // gli stati di Google Drive non sono di OneDrive
      expect(read('gdrive_sync_libri.json')['remoteFolder'], 'UniNotes/Libri');
      expect(CloudDriveService.validateFolderName(''), isNotNull);
      expect(CloudDriveService.validateFolderName('a/b'), isNotNull);
      expect(CloudDriveService.validateFolderName('Università'), isNull);
    });
  });
}
