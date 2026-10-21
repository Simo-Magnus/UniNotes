import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/features/cloud/drive_picker.dart';
import 'package:university_notes/features/cloud/google_drive_client.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/cloud/google_oauth.dart';
import 'package:university_notes/features/cloud/incoming_files.dart';
import 'package:university_notes/features/cloud/microsoft_oauth.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_google_drive.dart';

/// Accesso finto: [refreshError] fa fallire il rinnovo (accesso vecchio).
class _FakeOAuth extends LoopbackOAuth {
  _FakeOAuth({this.refreshError})
    : super(
        providerName: 'Google',
        authEndpoint: Uri.parse('https://login.example/authorize'),
        tokenEndpoint: Uri.parse('https://login.example/token'),
        clientId: 'x',
        scope: 's',
        openBrowser: (_) async => true,
      );

  final String? refreshError;

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
  Future<OAuthTokens> refresh(String refreshToken) async {
    final e = refreshError;
    if (e != null) throw OAuthException(e);
    return signIn();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppDatabase db;
  late SettingsRepository settings;
  late FakeGoogleDrive drive;
  late MemoryCloudSecrets secrets;
  String? refreshError;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gd_drivefile_');
    db = await AppDatabase.openInMemory();
    settings = SettingsRepository(db);
    await settings.set('install_id', 't1');
    drive = FakeGoogleDrive(driveFileScope: true);
    secrets = MemoryCloudSecrets();
    refreshError = null;
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Directory dir(String name) =>
      Directory(p.join(tmp.path, name))..createSync(recursive: true);

  GoogleDriveService service() => GoogleDriveService(
    settings,
    NotesStore(settings, root: () async => dir('appunti')),
    secrets: secrets,
    transport: drive.call,
    oauthFactory: (_, _) => _FakeOAuth(refreshError: refreshError),
    stateDir: () async => dir('stato'),
    builtInClientId: 'client.apps.googleusercontent.com',
    builtInClientSecret: '',
    deviceName: 'PC',
    sources: SyncSources(materials: () async => dir('materiali')),
  );

  FakeItem byName(String name) =>
      drive.items.values.firstWhere((i) => i.name == name && !i.trashed);

  test('scope: drive.file per Google, Files.ReadWrite per OneDrive', () {
    expect(
      GoogleOAuth.defaultScope,
      'https://www.googleapis.com/auth/drive.file',
    );
    final url = GoogleOAuth(
      clientId: 'id',
      openBrowser: (_) async => true,
    ).authorizeUrl(redirect: 'http://127.0.0.1:1', verifier: 'v', state: 's');
    expect(url.queryParameters['scope'], GoogleOAuth.defaultScope);
    // OneDrive: tutta la cartella scelta, anche i file aggiunti dal sito
    expect(MicrosoftOAuth.defaultScope.split(' '), contains('Files.ReadWrite'));
  });

  test('cartella UniNotes non visibile (altro progetto): se ne crea una '
      'nuova senza errori e l\'avviso compare una volta sola', () async {
    // cartella creata da una registrazione precedente dell'app: con
    // drive.file per questa non esiste
    final old = drive.add('root', 'UniNotes', GoogleDriveClient.folderMime);
    drive.add(old.id, 'vecchio.pdf', 'application/pdf', [1]);
    final gd = service();
    await gd.signIn();
    final mine = drive.items.values.where(
      (i) => i.name == 'UniNotes' && drive.granted.contains(i.id),
    );
    expect(mine, hasLength(1));
    expect(await gd.notice(), DriveNotice.newFolder);

    // la sincronizzazione non vede il file vecchio e non dà errori
    final r = await gd.sync();
    expect(r, isNotNull);
    expect(r!.errors, isEmpty);
    expect(r.downloaded, 0);

    await gd.dismissNotice();
    expect(await gd.notice(), isNull);
    // di nuovo senza cartella (es. eliminata): l'avviso non torna
    for (final it in drive.items.values) {
      it.trashed = true;
    }
    await gd.signOut();
    await gd.signIn();
    expect(await gd.notice(), isNull);
  });

  test('accesso della versione precedente rifiutato da Google: tolto in '
      'silenzio, si chiede di ricollegarsi una volta', () async {
    await secrets.write('gdrive.refreshToken', 'vecchio');
    await settings.set('gdrive_account', 'Studente');
    refreshError = 'Google ha rifiutato l\'accesso: unauthorized_client';
    final gd = service();
    expect(await gd.sync(), isNull);
    expect(await gd.connected(), isFalse);
    expect(await gd.account(), isNull);
    expect(gd.authExpired, isFalse); // niente «collegamento interrotto»
    expect(gd.lastError, isNull);
    expect(await gd.lastSyncLabel(), isNull);
    expect(await gd.notice(), DriveNotice.reconnect);
    expect(gd.takeReconnectAlert(), isTrue);
    expect(gd.takeReconnectAlert(), isFalse);

    // ricollegandosi l'avviso sparisce
    refreshError = null;
    await gd.signIn();
    expect(await gd.notice(), isNot(DriveNotice.reconnect));
  });

  test('accesso vecchio senza rete: non si tocca nulla', () async {
    await secrets.write('gdrive.refreshToken', 'vecchio');
    refreshError = 'Google non raggiungibile (rete assente).';
    final gd = service();
    await gd.migrateLegacyAccess();
    expect(await gd.connected(), isTrue);
    expect(await gd.notice(), isNull);
    expect(GoogleDriveService.legacyRejected('invalid_grant'), isTrue);
    expect(GoogleDriveService.legacyRejected('non raggiungibile'), isFalse);
  });

  test('file messo nella cartella dal sito: invisibile finché non si '
      'importa, poi si sincronizza', () async {
    final gd = service();
    await gd.signIn();
    await gd.sync();
    final materiali = byName('Materiali');
    final site = drive.add(materiali.id, 'dispense.pdf', 'application/pdf', [
      4,
      2,
    ]);
    var r = await gd.sync();
    expect(r!.downloaded, 0);
    expect(
      File(p.join(dir('materiali').path, 'dispense.pdf')).existsSync(),
      isFalse,
    );

    // scelto nel Picker: è già dentro UniNotes, nessuna copia
    drive.grant(site.id);
    final plan = await gd.planImport([site.id]);
    expect(plan.inside, ['dispense.pdf']);
    expect(plan.outside, isEmpty);
    r = await gd.sync();
    expect(r!.downloaded, 1);
    expect(
      File(p.join(dir('materiali').path, 'dispense.pdf')).readAsBytesSync(),
      [4, 2],
    );
  });

  test('importa da Drive: file fuori dalla cartella copiati nella cartella '
      'dell\'insegnamento, documenti Google saltati', () async {
    final gd = service();
    await gd.signIn();
    final a = drive.add('root', 'Esercizi.pdf', 'application/pdf', [1, 2]);
    final b = drive.add(
      'root',
      'Appunti',
      'application/vnd.google-apps.document',
    );
    final hidden = drive.add('root', 'Altro.pdf', 'application/pdf', [9]);
    drive.grant(a.id);
    drive.grant(b.id);
    final plan = await gd.planImport([a.id, b.id, hidden.id]);
    expect(plan.outside.map((f) => f.name), ['Esercizi.pdf']);
    expect(plan.skipped, ['Appunti']);
    expect(plan.inside, isEmpty);

    final dest = IncomingDestination.course(const Course(name: 'Analisi I'));
    expect(await gd.copyIntoApp(plan.outside, dest), 1);
    expect(await gd.copyIntoApp(plan.outside, dest), 1);
    expect(
      drive.files,
      containsPair(
        'UniNotes/Materiali/Analisi I/Esercizi.pdf',
        utf8.decode([1, 2]),
      ),
    );
    expect(
      drive.files.keys,
      contains('UniNotes/Materiali/Analisi I/Esercizi (2).pdf'),
    );
    // l'originale resta dov'era
    expect(drive.files.keys, contains('Esercizi.pdf'));

    final r = await gd.sync();
    expect(r!.downloaded, 2);
    expect(
      File(p.join(dir('materiali').path, 'Analisi I', 'Esercizi.pdf'))
          .existsSync(),
      isTrue,
    );
  });

  group('Picker', () {
    test('id restituiti dalla pagina', () {
      Uri back(Map<String, String> q) =>
          Uri.parse('http://127.0.0.1:5000/picker').replace(queryParameters: q);
      var r = PickerResult.parse(
        back({'state': 's1', 'ids': 'abc_1-X, abc_1-X,bad id,,9zz'}),
        's1',
      );
      expect(r.ids, ['abc_1-X', '9zz']);
      expect(r.cancelled, isFalse);
      expect(
        PickerResult.parse(back({'state': 'altro', 'ids': 'a'}), 's1').error,
        isNotNull,
      );
      expect(
        PickerResult.parse(
          back({'state': 's1', 'cancel': '1'}),
          's1',
        ).cancelled,
        isTrue,
      );
      expect(PickerResult.parse(back({'state': 's1'}), 's1').cancelled, isTrue);
      r = PickerResult.parse(back({'state': 's1', 'error': 'no'}), 's1');
      expect(r.error, 'no');
      // schema del telefono
      r = PickerResult.parse(
        Uri.parse('com.googleusercontent.apps.1-x:/picker?state=s&ids=q1,q2'),
        's',
      );
      expect(r.ids, ['q1', 'q2']);
    });

    test('pagina: parametri nel frammento, mai nella query', () {
      final picker = DrivePicker(
        openBrowser: (_) async => true,
        apiKey: 'K',
        projectNumber: '123',
        pageUrl: 'https://example.org/UniNotes/drive-picker.html',
      );
      expect(picker.available, isTrue);
      final u = picker.pageUri(
        token: 'tok',
        returnUrl: 'http://127.0.0.1:9/picker',
        state: 'st',
      );
      expect(u.query, isEmpty);
      final f = Uri.splitQueryString(u.fragment);
      expect(f, {
        'token': 'tok',
        'key': 'K',
        'app': '123',
        'ret': 'http://127.0.0.1:9/picker',
        'state': 'st',
      });
      expect(
        DrivePicker(openBrowser: (_) async => true, apiKey: '').available,
        isFalse,
      );
    });

    test('PC: ritorno sul server locale, richieste estranee ignorate', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final result = DrivePicker.waitForReturn(server, 'giusto');
      // HttpClient è finto nei test con il binding: richiesta a mano
      Future<int> get(String path) async {
        final socket = await Socket.connect('127.0.0.1', server.port);
        socket.write(
          'GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n',
        );
        final text = await utf8.decoder.bind(socket).join();
        socket.destroy();
        return int.parse(text.split(' ')[1]);
      }

      expect(await get('/picker?state=sbagliato&ids=x'), 404);
      expect(await get('/favicon.ico'), 404);
      expect(await get('/picker?state=giusto&ids=f1,f2'), 200);
      expect((await result).ids, ['f1', 'f2']);
    });

    test('telefono: ritorno con lo schema del client Google', () async {
      late Uri opened;
      final picker = DrivePicker(
        openBrowser: (_) async => true,
        apiKey: 'K',
        projectNumber: '1',
        mobileClientId: '42-ab.apps.googleusercontent.com',
        webAuth: (url, scheme) async {
          opened = url;
          expect(scheme, 'com.googleusercontent.apps.42-ab');
          final f = Uri.splitQueryString(url.fragment);
          expect(f['ret'], 'com.googleusercontent.apps.42-ab:/picker');
          return '${f['ret']}?state=${f['state']}&ids=z1';
        },
      );
      final r = await picker.pick('tok');
      expect(r.ids, ['z1']);
      expect(opened.fragment, contains('token=tok'));
    });
  });

  group('file condivisi con l\'app', () {
    test('elenco dal codice nativo', () {
      final list = IncomingFiles.parse([
        {
          'path': '/cache/condivisi/1_0_Esame.pdf',
          'name': 'Esame.pdf',
          'temporary': true,
        },
        {'path': '/cache/condivisi/1_0_Esame.pdf', 'name': 'doppione'},
        'file:///tmp/foto%20lavagna.jpg',
        {'path': ''},
        {'name': 'senza percorso'},
        {'path': '/x/a', 'name': 'cartella/..\\nome:strano?.docx'},
        42,
      ]);
      expect(list.map((f) => f.name), [
        'Esame.pdf',
        'foto lavagna.jpg',
        'nome_strano_.docx',
      ]);
      expect(list.first.temporary, isTrue);
      expect(list[1].path, endsWith('foto lavagna.jpg'));
      expect(list[1].temporary, isFalse);
      expect(IncomingFiles.parse(null), isEmpty);
    });

    test('canale nativo: take una volta, available avvisa', () async {
      const channel = MethodChannel(IncomingFiles.channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var pending = <Object?>[
        {'path': '/c/a.pdf', 'name': 'a.pdf', 'temporary': true},
      ];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'take');
        final out = pending;
        pending = [];
        return out;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final incoming = IncomingFiles();
      var notified = 0;
      incoming.listen(() => notified++);
      addTearDown(incoming.dispose);
      expect((await incoming.take()).single.name, 'a.pdf');
      expect(await incoming.take(), isEmpty);
      await messenger.handlePlatformMessage(
        IncomingFiles.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('available'),
        ),
        (_) {},
      );
      expect(notified, 1);
    });

    test('salvataggio in Materiali/<insegnamento> o «Da ordinare»', () async {
      final cache = dir('cache');
      final shared = File(p.join(cache.path, '1_0_slide.pdf'))
        ..writeAsStringSync('pdf');
      final desk = File(p.join(dir('desktop').path, 'slide.pdf'))
        ..writeAsStringSync('pdf2');
      final materials = dir('materiali');
      final dest = IncomingDestination.course(
        const Course(name: 'Fisica I', universityId: 'polito'),
      );
      expect(dest.folder, 'Fisica I'); // niente sigla dell'ateneo
      final saved = await IncomingFiles.store(
        [
          IncomingFile(shared.path, 'slide.pdf', temporary: true),
          IncomingFile(desk.path, 'slide.pdf'),
          const IncomingFile('/non/esiste.pdf', 'esiste.pdf'),
        ],
        materials,
        dest,
      );
      expect(saved, ['Fisica I/slide.pdf', 'Fisica I/slide (2).pdf']);
      expect(shared.existsSync(), isFalse); // copia temporanea eliminata
      expect(desk.existsSync(), isTrue); // il file trascinato resta
      final unsorted = await IncomingFiles.store(
        [IncomingFile(desk.path, 'slide.pdf')],
        materials,
        IncomingDestination.unsorted,
      );
      expect(unsorted, ['Da ordinare/slide.pdf']);

      final tmpFile = File(p.join(cache.path, 'x.pdf'))..writeAsStringSync('');
      await IncomingFiles.discard([
        IncomingFile(tmpFile.path, 'x.pdf', temporary: true),
      ]);
      expect(tmpFile.existsSync(), isFalse);
      expect(
        IncomingFiles.uniqueAmong({'a.pdf', 'a (2).pdf'}, 'a.pdf'),
        'a (3).pdf',
      );
    });

    test('i file salvati arrivano su Google Drive', () async {
      final gd = service();
      await gd.signIn();
      final shared = File(p.join(dir('cache').path, 'lab.pdf'))
        ..writeAsStringSync('lab');
      await IncomingFiles.store(
        [IncomingFile(shared.path, 'lab.pdf', temporary: true)],
        dir('materiali'),
        IncomingDestination.unsorted,
      );
      final r = await gd.sync();
      expect(r!.uploaded, 1);
      expect(
        drive.files,
        containsPair('UniNotes/Materiali/Da ordinare/lab.pdf', 'lab'),
      );
    });
  });
}
