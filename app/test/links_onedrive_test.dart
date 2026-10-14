import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/cloud/microsoft_oauth.dart';
import 'package:university_notes/features/cloud/onedrive_folders.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_drive.dart';

/// Accesso finto: il rinnovo del token riesce sempre.
class _FakeOAuth extends LoopbackOAuth {
  _FakeOAuth()
    : super(
        providerName: 'Microsoft',
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
  group('accesso Microsoft su telefono e PC', () {
    test('telefono: schema personalizzato; PC/Mac: loopback', () {
      expect(
        microsoftRedirectMode(mobile: true),
        OAuthRedirectMode.customScheme,
      );
      expect(microsoftRedirectMode(mobile: false), OAuthRedirectMode.loopback);
      expect(
        MicrosoftOAuth.mobileRedirectUri,
        'msauth.io.github.simomagnus.universitynotes://auth',
      );
    });

    test('telefono: PKCE, redirect msauth e scambio del codice', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      Map<String, String>? form;
      server.listen((req) async {
        form = Uri.splitQueryString(await utf8.decoder.bind(req).join());
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'access_token': 'acc',
            'refresh_token': 'ref',
            'expires_in': 3600,
          }),
        );
        await req.response.close();
      });
      Uri? opened;
      String? scheme;
      final oauth = MicrosoftOAuth(
        clientId: '11111111-2222-3333-4444-555555555555',
        openBrowser: (_) async => false,
        mode: OAuthRedirectMode.customScheme,
        authority: Uri.parse('http://127.0.0.1:${server.port}/'),
        webAuthenticator: (url, s) async {
          opened = url;
          scheme = s;
          return '${MicrosoftOAuth.mobileRedirectUri}?code=abc&state=${url.queryParameters['state']}';
        },
      );
      final t = await oauth.signIn();
      expect(t.accessToken, 'acc');
      expect(t.refreshToken, 'ref');
      expect(scheme, MicrosoftOAuth.mobileScheme);
      final q = opened!.queryParameters;
      expect(opened!.path, '/common/oauth2/v2.0/authorize');
      expect(q['redirect_uri'], MicrosoftOAuth.mobileRedirectUri);
      expect(q['code_challenge_method'], 'S256');
      expect(q['client_id'], '11111111-2222-3333-4444-555555555555');
      expect(q['scope'], contains('Files.ReadWrite'));
      expect(form!['grant_type'], 'authorization_code');
      expect(form!['code'], 'abc');
      expect(form!['redirect_uri'], MicrosoftOAuth.mobileRedirectUri);
      expect(
        LoopbackOAuth.challengeFor(form!['code_verifier']!),
        q['code_challenge'],
      );
    });

    test(
      'telefono: stato diverso o errore → messaggio, niente token',
      () async {
        final oauth = MicrosoftOAuth(
          clientId: 'x',
          openBrowser: (_) async => false,
          mode: OAuthRedirectMode.customScheme,
          webAuthenticator: (url, s) async =>
              '${MicrosoftOAuth.mobileRedirectUri}?error=access_denied&state=x',
        );
        await expectLater(
          oauth.signIn(),
          throwsA(
            isA<OAuthException>().having(
              (e) => e.message,
              'm',
              contains('annullato'),
            ),
          ),
        );
        final cancelled = MicrosoftOAuth(
          clientId: 'x',
          openBrowser: (_) async => false,
          mode: OAuthRedirectMode.customScheme,
          webAuthenticator: (url, s) async => throw Exception('CANCELED'),
        );
        await expectLater(cancelled.signIn(), throwsA(isA<OAuthException>()));
      },
    );

    test('AADSTS50011 indica gli URI di PC e telefono', () {
      final m = MicrosoftOAuth.explain('AADSTS50011: redirect mismatch');
      expect(m, contains('http://localhost'));
      expect(m, contains(MicrosoftOAuth.mobileRedirectUri));
    });
  });

  group('servizio OneDrive', () {
    late Directory tmp;
    late AppDatabase db;
    late SettingsRepository settings;
    late FakeDrive drive;
    late MemoryCloudSecrets secrets;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('links_od_');
      db = await AppDatabase.openInMemory();
      settings = SettingsRepository(db);
      await settings.set('install_id', 't1');
      drive = FakeDrive();
      secrets = MemoryCloudSecrets();
    });
    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    Directory dir(String name) =>
        Directory(p.join(tmp.path, name))..createSync(recursive: true);

    var backup = '{"createdAt":"1","tables":{"exams":[]}}';

    OneDriveService service({String builtIn = ''}) => OneDriveService(
      settings,
      NotesStore(settings, root: () async => dir('appunti')),
      secrets: secrets,
      transport: drive.call,
      oauthFactory: (_, _) => _FakeOAuth(),
      stateDir: () async => dir('stato'),
      builtInClientId: builtIn,
      deviceName: 'PC',
      sources: SyncSources(
        books: () async => dir('libri'),
        materials: () async => dir('materiali'),
        attachments: () async => dir('allegati'),
        backupJson: () async => backup,
      ),
    );

    test('ID applicazione: quello incluso nell\'app, modificabile', () async {
      final od = service(builtIn: '11111111-2222-3333-4444-555555555555');
      expect(od.hasBuiltInClientId, isTrue);
      expect(await od.clientId(), '11111111-2222-3333-4444-555555555555');
      await od.setClientId('aaaaaaaa-2222-3333-4444-555555555555');
      expect(await od.clientId(), 'aaaaaaaa-2222-3333-4444-555555555555');
      await od.setClientId('');
      expect(await od.clientId(), '11111111-2222-3333-4444-555555555555');
      final none = service();
      await expectLater(
        none.signIn(),
        throwsA(
          isA<OAuthException>().having(
            (e) => e.message,
            'm',
            contains('MS_CLIENT_ID'),
          ),
        ),
      );
      expect(await none.folder(), 'UniNotes');
    });

    test(
      'accesso, cartelle per tipo, caselle e backup solo se cambia',
      () async {
        final od = service(builtIn: '11111111-2222-3333-4444-555555555555');
        await od.signIn();
        expect(await od.account(), 'Studente Prova · studente@example.com');
        final notes = dir('appunti');
        File(p.join(notes.path, 'Fisica', 'Registrazioni', 'L1.m4a'))
          ..createSync(recursive: true)
          ..writeAsStringSync('audio');
        File(p.join(notes.path, 'Fisica', 'Trascrizioni', 'L1.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('testo');
        File(p.join(dir('libri').path, 'libro.pdf')).writeAsStringSync('pdf');
        File(p.join(dir('allegati').path, 'a.png')).writeAsStringSync('png');

        await od.setScopes(
          SyncScope.values.toSet()..remove(SyncScope.recordings),
        );
        final r = await od.sync();
        expect(r, isNotNull);
        expect(od.lastError, isNull);
        expect(
          drive.files.keys,
          containsAll([
            'UniNotes/Corsi/Fisica/Trascrizioni/L1.md',
            'UniNotes/Libri/libro.pdf',
            'UniNotes/Allegati/a.png',
            'UniNotes/Backup/Backup PC t1.json',
          ]),
        );
        expect(
          drive.files.keys.where((k) => k.contains('Registrazioni')),
          isEmpty,
        );
        expect(await od.lastSyncLabel(), contains('caricati'));
        expect(await od.lastSyncAt(), isNotNull);

        // Backup invariato (cambia solo la data): nessun nuovo caricamento.
        backup = '{"createdAt":"2","tables":{"exams":[]}}';
        final v = drive.versions['UniNotes/Backup/Backup PC t1.json'];
        await od.sync();
        expect(drive.versions['UniNotes/Backup/Backup PC t1.json'], v);

        // Registrazioni riattivate: ora si caricano.
        await od.setScopes(SyncScope.values.toSet());
        await od.sync();
        expect(
          drive.files.keys,
          contains('UniNotes/Corsi/Fisica/Registrazioni/L1.m4a'),
        );
      },
    );

    test('controlli automatici con /delta: solo se qualcosa cambia', () async {
      final od = service(builtIn: '11111111-2222-3333-4444-555555555555');
      await od.signIn();
      await od.setScopes({SyncScope.notes});
      final notes = dir('appunti');
      File(p.join(notes.path, 'Fisica', 'Appunti', 'a.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('uno');
      await od.sync();
      final engine = (await od.targets()).single;
      expect(engine.remote, 'UniNotes/Corsi');

      // Niente di nuovo: il controllo leggero non elenca le cartelle.
      drive.log.clear();
      await od.sync(force: false);
      expect(drive.log.where((l) => l.contains('/children')), isEmpty);
      expect(drive.log.where((l) => l.contains('/delta')), isNotEmpty);

      // Un file aggiunto su OneDrive da un altro dispositivo arriva.
      drive.put('UniNotes/Corsi/Fisica/Appunti/b.md', 'dal telefono');
      final r = await od.sync(force: false);
      expect(r!.downloaded, 1);
      expect(
        File(p.join(notes.path, 'Fisica', 'Appunti', 'b.md'))
            .readAsStringSync(),
        'dal telefono',
      );

      // OneDrive for Business: niente /delta sulle sottocartelle → si
      // rilegge sempre tutto.
      drive.deltaUnsupported = true;
      await od.sync();
      drive.log.clear();
      await od.sync(force: false);
      expect(drive.log.where((l) => l.contains('/children')), isNotEmpty);
    });

    test('caselle e intervallo salvati', () async {
      final od = service();
      expect(await od.scopes(), SyncScope.values.toSet());
      await od.setScopes({SyncScope.backup});
      expect(await od.scopes(), {SyncScope.backup});
      expect(await od.intervalMinutes(), CloudDriveService.defaultInterval);
      await od.setIntervalMinutes(30);
      expect(await od.intervalMinutes(), 30);
    });
  });

  group('selettore della cartella OneDrive', () {
    late FakeDrive drive;
    late OneDriveFolderBrowser browser;

    setUp(() {
      drive = FakeDrive()
        ..addFolder('Documenti')
        ..addFolder('Università/Primo anno')
        ..put('file.txt', 'x');
      browser = OneDriveFolderBrowser(
        GraphClient(() async => 't', transport: drive.call),
      );
    });

    test('elenca solo le cartelle, naviga e crea', () async {
      final root = await browser.children(DriveFolder.root);
      expect(root.map((f) => f.name), ['Documenti', 'Università']);
      final uni = root.last;
      expect(uni.path, 'Università');
      final inside = await browser.children(uni);
      expect(inside.single.path, 'Università/Primo anno');

      final created = await browser.createFolder(uni, 'UniNotes');
      expect(created.path, 'Università/UniNotes');
      expect(drive.folders, contains('Università/UniNotes'));

      final top = await browser.createFolder(DriveFolder.root, 'Nuova');
      expect(top.path, 'Nuova');
      await expectLater(
        browser.createFolder(DriveFolder.root, 'Nuova'),
        throwsA(
          isA<GraphException>().having(
            (e) => e.message,
            'm',
            contains('Esiste già'),
          ),
        ),
      );
    });

    test('nomi non validi', () {
      expect(OneDriveFolderBrowser.validateName(''), isNotNull);
      expect(OneDriveFolderBrowser.validateName('a/b'), isNotNull);
      expect(OneDriveFolderBrowser.validateName('a:b'), isNotNull);
      expect(OneDriveFolderBrowser.validateName('fine.'), isNotNull);
      expect(OneDriveFolderBrowser.validateName('UniNotes'), isNull);
    });
  });
}
