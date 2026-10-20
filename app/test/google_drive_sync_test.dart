import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/features/cloud/google_drive_client.dart';
import 'package:university_notes/features/cloud/google_drive_sync.dart';
import 'package:university_notes/features/cloud/google_oauth.dart';

import 'support/fake_google_drive.dart';

void main() {
  late Directory tmp;
  late FakeGoogleDrive drive;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('um_gdrive_');
    drive = FakeGoogleDrive();
  });
  tearDown(() => tmp.delete(recursive: true));

  GoogleDriveSync device(String name) => GoogleDriveSync(
    drive: GoogleDriveClient(() async => 'token', transport: drive.call),
    localRoot: Directory(p.join(tmp.path, name, 'Corsi')),
    remoteFolder: 'UniNotes/Corsi',
    stateFile: File(p.join(tmp.path, name, 'state.json')),
    deviceName: name,
    now: () => DateTime(2026, 10, 4, 15, 30),
  );

  File f(GoogleDriveSync d, String rel) =>
      File(p.joinAll([d.localRoot.path, ...rel.split('/')]));

  Future<void> write(GoogleDriveSync d, String rel, String text) async {
    final file = f(d, rel);
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
    await file.setLastModified(
      DateTime.now().add(Duration(seconds: text.length)),
    );
  }

  const lesson = "PoliTo - Analisi I/Trascrizioni/2026-10-05 L'esame.md";
  const remote = 'UniNotes/Corsi/$lesson';

  test('PC carica, telefono scarica; modifiche e cancellazioni', () async {
    final pc = device('PC');
    final phone = device('telefono');
    await write(pc, lesson, 'limiti');
    await write(pc, '.appunti.json', '{}'); // escluso
    var r = await pc.run();
    expect(r.errors, isEmpty);
    expect(r.uploaded, 1);
    expect(drive.files, {remote: 'limiti'});

    r = await phone.run();
    expect(r.downloaded, 1);
    expect(await f(phone, lesson).readAsString(), 'limiti');
    // cartelle create una volta sola, nessun doppione
    expect(drive.folders, [
      'UniNotes',
      'UniNotes/Corsi',
      'UniNotes/Corsi/PoliTo - Analisi I',
      'UniNotes/Corsi/PoliTo - Analisi I/Trascrizioni',
    ]);

    expect((await pc.run()).changed, isFalse);

    await write(phone, lesson, 'limiti e derivate');
    expect((await phone.run()).uploaded, 1);
    expect(drive.files, {remote: 'limiti e derivate'}); // stesso file
    expect((await pc.run()).downloaded, 1);
    expect(await f(pc, lesson).readAsString(), 'limiti e derivate');

    await f(pc, lesson).delete();
    expect((await pc.run()).deletedRemote, 1);
    expect(drive.trash, [remote]);
    expect((await phone.run()).deletedLocal, 1);
    expect(await f(phone, lesson).exists(), isFalse);
    expect(
      await File(
        p.joinAll([
          phone.localRoot.path,
          GoogleDriveSync.trashDir,
          ...lesson.split('/'),
        ]),
      ).exists(),
      isTrue,
    );
  });

  test('conflitto: si tengono entrambe le versioni', () async {
    final pc = device('PC');
    final phone = device('telefono');
    await write(pc, 'a.md', 'uno');
    await pc.run();
    await phone.run();
    await write(pc, 'a.md', 'dal PC');
    await write(phone, 'a.md', 'dal telefono!');
    await pc.run();
    final r = await phone.run();
    expect(r.conflicts, 1);
    expect(await f(phone, 'a.md').readAsString(), 'dal PC');
    expect(
      await f(
        phone,
        'a (conflitto telefono 2026-10-04 15.30).md',
      ).readAsString(),
      'dal telefono!',
    );
    expect(drive.files.length, 2);
  });

  test('prima sincronizzazione: stessa dimensione, contenuto confrontato con '
      'l\'MD5 di Drive (diverso = conflitto)', () async {
    final pc = device('PC');
    final phone = device('telefono');
    await write(pc, 'a.md', 'abc');
    await write(pc, 'b.md', 'xyz');
    await pc.run();
    // sul telefono gli stessi file copiati a mano, uno con contenuto diverso
    await write(phone, 'a.md', 'abd');
    await write(phone, 'b.md', 'xyz');
    final r = await phone.run();
    expect(r.errors, isEmpty);
    expect(r.conflicts, 1);
    expect(r.uploaded + r.downloaded, 0);
    expect(await f(phone, 'a.md').readAsString(), 'abc');
    expect(
      await f(
        phone,
        'a (conflitto telefono 2026-10-04 15.30).md',
      ).readAsString(),
      'abd',
    );
    expect(await f(phone, 'b.md').readAsString(), 'xyz');
    expect(drive.files.length, 3);
    expect((await phone.run()).changed, isFalse);
  });

  test(
    'scaricamento non riuscito: il file buono resta, niente «.part»',
    () async {
      final pc = device('PC');
      var fail = false;
      final phone = GoogleDriveSync(
        drive: GoogleDriveClient(
          () async => 'token',
          transport: (m, u, {headers = const {}, body}) async =>
              fail && u.queryParameters['alt'] == 'media'
              ? GraphResponse(500, Uint8List.fromList(utf8.encode('{}')))
              : drive.call(m, u, headers: headers, body: body),
        ),
        localRoot: Directory(p.join(tmp.path, 'telefono', 'Corsi')),
        remoteFolder: 'UniNotes/Corsi',
        stateFile: File(p.join(tmp.path, 'telefono', 'state.json')),
        deviceName: 'telefono',
      );
      await write(pc, 'a.md', 'uno');
      await pc.run();
      await phone.run();
      await write(pc, 'a.md', 'due!');
      await pc.run();
      fail = true;
      final r = await phone.run();
      expect(r.errors.single, contains('a.md'));
      expect(await f(phone, 'a.md').readAsString(), 'uno');
      expect(await File('${f(phone, 'a.md').path}.part').exists(), isFalse);
      fail = false;
      expect((await phone.run()).downloaded, 1);
      expect(await f(phone, 'a.md').readAsString(), 'due!');
    },
  );

  test('controllo leggero con le modifiche di Drive', () async {
    final pc = device('PC');
    final phone = device('telefono');
    await write(pc, 'a.md', 'uno');
    await pc.run();
    await phone.run();
    expect(await pc.needsSync(), isFalse);
    await write(phone, 'a.md', 'due!');
    await phone.run();
    expect(await pc.needsSync(), isTrue);
    await pc.run();
    expect(await pc.needsSync(), isFalse);
    await write(pc, 'b.md', 'nuovo');
    expect(await pc.needsSync(), isTrue); // file locale nuovo
  });

  test('file grandi: caricamento ripristinabile a blocchi', () async {
    final pc = device('PC');
    final big = f(pc, 'Libri/manuale.pdf');
    await big.parent.create(recursive: true);
    final size = GoogleDriveSync.chunkSize + 1000;
    await big.writeAsBytes(List.filled(size, 65));
    final r = await pc.run();
    expect(r.errors, isEmpty);
    expect(drive.resumableChunks, 2);
    expect(drive.files['UniNotes/Corsi/Libri/manuale.pdf']!.length, size);
    // aggiornamento dello stesso file, sempre a blocchi
    await big.writeAsBytes(List.filled(size + 1, 66));
    expect((await pc.run()).uploaded, 1);
    expect(drive.files.length, 1);
  });

  test('drive.file: file aggiunto dal sito nella cartella invisibile finché '
      'non si importa; il resto del Drive non conta', () async {
    drive.driveFileScope = true;
    final pc = device('PC');
    await write(pc, 'a.md', 'uno');
    await pc.run();
    expect(await pc.needsSync(), isFalse);
    // modifica fuori dalla cartella dell'app
    drive.grant(drive.add('root', 'foto.jpg', 'image/jpeg', [1, 2, 3]).id);
    expect(await pc.needsSync(), isFalse);
    // file caricato dal sito di Drive nella cartella dell'app: l'app non lo
    // vede (né lo considera eliminato)
    final corsi = drive.items.values.firstWhere((i) => i.name == 'Corsi');
    final pdf = drive.add(corsi.id, 'esercizi.pdf', 'application/pdf', [7, 7]);
    expect(await pc.needsSync(), isFalse);
    expect((await pc.run()).changed, isFalse);
    // scelto con «Importa da Drive» (Picker): da ora si sincronizza
    drive.grant(pdf.id);
    expect(await pc.needsSync(), isTrue);
    final r = await pc.run();
    expect(r.downloaded, 1);
    expect(await f(pc, 'esercizi.pdf').readAsBytes(), [7, 7]);
  });

  test('sottocartella nuova con un file visibile all\'app (da un altro '
      'dispositivo o importato): arriva', () async {
    final pc = device('PC');
    await write(pc, 'a.md', 'uno');
    await pc.run();
    final corsi = drive.items.values.firstWhere((i) => i.name == 'Corsi');
    final sub = drive.add(corsi.id, 'Fisica', GoogleDriveClient.folderMime);
    drive.add(sub.id, 'esercizi.pdf', 'application/pdf', [7, 7, 7]);
    expect(await pc.needsSync(), isTrue);
    final r = await pc.run();
    expect(r.downloaded, 1);
    expect(await f(pc, 'Fisica/esercizi.pdf').readAsBytes(), [7, 7, 7]);
  });

  test(
    'nomi remoti pericolosi ignorati: nessun file fuori dalla cartella',
    () async {
      final pc = device('PC');
      await write(pc, 'a.md', 'uno');
      await pc.run();
      final corsi = drive.items.values.firstWhere((i) => i.name == 'Corsi');
      drive.add(corsi.id, r'x\..\..\..\evil.cmd', 'text/plain', [1]);
      drive.add(corsi.id, '..', 'text/plain', [2]);
      drive.add(corsi.id, 'CON.txt', 'text/plain', [3]);
      final r = await pc.run();
      expect(r.downloaded, 0);
      expect(r.errors.length, 3);
      expect(
        tmp.listSync(recursive: true).whereType<File>().map((f) => f.path),
        everyElement(isNot(contains('evil'))),
      );
      expect(FolderSync.safeRel('Analisi/Riassunti/r.md'), isTrue);
      expect(FolderSync.safeRel('a/../b'), isFalse);
      expect(FolderSync.safeRel(r'a\b'), isFalse);
    },
  );

  test(
    'cartella eliminata dal sito: i file si ricaricano, non si cancellano',
    () async {
      final pc = device('PC');
      await write(pc, 'a.md', 'uno');
      await write(pc, 'b.md', 'due!');
      await pc.run();
      for (final it in drive.items.values) {
        it.trashed = true; // l'utente cestina la cartella UniNotes dal sito
      }
      final r = await pc.run();
      expect(r.deletedLocal, 0);
      expect(r.uploaded, 2);
      expect(await f(pc, 'a.md').exists(), isTrue);
      expect(drive.files.length, 2);
    },
  );

  test('selettore delle cartelle di Google Drive', () async {
    final browser = GoogleDriveFolderBrowser(
      GoogleDriveClient(() async => 'token', transport: drive.call),
    );
    expect(await browser.children(browser.root), isEmpty);
    final un = await browser.createFolder(browser.root, 'UniNotes');
    expect(un.path, 'UniNotes');
    await browser.createFolder(un, 'Corsi');
    expect((await browser.children(un)).map((d) => d.name), ['Corsi']);
    await expectLater(
      browser.createFolder(browser.root, 'UniNotes'),
      throwsA(isA<DriveException>()),
    );
    expect(browser.validate('a/b'), isNotNull);
  });

  test('documenti Google (senza file) ignorati', () async {
    final pc = device('PC');
    await pc.run();
    final corsi = drive.items.values.firstWhere((i) => i.name == 'Corsi');
    drive.add(corsi.id, 'Note', 'application/vnd.google-apps.document');
    final r = await pc.run();
    expect(r.downloaded, 0);
    expect(r.errors, isEmpty);
  });

  test('accesso Google: schema di ritorno ed errori leggibili', () {
    expect(
      GoogleOAuth.reverseScheme('123-abc.apps.googleusercontent.com'),
      'com.googleusercontent.apps.123-abc',
    );
    expect(
      GoogleOAuth.explain('redirect_uri_mismatch'),
      contains('App desktop'),
    );
    expect(GoogleOAuth.explain('boh'), 'boh');
    expect(GoogleDriveClient.quote("L'esame"), r"'L\'esame'");
  });
}
