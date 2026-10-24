import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:university_notes/core/reminders/notification_platform.dart';
import 'package:university_notes/core/reminders/windows_aumid.dart';
import 'package:university_notes/core/reminders/windows_toast_icon.dart';

/// AUMID nuovo dei toast di Windows (24/10/2026): versione del sito con
/// `SimoMagnus.UniNotes` (logo in cima ai toast), MSIX invariato, passaggio
/// una volta sola dall'AUMID vecchio.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AUMID', () {
    test('non pacchettizzata: nuovo; MSIX: come prima', () {
      expect(WindowsAumid.of(packaged: false), 'SimoMagnus.UniNotes');
      expect(
        WindowsAumid.of(packaged: true),
        'io.github.simomagnus.universitynotes',
      );
    });

    test('inizializzazione del pacchetto delle notifiche', () {
      final site = LocalNotificationPlatform.windowsSettings(
        packaged: false,
        iconPath: r'C:\App\data\flutter_assets\assets\notifiche\uninotes.png',
      );
      expect(site.appName, 'UniNotes');
      expect(site.appUserModelId, WindowsAumid.current);
      expect(site.iconPath, endsWith('uninotes.png'));
      final store = LocalNotificationPlatform.windowsSettings(packaged: true);
      expect(store.appUserModelId, WindowsAumid.legacy);
      // stesso GUID di attivazione in entrambe (manifest MSIX invariato)
      expect(store.guid, site.guid);
    });

    test('chiave del registro dell\'icona sull\'AUMID nuovo', () {
      expect(
        WindowsToastIcon.keyFor(WindowsAumid.current),
        r'HKCU\Software\Classes\AppUserModelId\SimoMagnus.UniNotes',
      );
    });

    test('installatore, runner e manifest MSIX allineati', () {
      final guid = LocalNotificationPlatform.windowsSettings(
        packaged: false,
      ).guid;
      final iss = File('windows/installer/uninotes.iss').readAsStringSync();
      final shortcuts = iss
          .split('\n')
          .where((l) => l.startsWith('Name: "{auto'))
          .toList();
      expect(shortcuts, hasLength(2));
      for (final l in shortcuts) {
        expect(l, contains('AppUserModelID: "${WindowsAumid.current}"'));
        expect(l, contains('AppUserModelToastActivatorCLSID: "$guid"'));
      }
      // la chiave nuova e la vecchia si tolgono con il programma
      expect(
        iss,
        contains(
          'AppUserModelId\\${WindowsAumid.current}"; '
          'Flags: uninsdeletekey dontcreatekey',
        ),
      );
      expect(
        iss,
        contains(
          'AppUserModelId\\${WindowsAumid.legacy}"; '
          'Flags: uninsdeletekey dontcreatekey',
        ),
      );
      final runner = File(
        'windows/runner/notification_identity.cpp',
      ).readAsStringSync();
      expect(runner, contains('L"${WindowsAumid.current}"'));
      expect(runner, contains('"${WindowsAumidMigration.channelName}"'));
      final manifest = File(
        'windows/msix/AppxManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('ToastActivatorCLSID="$guid"'));
    });
  });

  group('passaggio dall\'AUMID vecchio', () {
    const channel = MethodChannel(WindowsAumidMigration.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      calls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'rimossi': 3, 'pacchetto': false};
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('una volta sola, con l\'AUMID vecchio', () async {
      final m = WindowsAumidMigration();
      expect(await m.run(packaged: false), isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'migraAumid');
      expect(calls.single.arguments, {'vecchio': WindowsAumid.legacy});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(WindowsAumidMigration.doneKey), isTrue);
      // avvii successivi: niente
      expect(await m.run(packaged: false), isFalse);
      expect(await WindowsAumidMigration().run(packaged: false), isFalse);
      expect(calls, hasLength(1));
    });

    test('MSIX: nessuna chiamata, nessun flag', () async {
      expect(await WindowsAumidMigration().run(packaged: true), isFalse);
      expect(calls, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(WindowsAumidMigration.doneKey), isNull);
    });

    test('errore del codice nativo: avvio non bloccato, si riprova', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        throw PlatformException(code: 'argomenti');
      });
      expect(await WindowsAumidMigration().run(packaged: false), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(WindowsAumidMigration.doneKey), isNull);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'rimossi': 0, 'pacchetto': false};
      });
      expect(await WindowsAumidMigration().run(packaged: false), isTrue);
      expect(calls, hasLength(2));
    });

    test('canale assente: nessun errore', () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(await WindowsAumidMigration().run(packaged: false), isFalse);
    });
  });
}
