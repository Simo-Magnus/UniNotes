import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/core/services/power.dart';
import 'package:university_notes/features/cloud/google_drive_client.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/cloud/google_oauth.dart'
    show GoogleOAuth;
import 'package:university_notes/features/cloud/graph_client.dart'
    show GraphException;
import 'package:university_notes/features/cloud/onedrive_service.dart'
    show OneDriveService;
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

  test('risparmio energetico: registrazioni solo con Wi‑Fi, backup solo se '
      'i dati cambiano', () async {
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

  GoogleDriveService withTransport(GraphTransport t) => GoogleDriveService(
    settings,
    NotesStore(settings, root: () async => dir('appunti')),
    secrets: secrets,
    transport: t,
    oauthFactory: (_, _) => _FakeOAuth(),
    stateDir: () async => dir('stato'),
    builtInClientId: 'client.apps.googleusercontent.com',
    builtInClientSecret: '',
    deviceName: 'PC',
  );

  test('accesso a metà: se account o cartella non riescono non resta '
      'collegato', () async {
    final gd = withTransport((m, u, {headers = const {}, body}) async {
      if (u.path == '/drive/v3/files' && m == 'POST') {
        return GraphResponse(
          500,
          Uint8List.fromList(utf8.encode('{"error":{"message":"Errore"}}')),
        );
      }
      return drive.call(m, u, headers: headers, body: body);
    });
    await expectLater(gd.signIn(), throwsA(isA<DriveException>()));
    expect(await gd.connected(), isFalse);
    expect(await gd.account(), isNull);
    expect(await settings.get(gd.grantedScopeKey), isNull);
    expect(secrets.values, isEmpty);
    expect(gd.tokens, isNull);
  });

  test('Scollega revoca il token presso Google; senza rete si scollega '
      'comunque', () async {
    final revokes = <String>[];
    var offline = false;
    final gd = withTransport((m, u, {headers = const {}, body}) async {
      if (u == GoogleOAuth.revokeEndpoint) {
        if (offline) {
          throw GraphException(0, 'Google non raggiungibile (offline).');
        }
        revokes.add('$m ${utf8.decode(body!)}');
        return GraphResponse(200, Uint8List(0));
      }
      return drive.call(m, u, headers: headers, body: body);
    });
    await gd.signIn();
    expect(await gd.signOut(), isTrue);
    expect(revokes, ['POST token=r']);
    expect(await gd.connected(), isFalse);

    await gd.signIn();
    offline = true;
    expect(await gd.signOut(), isFalse);
    expect(await gd.connected(), isFalse);
    expect(await gd.account(), isNull);
  });

  test(
    '«Salva nel cloud» di un libro vale per OneDrive e Google Drive',
    () async {
      final od = OneDriveService(
        settings,
        NotesStore(settings, root: () async => dir('appunti')),
        secrets: secrets,
        stateDir: () async => dir('stato'),
        builtInClientId: '',
      );
      final gd = service();
      final noBooks = SyncScope.values.toSet()..remove(SyncScope.books);
      await od.setScopes(noBooks);
      await gd.setScopes(noBooks);
      await CloudDriveService.setBookInCloudFor([od, gd], 'libro.pdf', false);
      // lista comune dei libri solo su questo dispositivo
      expect(await od.booksLocalOnly(), {'libro.pdf'});
      expect(await gd.booksLocalOnly(), {'libro.pdf'});
      expect(await gd.scopes(), noBooks);
      await CloudDriveService.setBookInCloudFor([od, gd], 'libro.pdf', true);
      expect(await od.booksLocalOnly(), isEmpty);
      // casella «Libri» riattivata su entrambi i servizi
      expect(await od.scopes(), contains(SyncScope.books));
      expect(await gd.scopes(), contains(SyncScope.books));
    },
  );

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
