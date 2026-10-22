// «Apri con…»: la scelta dell'app del sistema passa dal canale nativo
// (Windows SHOpenWithDialog, macOS pannello Applicazioni, Android
// createChooser, iOS «Apri in…»); «Apri» resta l'app predefinita.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/services/external_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late File file;
  final calls = <MethodCall>[];
  var reply = 'ok';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('um_open_with_');
    file = File(p.join(tmp.path, 'Slide lezione 3.pptx'))..writeAsStringSync('x');
    calls.clear();
    reply = 'ok';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExternalLauncher.openWithChannel, (c) async {
          calls.add(c);
          if (reply == 'eccezione') {
            throw PlatformException(code: 'x', message: 'rotto');
          }
          return reply;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExternalLauncher.openWithChannel, null);
    ExternalLauncher.platform = () => defaultTargetPlatform;
    tmp.deleteSync(recursive: true);
  });

  test('scelta dell\'app: percorso al canale nativo', () async {
    ExternalLauncher.platform = () => TargetPlatform.android;
    final r = await ExternalLauncher.openWith(file.path);
    expect(r.ok, isTrue);
    expect(calls.single.method, 'openWith');
    expect((calls.single.arguments as Map)['path'], file.path);
  });

  test('scelta chiusa dall\'utente: nessun messaggio', () async {
    reply = 'annullato';
    final r = await ExternalLauncher.openWith(file.path);
    expect(r.ok, isTrue);
    expect(r.message, isNull);
  });

  test('nessuna app o errore: messaggio', () async {
    reply = 'nessuna_app';
    var r = await ExternalLauncher.openWith(file.path);
    expect(r.ok, isFalse);
    expect(r.message, ExternalLauncher.noAppMessage);
    reply = 'errore';
    r = await ExternalLauncher.openWith(file.path);
    expect(r.ok, isFalse);
    reply = 'eccezione';
    r = await ExternalLauncher.openWith(file.path);
    expect(r.message, contains('rotto'));
  });

  test('programmi e percorsi di rete: mai aperti', () async {
    final exe = File(p.join(tmp.path, 'setup.exe'))..writeAsStringSync('x');
    final r = await ExternalLauncher.openWith(exe.path);
    expect(r.ok, isFalse);
    expect(r.message, contains('programmi'));
    expect(
      (await ExternalLauncher.openWith(r'\\server\cartella\a.pdf')).ok,
      isFalse,
    );
    expect(calls, isEmpty);
  });
}
