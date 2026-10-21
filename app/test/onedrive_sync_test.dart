import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/cloud/onedrive_sync.dart';
import 'package:university_notes/features/cloud/onenote.dart';

import 'support/fake_drive.dart';

void main() {
  late Directory tmp;
  late FakeDrive drive;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('um_onedrive_');
    drive = FakeDrive();
  });
  tearDown(() => tmp.delete(recursive: true));

  OneDriveSync device(String name) {
    final graph = GraphClient(() async => 'token', transport: drive.call);
    return OneDriveSync(
      graph: graph,
      localRoot: Directory(p.join(tmp.path, name, 'Corsi')),
      remoteFolder: 'Appunti università',
      stateFile: File(p.join(tmp.path, name, 'state.json')),
      deviceName: name,
      now: () => DateTime(2026, 10, 4, 15, 30),
    );
  }

  File f(OneDriveSync d, String rel) =>
      File(p.joinAll([d.localRoot.path, ...rel.split('/')]));

  Future<void> write(OneDriveSync d, String rel, String text) async {
    final file = f(d, rel);
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
    // mtime diverso anche su file system con risoluzione al secondo.
    await file.setLastModified(
      DateTime.now().add(Duration(seconds: text.length)),
    );
  }

  const lesson =
      'PoliTo - Analisi matematica I/Trascrizioni/2026-10-05 Lezione.md';

  test(
    'PC carica, telefono scarica; modifiche e cancellazioni viaggiano',
    () async {
      final pc = device('PC');
      final phone = device('telefono');
      await write(pc, lesson, 'limiti');
      await write(pc, '.appunti.json', '{}'); // escluso
      var r = await pc.run();
      expect(r.uploaded, 1);
      expect(drive.files.keys, ['Appunti università/$lesson']);

      r = await phone.run();
      expect(r.downloaded, 1);
      expect(await f(phone, lesson).readAsString(), 'limiti');

      // Niente da fare se nessuno cambia nulla.
      expect((await pc.run()).changed, isFalse);

      await write(phone, lesson, 'limiti e derivate');
      expect((await phone.run()).uploaded, 1);
      expect((await pc.run()).downloaded, 1);
      expect(await f(pc, lesson).readAsString(), 'limiti e derivate');

      await f(pc, lesson).delete();
      expect((await pc.run()).deletedRemote, 1);
      expect(drive.trash, ['Appunti università/$lesson']);
      expect((await phone.run()).deletedLocal, 1);
      expect(await f(phone, lesson).exists(), isFalse);
      expect(
        await File(
          p.joinAll([
            phone.localRoot.path,
            OneDriveSync.trashDir,
            ...lesson.split('/'),
          ]),
        ).exists(),
        isTrue,
      );
    },
  );

  test('conflitto: si tengono entrambe le versioni', () async {
    final pc = device('PC');
    final phone = device('telefono');
    await write(pc, lesson, 'v1');
    await pc.run();
    await phone.run();
    await write(pc, lesson, 'versione del PC');
    await write(phone, lesson, 'versione del telefono!');
    await pc.run();
    final r = await phone.run();
    expect(r.conflicts, 1);
    expect(await f(phone, lesson).readAsString(), 'versione del PC');
    final copy = phone.conflictName(lesson);
    expect(copy, contains('(conflitto telefono 2026-10-04 15.30).md'));
    expect(await f(phone, copy).readAsString(), 'versione del telefono!');
    await pc.run();
    expect(await f(pc, copy).readAsString(), 'versione del telefono!');
  });

  test(
    'prima sincronizzazione con lo stesso file da entrambe le parti',
    () async {
      final pc = device('PC');
      final phone = device('telefono');
      await write(pc, lesson, 'uguale');
      await pc.run();
      await write(phone, lesson, 'uguale');
      final r = await phone.run();
      expect(r.changed, isFalse);
      expect(drive.files.length, 1);
    },
  );

  test(
    'scaricamento non riuscito: il file buono resta, niente «.part»',
    () async {
      final pc = device('PC');
      var fail = false;
      final phone = OneDriveSync(
        graph: GraphClient(
          () async => 'token',
          transport: (m, u, {headers = const {}, body}) async =>
              fail && u.host == 'dl.example'
              ? GraphResponse(500, Uint8List.fromList(utf8.encode('{}')))
              : drive.call(m, u, headers: headers, body: body),
        ),
        localRoot: Directory(p.join(tmp.path, 'telefono', 'Corsi')),
        remoteFolder: 'Appunti università',
        stateFile: File(p.join(tmp.path, 'telefono', 'state.json')),
        deviceName: 'telefono',
      );
      await write(pc, lesson, 'v1');
      await pc.run();
      await phone.run();
      await write(pc, lesson, 'versione 2');
      await pc.run();
      fail = true;
      final r = await phone.run();
      expect(r.errors.single, contains('Lezione.md'));
      expect(await f(phone, lesson).readAsString(), 'v1');
      expect(await File('${f(phone, lesson).path}.part').exists(), isFalse);
      fail = false;
      expect((await phone.run()).downloaded, 1);
      expect(await f(phone, lesson).readAsString(), 'versione 2');
    },
  );

  test(
    'ioDownload: il corpo va sul file a pezzi; gli errori non lo toccano',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        if (req.uri.path == '/ok') {
          for (var i = 0; i < 3; i++) {
            req.response.add(List.filled(1000, 65 + i));
            await req.response.flush();
          }
        } else {
          req.response
            ..statusCode = 403
            ..write('{"error":{"message":"Accesso negato"}}');
        }
        await req.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final ok = File(p.join(tmp.path, 'ok.bin'));
      final r = await ioDownload(Uri.parse('$base/ok'), ok);
      expect(r.status, 200);
      expect(r.body, isEmpty);
      final bytes = await ok.readAsBytes();
      expect(bytes.length, 3000);
      expect(bytes.last, 67);
      final err = File(p.join(tmp.path, 'err.bin'));
      final e = await ioDownload(Uri.parse('$base/no'), err);
      expect(e.status, 403);
      expect(e.text, contains('Accesso negato'));
      expect(await err.exists(), isFalse);
      // tramite GraphClient: errore leggibile
      await expectLater(
        GraphClient(() async => 't').download('$base/no', err, auth: false),
        throwsA(isA<GraphException>().having((x) => x.status, 'status', 403)),
      );
    },
  );

  test('senza rete: il messaggio nomina il servizio giusto', () async {
    expect(
      networkServiceName(Uri.parse('https://graph.microsoft.com/v1.0/me')),
      'Microsoft',
    );
    expect(
      networkServiceName(Uri.parse('https://contoso.sharepoint.com/f')),
      'Microsoft',
    );
    expect(
      networkServiceName(Uri.parse('https://www.googleapis.com/drive/v3/')),
      'Google',
    );
    expect(
      networkServiceName(Uri.parse('https://oauth2.googleapis.com/revoke')),
      'Google',
    );
    expect(networkServiceName(Uri.parse('https://example.com')), 'Il servizio');
    // porta chiusa: errore di rete (stato 0)
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    await expectLater(
      ioTransport('GET', Uri.parse('http://127.0.0.1:$port/')),
      throwsA(
        isA<GraphException>()
            .having((e) => e.status, 'status', 0)
            .having(
              (e) => e.message,
              'm',
              startsWith(
                'Il servizio non '
                'raggiungibile',
              ),
            ),
      ),
    );
  });

  test('file grandi: sessione di caricamento a blocchi', () async {
    final pc = device('PC');
    final big = f(pc, 'PoliTo - Chimica/Registrazioni/lezione.flac');
    await big.parent.create(recursive: true);
    final data = Uint8List.fromList(
      List.generate(OneDriveSync.chunkSize * 2 + 1234, (i) => i % 251),
    );
    await big.writeAsBytes(data);
    final r = await pc.run();
    expect(r.uploaded, 1);
    expect(
      drive
          .files['Appunti università/PoliTo - Chimica/Registrazioni/lezione.flac'],
      data,
    );
  });

  test('file aggiunti, modificati ed eliminati dal sito di OneDrive, da '
      'altre app o da OneDrive per desktop arrivano nell\'app', () async {
    final pc = device('PC');
    await write(pc, lesson, 'limiti');
    await pc.run();
    expect(await pc.needsSync(), isFalse);

    // aggiunti fuori dall'app, anche in una sottocartella nuova
    drive.put('Appunti università/Da ordinare/dispense.pdf', 'pdf');
    drive.put('Appunti università/PoliTo - Analisi matematica I/foto.jpg', 'j');
    expect(await pc.needsSync(), isTrue);
    var r = await pc.run();
    expect(r.downloaded, 2);
    expect(await f(pc, 'Da ordinare/dispense.pdf').readAsString(), 'pdf');
    expect(await pc.needsSync(), isFalse);

    // modificato fuori dall'app
    drive.put('Appunti università/Da ordinare/dispense.pdf', 'pdf v2');
    expect(await pc.needsSync(), isTrue);
    r = await pc.run();
    expect(r.downloaded, 1);
    expect(await f(pc, 'Da ordinare/dispense.pdf').readAsString(), 'pdf v2');

    // eliminato dal sito: sul dispositivo va nel cestino locale
    drive.files.remove(
      'Appunti università/PoliTo - Analisi matematica I/foto.jpg',
    );
    drive.addFolder('Appunti università/PoliTo - Analisi matematica I');
    r = await pc.run();
    expect(r.deletedLocal, 1);
    expect(
      await f(pc, 'PoliTo - Analisi matematica I/foto.jpg').exists(),
      isFalse,
    );

    // OneDrive for Business (niente /delta sulle cartelle): si rilegge tutto
    drive.deltaUnsupported = true;
    final work = device('lavoro');
    await work.run();
    drive.put('Appunti università/nuovo.md', 'n');
    expect(await work.needsSync(), isTrue);
    expect((await work.run()).downloaded, 1);
  });

  test('file temporanei e nascosti esclusi', () {
    expect(OneDriveSync.ignored('a/.appunti.json'), isTrue);
    expect(OneDriveSync.ignored('.cestino-onedrive/x.md'), isTrue);
    expect(OneDriveSync.ignored('a/b.flac.part'), isTrue);
    expect(OneDriveSync.ignored('a/~\$doc.docx'), isTrue);
    expect(OneDriveSync.ignored('a/b.md'), isFalse);
  });

  test('errori di Graph leggibili', () async {
    final g = GraphClient(
      () async => 't',
      transport: (m, u, {headers = const {}, body}) async => GraphResponse(
        403,
        Uint8List.fromList(
          utf8.encode(
            '{"error":{"code":"accessDenied","message":"Accesso negato"}}',
          ),
        ),
      ),
    );
    await expectLater(
      g.getJson('me/drive'),
      throwsA(
        isA<GraphException>().having(
          (e) => e.message,
          'msg',
          contains('Accesso negato'),
        ),
      ),
    );
    expect(
      GraphClient.drivePath('/Appunti università/a b/'),
      'Appunti%20universit%C3%A0/a%20b',
    );
  });

  test('OneNote: elementi e collegamenti', () {
    final it = OneNoteItem.from({
      'id': '1',
      'title': ' Lezione 1 ',
      'lastModifiedDateTime': '2026-10-04T10:00:00Z',
      'links': {
        'oneNoteWebUrl': {'href': 'https://onenote.example/1'},
        'oneNoteClientUrl': {'href': 'onenote:1'},
      },
      'parentSection': {'displayName': 'Analisi'},
    }, titleKey: 'title');
    expect(it.title, 'Lezione 1');
    expect(it.webUrl, 'https://onenote.example/1');
    expect(it.clientUrl, 'onenote:1');
    expect(it.parent, 'Analisi');
    expect(
      OneNoteItem.from({'id': '2', 'displayName': ''}).title,
      '(senza titolo)',
    );
  });

  test('PKCE condiviso tra Google e Microsoft', () {
    expect(
      LoopbackOAuth.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });
}
