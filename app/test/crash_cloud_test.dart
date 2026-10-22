import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/agenda.dart';
import 'package:university_notes/core/reminders/home_widgets.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/reminders/notification_platform.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/features/cloud/data_sync.dart';
import 'package:university_notes/features/cloud/google_drive_client.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/cloud/google_drive_sync.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/cloud/onedrive_sync.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_drive.dart';
import 'support/fake_google_drive.dart';
import 'support/fake_reminders.dart';

/// Caccia ai crash del 22/10/2026 (sincronizzazione, accesso, promemoria):
/// ogni test riproduce un caso che prima bloccava, perdeva dati o lanciava
/// un errore che nessuno raccoglieva.

/// Accesso finto: riesce sempre.
class _FakeOAuth extends LoopbackOAuth {
  _FakeOAuth({this.reject})
    : super(
        providerName: 'Microsoft',
        authEndpoint: Uri.parse('https://login.example/authorize'),
        tokenEndpoint: Uri.parse('https://login.example/token'),
        clientId: 'x',
        scope: 's',
        openBrowser: (_) async => true,
      );

  /// Messaggio del rifiuto del rinnovo (null = rinnovo riuscito).
  final String? reject;

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
    if (reject != null) throw OAuthException(reject!);
    return signIn();
  }
}

/// Portachiavi che non riesce a cancellare (es. Keystore di Android
/// rovinato dopo un ripristino).
class _BrokenDeleteSecrets extends MemoryCloudSecrets {
  @override
  Future<void> delete(String key) async =>
      throw Exception('portachiavi non disponibile');
}

/// Notifiche che funzionano solo dopo [init] (come il pacchetto nel motore
/// senza interfaccia della sincronizzazione in background).
class _NeedsInitPlatform extends FakeNotificationPlatform {
  int inits = 0;

  @override
  Future<void> init(void Function(NotificationTap tap) onTap) async => inits++;

  @override
  Future<void> schedule(PlannedNotification n) async {
    if (inits == 0) throw StateError('notifiche non inizializzate');
    return super.schedule(n);
  }
}

GraphResponse _json(int status, Object body) =>
    GraphResponse(status, Uint8List.fromList(utf8.encode(jsonEncode(body))));

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('um_crash_cloud_');
  });
  tearDown(() async {
    CloudDriveService.busyElsewhere = null;
    networkIdleTimeout = const Duration(seconds: 60);
    await tmp.delete(recursive: true);
  });

  Future<void> write(File file, Object content) async {
    await file.parent.create(recursive: true);
    if (content is String) {
      await file.writeAsString(content);
    } else {
      await file.writeAsBytes(content as List<int>);
    }
    final len = content is String ? content.length : (content as List).length;
    // mtime diverso anche su file system con risoluzione al secondo
    await file.setLastModified(DateTime.now().add(Duration(seconds: len % 5000)));
  }

  group('OneDrive', () {
    late FakeDrive drive;
    setUp(() => drive = FakeDrive());

    OneDriveSync device(String name, {GraphTransport? transport}) =>
        OneDriveSync(
          graph: GraphClient(
            () async => 'token',
            transport: transport ?? drive.call,
          ),
          localRoot: Directory(p.join(tmp.path, name, 'Corsi')),
          remoteFolder: 'UniNotes/Corsi',
          stateFile: File(p.join(tmp.path, name, 'state.json')),
          deviceName: name,
          now: () => DateTime(2026, 10, 22, 9, 15),
        );

    File f(OneDriveSync d, String rel) =>
        File(p.joinAll([d.localRoot.path, ...rel.split('/')]));

    const lesson = 'Analisi I/Trascrizioni/Lezione 1.md';

    test(
      'elenco senza «value» (risposta inattesa): errore, i file restano',
      () async {
        final pc = device('PC');
        await write(f(pc, lesson), 'limiti');
        expect((await pc.run()).uploaded, 1);
        final broken = device(
          'PC',
          transport: (m, u, {headers = const {}, body}) async =>
              m == 'GET' && u.path.endsWith('/children')
              ? _json(200, {'@odata.context': 'x'})
              : drive.call(m, u, headers: headers, body: body),
        );
        await expectLater(broken.run(), throwsA(isA<GraphException>()));
        expect(await f(pc, lesson).readAsString(), 'limiti');
        expect(
          await Directory(
            p.join(pc.localRoot.path, OneDriveSync.trashDir),
          ).exists(),
          isFalse,
        );
      },
    );

    test('cartella sparita durante l\'elenco (404): errore, nessun file '
        'tolto', () async {
      final pc = device('PC');
      await write(f(pc, lesson), 'limiti');
      await pc.run();
      final gone = device(
        'PC',
        transport: (m, u, {headers = const {}, body}) async =>
            m == 'GET' && u.path.endsWith('/children')
            ? _json(404, {
                'error': {'code': 'itemNotFound'},
              })
            : drive.call(m, u, headers: headers, body: body),
      );
      await expectLater(gone.run(), throwsA(isA<GraphException>()));
      expect(await f(pc, lesson).exists(), isTrue);
    });

    test('caricamento rifiutato (404): non risulta sincronizzato e la volta '
        'dopo si ricarica, il file resta', () async {
      var fail = true;
      final pc = device(
        'PC',
        transport: (m, u, {headers = const {}, body}) async =>
            fail && m == 'PUT' && u.path.endsWith(':/content')
            ? _json(404, {
                'error': {'code': 'itemNotFound'},
              })
            : drive.call(m, u, headers: headers, body: body),
      );
      await write(f(pc, lesson), 'limiti');
      final r = await pc.run();
      expect(r.uploaded, 0);
      expect(r.errors.single, contains('Lezione 1.md'));
      fail = false;
      expect((await pc.run()).uploaded, 1);
      expect(await f(pc, lesson).readAsString(), 'limiti');
      expect(utf8.decode(drive.files['UniNotes/Corsi/$lesson']!), 'limiti');
    });

    test('sessione di caricamento scaduta a metà (404): il file grande resta '
        'e si ricarica', () async {
      var fail = true;
      final pc = device(
        'PC',
        transport: (m, u, {headers = const {}, body}) async =>
            fail && u.host == 'upload.example'
            ? _json(404, {
                'error': {'code': 'itemNotFound'},
              })
            : drive.call(m, u, headers: headers, body: body),
      );
      const big = 'Analisi I/Registrazioni/Lezione 1.m4a';
      final bytes = List<int>.generate(
        OneDriveSync.simpleUploadLimit + 10,
        (i) => i % 251,
      );
      await write(f(pc, big), bytes);
      final r = await pc.run();
      expect(r.uploaded, 0);
      expect(r.errors, isNotEmpty);
      fail = false;
      expect((await pc.run()).uploaded, 1);
      expect(await f(pc, big).length(), bytes.length);
      expect(drive.files['UniNotes/Corsi/$big']!.length, bytes.length);
    });

    test('due conflitti nello stesso minuto: la prima copia non si '
        'sovrascrive', () async {
      final pc = device('PC');
      final phone = device('telefono');
      await write(f(pc, lesson), 'v1');
      await pc.run();
      await phone.run();
      await write(f(pc, lesson), 'PC primo');
      await write(f(phone, lesson), 'telefono primo!');
      await pc.run();
      expect((await phone.run()).conflicts, 1);
      final first = phone.conflictName(lesson);
      expect(await f(phone, first).readAsString(), 'telefono primo!');
      await pc.run();
      await write(f(pc, lesson), 'PC secondo, più lungo');
      await write(f(phone, lesson), 'telefono secondo, ancora più lungo');
      await pc.run();
      expect((await phone.run()).conflicts, 1);
      final second = phone.conflictName(lesson, 2);
      expect(second, contains('(conflitto telefono 2026-10-22 09.15 2).md'));
      expect(await f(phone, first).readAsString(), 'telefono primo!');
      expect(
        await f(phone, second).readAsString(),
        'telefono secondo, ancora più lungo',
      );
      expect(
        utf8.decode(drive.files['UniNotes/Corsi/$first']!),
        'telefono primo!',
      );
    });
  });

  group('Google Drive', () {
    late FakeGoogleDrive drive;
    setUp(() => drive = FakeGoogleDrive());

    GoogleDriveSync device(String name, {GraphTransport? transport}) =>
        GoogleDriveSync(
          drive: GoogleDriveClient(
            () async => 'token',
            transport: transport ?? drive.call,
          ),
          localRoot: Directory(p.join(tmp.path, name, 'Corsi')),
          remoteFolder: 'UniNotes/Corsi',
          stateFile: File(p.join(tmp.path, name, 'state.json')),
          deviceName: name,
          now: () => DateTime(2026, 10, 22, 9, 15),
        );

    File f(GoogleDriveSync d, String rel) =>
        File(p.joinAll([d.localRoot.path, ...rel.split('/')]));

    const lesson = 'Analisi I/Lezione 1.md';

    test('elenco senza «files»: errore, i file restano', () async {
      final pc = device('PC');
      await write(f(pc, lesson), 'limiti');
      expect((await pc.run()).uploaded, 1);
      final broken = device(
        'PC',
        transport: (m, u, {headers = const {}, body}) async =>
            m == 'GET' &&
                u.path == '/drive/v3/files' &&
                !(u.queryParameters['q'] ?? '').contains('mimeType')
            ? _json(200, {'kind': 'drive#fileList'})
            : drive.call(m, u, headers: headers, body: body),
      );
      await expectLater(broken.run(), throwsA(isA<DriveException>()));
      expect(await f(pc, lesson).readAsString(), 'limiti');
    });

    test('file tolto da Drive durante la sincronizzazione (404 sul '
        'caricamento): la modifica locale non si perde', () async {
      var fail = false;
      final pc = device(
        'PC',
        transport: (m, u, {headers = const {}, body}) async =>
            fail &&
                m == 'PATCH' &&
                u.path.startsWith('/upload/drive/v3/files/')
            ? _json(404, {
                'error': {'message': 'File not found'},
              })
            : drive.call(m, u, headers: headers, body: body),
      );
      await write(f(pc, lesson), 'v1');
      await pc.run();
      await write(f(pc, lesson), 'versione modificata');
      fail = true;
      final r = await pc.run();
      expect(r.uploaded, 0);
      expect(r.errors, isNotEmpty);
      fail = false;
      await pc.run();
      expect(await f(pc, lesson).readAsString(), 'versione modificata');
      expect(drive.files['UniNotes/Corsi/$lesson'], 'versione modificata');
    });
  });

  group('servizio cloud', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late FakeDrive drive;
    late MemoryCloudSecrets secrets;

    setUp(() async {
      db = await AppDatabase.openInMemory();
      settings = SettingsRepository(db);
      await settings.set('install_id', 't1');
      drive = FakeDrive();
      secrets = MemoryCloudSecrets();
      await secrets.write('onedrive.refreshToken', 'r');
    });
    tearDown(() => db.close());

    Directory dir(String name) =>
        Directory(p.join(tmp.path, name))..createSync(recursive: true);

    OneDriveService service() => OneDriveService(
      settings,
      NotesStore(settings, root: () async => dir('appunti')),
      secrets: secrets,
      transport: drive.call,
      oauthFactory: (_, _) => _FakeOAuth(),
      stateDir: () async => dir('stato'),
      builtInClientId: '1a2b3c4d-1111-2222-3333-444455556666',
      deviceName: 'PC',
    );

    test('due sincronizzazioni quasi insieme: ne parte una sola', () async {
      final od = service();
      await write(File(p.join(dir('appunti').path, 'Analisi', 'a.md')), 'x');
      final results = await Future.wait([od.sync(), od.sync(), od.sync()]);
      expect(results.whereType<SyncReport>().length, 1);
      expect(results.whereType<SyncReport>().single.uploaded, 1);
      // un solo giro: un solo caricamento (prima partivano tutti e tre, sugli
      // stessi file di stato)
      expect(drive.log.where((l) => l.startsWith('PUT')).length, 1);
      expect(od.syncing, isFalse);
    });

    test('sincronizzazione già in corso altrove (Android in background): si '
        'aspetta il giro successivo', () async {
      final od = service();
      CloudDriveService.busyElsewhere = () async => true;
      expect(await od.sync(), isNull);
      expect(drive.requests, 0);
      expect(od.syncing, isFalse);
      // controllo che non risponde: si sincronizza come sempre
      CloudDriveService.busyElsewhere = () async => throw Exception('canale');
      expect(await od.sync(), isNotNull);
    });

    test('Google Drive: accesso vecchio rifiutato e portachiavi rotto, la '
        'sincronizzazione non lancia errori', () async {
      final broken = _BrokenDeleteSecrets();
      await broken.write('gdrive.refreshToken', 'vecchio');
      final gd = GoogleDriveService(
        settings,
        NotesStore(settings, root: () async => dir('appunti')),
        secrets: broken,
        transport: FakeGoogleDrive().call,
        oauthFactory: (_, _) =>
            _FakeOAuth(reject: 'Google ha rifiutato l\'accesso: invalid_grant'),
        stateDir: () async => dir('stato_gd'),
        builtInClientId: 'cid.apps.googleusercontent.com',
        builtInClientSecret: 's',
        deviceName: 'PC',
      );
      expect(await gd.sync(auto: true), isNull);
      expect(gd.lastError, contains('invalid_grant'));
      expect(gd.syncing, isFalse);
    });
  });

  group('rete', () {
    test('il servizio accetta la connessione ma non risponde: tempo scaduto, '
        'nessuna attesa infinita', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((_) {}); // mai una risposta
      networkIdleTimeout = const Duration(milliseconds: 300);
      final url = Uri.parse('http://127.0.0.1:${server.port}/x');
      Object? error;
      try {
        await ioTransport('GET', url);
      } catch (e) {
        error = e;
      }
      expect(error, isA<TimeoutException>());
      expect(isNetworkError(error!), isTrue);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('scaricamento fermo a metà: tempo scaduto, si riprova dopo', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.contentLength = 1000;
        req.response.add(List.filled(100, 65));
        await req.response.flush();
        // il resto non arriva mai
      });
      networkIdleTimeout = const Duration(milliseconds: 300);
      final to = File(p.join(tmp.path, 'parziale.bin'));
      Object? error;
      try {
        await ioDownload(Uri.parse('http://127.0.0.1:${server.port}/f'), to);
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      expect(isNetworkError(error!), isTrue);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('rinnovo dell\'accesso con una risposta strana: errore leggibile',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final bodies = ['[1, 2]', '{"access_token": 5}', '"testo"'];
      var i = 0;
      server.listen((req) async {
        await req.drain<void>();
        req.response.headers.contentType = ContentType.json;
        req.response.write(bodies[i++ % bodies.length]);
        await req.response.close();
      });
      final oauth = LoopbackOAuth(
        providerName: 'Microsoft',
        authEndpoint: Uri.parse('http://127.0.0.1:${server.port}/auth'),
        tokenEndpoint: Uri.parse('http://127.0.0.1:${server.port}/token'),
        clientId: 'x',
        scope: 's',
        openBrowser: (_) async => true,
      );
      for (var k = 0; k < bodies.length; k++) {
        await expectLater(oauth.refresh('r'), throwsA(isA<OAuthException>()));
      }
    });
  });

  test('widget: giorni mancanti giusti a cavallo dell\'ora legale', () {
    // 28/3/2027: in Italia si passa all'ora legale (giornata di 23 ore)
    final item = AgendaItem(
      key: examAgendaKey(1),
      kind: AgendaKind.exam,
      title: 'Esame: Analisi I',
      subject: 'Analisi I',
      date: DateTime(2027, 3, 29),
      examId: 1,
    );
    final exams =
        widgetPayload([item], DateTime(2027, 3, 27, 10))['exams'] as List;
    final e = exams.single as Map;
    expect(e['days'], 2);
    expect(e['daysLabel'], 'Tra 2 giorni');
  });

  test('dati dell\'app: un valore infinito nel database non blocca '
      'l\'unione', () async {
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    await db.db.insert('courses', {
      'name': 'Analisi I',
      'cfu': double.infinity,
    });
    final sync = DataSync(db, stateDir: () async => tmp);
    final dati = Directory(p.join(tmp.path, 'dati'));
    final r = await sync.mergeFolder(
      dati,
      ownName: DataSync.ownFileName('PC', 'a1'),
      device: 'PC',
      installId: 'a1',
    );
    expect(r.ownChanged, isTrue);
    final own = File(p.join(dati.path, DataSync.ownFileName('PC', 'a1')));
    final snap = SyncSnapshot.decode(await own.readAsBytes())!;
    final row = snap.tables['courses']!.values.single;
    expect(row.values['name'], 'Analisi I');
    expect(row.values.containsKey('cfu'), isFalse);
  });

  test('promemoria senza avvio (motore in background): le notifiche si '
      'preparano prima di pianificarle', () async {
    final db = await AppDatabase.openInMemory();
    final platform = _NeedsInitPlatform();
    final s = AppServices(
      db,
      reminders: (s) => RemindersService(
        s,
        platform: platform,
        calendarBackend: FakeCalendarBackend(),
        widgets: FakeHomeWidgets(),
        platformName: 'android',
        isRecording: () => false,
      ),
    );
    addTearDown(db.close);
    final c = await s.courses.insert(const Course(name: 'Analisi I'));
    await s.exams.insert(Exam(courseId: c, date: DateTime(2027, 2, 10)));
    await s.settings.set(NotificationKeys.consent, '1');
    await s.reminders.refresh(now: DateTime(2027, 1, 20, 10));
    expect(s.reminders.started, isFalse);
    expect(platform.inits, greaterThan(0));
    expect(platform.scheduled, isNotEmpty);
  });
}
