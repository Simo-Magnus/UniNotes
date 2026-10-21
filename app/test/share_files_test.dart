import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:university_notes/widgets/share_files.dart';

void main() {
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          // come il plugin di Windows: sempre «non disponibile»
          return 'dev.fluttercommunity.plus/share/unavailable';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<BuildContext> host(WidgetTester t) async {
    late BuildContext ctx;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    return ctx;
  }

  testWidgets('Windows: «non disponibile» vale come finestra aperta, con '
      'titolo e tutti i campi', (t) async {
    final ctx = await host(t);
    late bool shown;
    await t.runAsync(() async {
      shown = await systemShare(
        ctx,
        ShareParams(files: [XFile(r'C:\Appunti\lezione.m4a')]),
        windows: true,
        windowsBuild: 26100,
      );
    });
    expect(shown, isTrue);
    final args = calls.single.arguments as Map;
    // il plugin ricorda i campi della condivisione prima: si mandano tutti
    expect(args['text'], '');
    expect(args['uri'], '');
    expect(args['title'], 'Condividi da UniNotes');
    expect(args['paths'], [r'C:\Appunti\lezione.m4a']);
  });

  testWidgets('altri sistemi: «non disponibile» porta al ripiego', (t) async {
    final ctx = await host(t);
    late bool shown;
    await t.runAsync(() async {
      shown = await systemShare(
        ctx,
        ShareParams(text: 'ciao', subject: 'Oggetto'),
        windows: false,
      );
    });
    expect(shown, isFalse);
    final args = calls.single.arguments as Map;
    expect(args['text'], 'ciao');
    expect(args.containsKey('paths'), isFalse);
  });

  test('percorsi per Windows: assoluti e con «\\»', () {
    expect(
      sharePath('C:/Utenti/Ada/Appunti/../Appunti/a.md', windows: true),
      r'C:\Utenti\Ada\Appunti\a.md',
    );
    expect(sharePath('/home/ada/a.md', windows: false), '/home/ada/a.md');
  });
}
