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
