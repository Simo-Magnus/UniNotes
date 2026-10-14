import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/core/services/power.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_google_drive.dart';

/// Accesso finto: riesce sempre.
class _FakeOAuth extends LoopbackOAuth {
  _FakeOAuth()
    : super(
        providerName: 'Google',
        authEndpoint: Uri.parse('https://login.example/authorize'),
        tokenEndpoint: Uri.parse('https://login.example/token'),
        clientId: 'x',
        scope: 's',
        openBrowser: (_) async => true,
      );

  @override
  Future<OAuthTokens> signIn({
    String? loginHint,
    Duration timeout = const Duration(minutes: 5),
  }) async => OAuthTokens(
    accessToken: 'a',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    refreshToken: 'r',
  );

  @override
  Future<OAuthTokens> refresh(String refreshToken) => signIn();
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late SettingsRepository settings;
  late FakeGoogleDrive drive;
  late MemoryCloudSecrets secrets;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gd_service_');
    db = await AppDatabase.openInMemory();
    settings = SettingsRepository(db);
    await settings.set('install_id', 't1');
    drive = FakeGoogleDrive();
    secrets = MemoryCloudSecrets();
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Directory dir(String name) =>
      Directory(p.join(tmp.path, name))..createSync(recursive: true);

  GoogleDriveService service({
    String id = 'client.apps.googleusercontent.com',
  }) => GoogleDriveService(
    settings,
    NotesStore(settings, root: () async => dir('appunti')),
    secrets: secrets,
    transport: drive.call,
    oauthFactory: (_, _) => _FakeOAuth(),
    stateDir: () async => dir('stato'),
    builtInClientId: id,
    builtInClientSecret: '',
    deviceName: 'PC',
    sources: SyncSources(
      books: () async => dir('libri'),
      backupJson: () async => '{"createdAt":"1","tables":{}}',
    ),
  );

  test('risparmio energetico: pausa con batteria scarica, registrazioni solo '
      'con Wi‑Fi, backup solo se i dati cambiano', () async {
    var exports = 0;
    var changes = 1;
    final gd = GoogleDriveService(
      settings,
      NotesStore(settings, root: () async => dir('appunti')),
      secrets: secrets,
      transport: drive.call,
      oauthFactory: (_, _) => _FakeOAuth(),
      stateDir: () async => dir('stato'),
      builtInClientId: 'client.apps.googleusercontent.com',
      builtInClientSecret: '',
      deviceName: 'PC',
      sources: SyncSources(
        backupJson: () async {
          exports++;
          return '{"tables":{"n":$changes}}';
        },
        changeCounter: () async => changes,
      ),
    );
    addTearDown(() {
      Power.debugOnWifi = null;
    });
    await gd.signIn();
    File(p.join(dir('appunti').path, 'Analisi', 'Registrazioni', 'l.m4a'))
      ..createSync(recursive: true)
      ..writeAsStringSync('audio');
    File(p.join(dir('appunti').path, 'Analisi', 'Riassunti', 'r.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('testo');

    // dati mobili + «registrazioni solo con Wi‑Fi»
    Power.debugOnWifi = () async => false;
    await gd.setRecordingsWifiOnly(true);
    await gd.sync();
    expect(drive.files.keys.toSet(), {
      'UniNotes/Corsi/Analisi/Riassunti/r.md',
      'UniNotes/Backup/Backup PC t1.json',
    });
    expect(exports, 1);

    // Wi‑Fi: arriva anche la registrazione; dati invariati → nessun export
    Power.debugOnWifi = () async => true;
    await gd.sync();
    expect(
      drive.files.keys,
      contains('UniNotes/Corsi/Analisi/Registrazioni/l.m4a'),
    );
    expect(exports, 1);
    changes = 2;
    await gd.sync();
    expect(exports, 2);
  });

  test('senza ID client nella build: accesso spiegato', () async {
    final gd = service(id: '');
    expect(gd.available, isFalse);
    await expectLater(
      gd.signIn(),
      throwsA(
        isA<OAuthException>().having(
          (e) => e.message,
          'm',
          contains('google_drive_setup'),
        ),
      ),
    );
  });

  test('accesso, sincronizzazione di appunti, libri e backup', () async {
    final gd = service();
    expect(await gd.connected(), isFalse);
    await gd.signIn();
    expect(await gd.connected(), isTrue);
    expect(await gd.account(), 'Studente · s@gmail.com');

    File(p.join(dir('appunti').path, 'Analisi', 'Riassunti', 'r.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('riassunto');
    File(p.join(dir('libri').path, 'manuale.pdf')).writeAsStringSync('pdf');
    File(p.join(dir('libri').path, 'solo qui.pdf')).writeAsStringSync('x');
    await gd.setBookInCloud('solo qui.pdf', false);

    final r = await gd.sync();
    expect(r, isNotNull);
    expect(r!.errors, isEmpty);
    expect(drive.files.keys.toSet(), {
      'UniNotes/Corsi/Analisi/Riassunti/r.md',
      'UniNotes/Libri/manuale.pdf',
      'UniNotes/Backup/Backup PC t1.json',
    });
    expect(await gd.lastSyncLabel(), contains('3'));

    // impostazioni separate da OneDrive
    expect(await settings.get('gdrive_account'), isNotNull);
    expect(await settings.get('onedrive_account'), isNull);

    await gd.signOut();
    expect(await gd.connected(), isFalse);
    expect(await gd.sync(), isNull);
  });
}
