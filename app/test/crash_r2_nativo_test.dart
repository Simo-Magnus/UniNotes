import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/system_speech.dart';

/// Caccia ai crash, secondo giro, categoria «codice nativo e differenze tra
/// piattaforme» (R2-C): canali che non rispondono e impostazioni native che,
/// se mancano, fanno chiudere l'app dal sistema.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(SystemSpeech.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> fromSystem(String method, Map<String, Object?> args) =>
      messenger.handlePlatformMessage(
        SystemSpeech.channelName,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('riconoscitore del sistema che non risponde a «start»', () {
    test('start finisce con false entro il limite e chiude la sessione', () async {
      final calls = <String>[];
      final never = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (c) {
        calls.add(c.method);
        // iOS 26 con il modello della lingua in download senza rete:
        // nessuna risposta
        if (c.method == 'start') return never.future;
        return Future.value(null);
      });
      final speech = SystemSpeech(
        startTimeout: const Duration(milliseconds: 50),
      );
      final events = <SpeechEvent>[];
      final sub = speech.events.listen(events.add);
      final ok = await speech
          .start(locale: 'it-IT')
          .timeout(const Duration(seconds: 5));
      expect(ok, isFalse);
      // il lato nativo riceve «stop» (niente riconoscitore lasciato acceso)
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['start', 'stop']);
      // un testo arrivato dopo, con il numero della sessione scaduta, si
      // scarta
      await fromSystem('result', {'session': 1, 'text': 'in ritardo'});
      expect(events, isEmpty);
      await sub.cancel();
      await speech.dispose();
    });

    test('il testo dal vivo passa al motore successivo invece di restare '
        '«in avvio»', () async {
      messenger.setMockMethodCallHandler(channel, (c) {
        if (c.method == 'support') {
          return Future.value({'available': true, 'onDevice': true});
        }
        if (c.method == 'start') return Completer<Object?>().future;
        return Future.value(null);
      });
      final live = LiveTranscriber(
        null,
        speech: SystemSpeech(startTimeout: const Duration(milliseconds: 50)),
      );
      await live
          .begin(File('x.wav'), sampleRate: 16000, channels: 1)
          .timeout(const Duration(seconds: 5));
      // senza Whisper né Parakeet: nessun motore, ma lo stato non resta
      // «starting» per tutta la lezione
      expect(live.state, isNot(LiveState.starting));
      expect(live.engine, isNot(LiveEngine.system));
      await live.close();
    });

    test('risposta normale: nessun cambiamento', () async {
      messenger.setMockMethodCallHandler(channel, (c) async {
        return c.method == 'start' ? true : null;
      });
      final speech = SystemSpeech(
        startTimeout: const Duration(milliseconds: 200),
      );
      final events = <SpeechEvent>[];
      final sub = speech.events.listen(events.add);
      expect(await speech.start(locale: 'it-IT'), isTrue);
      await fromSystem('result', {'session': 1, 'text': 'buongiorno'});
      expect(events.single.text, 'buongiorno');
      await sub.cancel();
      await speech.dispose();
    });
  });

  group('impostazioni native senza le quali il sistema chiude l\'app', () {
    String read(String path) => File(path).readAsStringSync();

    test('iOS: tutte le chiavi d\'uso delle funzioni che l\'app chiede', () {
      final plist = read('ios/Runner/Info.plist');
      for (final key in [
        // registratore
        'NSMicrophoneUsageDescription',
        // testo dal vivo (SFSpeechRecognizer / SpeechAnalyzer)
        'NSSpeechRecognitionUsageDescription',
        // calendario (requestFullAccessToEvents da iOS 17, requestAccess prima)
        'NSCalendarsFullAccessUsageDescription',
        'NSCalendarsUsageDescription',
        // «Salva immagine/video» nel foglio Condividi
        'NSPhotoLibraryAddUsageDescription',
      ]) {
        expect(plist, contains('<key>$key</key>'), reason: key);
      }
    });

    test('iOS: il compito della sincronizzazione è fra quelli permessi', () {
      final plist = read('ios/Runner/Info.plist');
      final swift = read('ios/Runner/AppDelegate.swift');
      final id = RegExp(
        r'static let syncTaskId = "([^"]+)"',
      ).firstMatch(swift)!.group(1)!;
      // BGTaskScheduler.register con un identificativo non dichiarato
      // chiude l'app all'avvio (NSInternalInconsistencyException)
      final permitted = RegExp(
        r'<key>BGTaskSchedulerPermittedIdentifiers</key>\s*<array>([\s\S]*?)</array>',
      ).firstMatch(plist)!.group(1)!;
      expect(permitted, contains('<string>$id</string>'));
      // BGAppRefreshTask richiede la modalità «fetch»
      final modes = RegExp(
        r'<key>UIBackgroundModes</key>\s*<array>([\s\S]*?)</array>',
      ).firstMatch(plist)!.group(1)!;
      expect(modes, contains('<string>fetch</string>'));
      expect(modes, contains('<string>audio</string>'));
    });

    test('macOS: chiavi d\'uso e permessi della sandbox', () {
      final plist = read('macos/Runner/Info.plist');
      for (final key in [
        'NSMicrophoneUsageDescription',
        'NSSpeechRecognitionUsageDescription',
        'NSCalendarsFullAccessUsageDescription',
        'NSCalendarsUsageDescription',
      ]) {
        expect(plist, contains('<key>$key</key>'), reason: key);
      }
      for (final f in [
        'macos/Runner/DebugProfile.entitlements',
        'macos/Runner/Release.entitlements',
      ]) {
        final e = read(f);
        for (final key in [
          'com.apple.security.device.audio-input',
          'com.apple.security.personal-information.calendars',
          'com.apple.security.network.client',
          'com.apple.security.files.user-selected.read-write',
        ]) {
          expect(e, contains('<key>$key</key>'), reason: '$f: $key');
        }
      }
    });

    test('Android: servizio del registratore di tipo microfono, mai '
        'riavviato dal sistema all\'accensione', () {
      final m = read('android/app/src/main/AndroidManifest.xml');
      final service = RegExp(
        r'<service\s+android:name="com\.pravera\.flutter_foreground_task\.service\.ForegroundService"[^>]*>',
      ).firstMatch(m)!.group(0)!;
      // Android 14: senza il tipo startForeground lancia
      // MissingForegroundServiceTypeException
      expect(service, contains('android:foregroundServiceType="microphone"'));
      // Android 15: un servizio «microphone» avviato da BOOT_COMPLETED
      // (RebootReceiver del pacchetto) lancia
      // ForegroundServiceStartNotAllowedException; con stopWithTask il
      // pacchetto non lo riavvia
      expect(service, contains('android:stopWithTask="true"'));
      expect(
        m,
        contains(
          'android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"',
        ),
      );
      expect(m, contains('android:name="android.permission.RECORD_AUDIO"'));
      // setPersisted del JobScheduler senza questo permesso: eccezione
      expect(
        m,
        contains('android:name="android.permission.RECEIVE_BOOT_COMPLETED"'),
      );
    });

    test('Android: ogni receiver, servizio e attività con filtri dichiara '
        'android:exported (obbligatorio da Android 12)', () {
      final m = read('android/app/src/main/AndroidManifest.xml');
      final components = RegExp(
        r'<(activity|receiver|service)\b[^>]*>',
      ).allMatches(m).map((x) => x.group(0)!).toList();
      expect(components, isNotEmpty);
      for (final c in components) {
        expect(c, contains('android:exported='), reason: c);
      }
    });

    test('Android: il controllo della sincronizzazione del calendario ha il '
        'suo permesso e non si confonde con il permesso del calendario', () {
      // senza READ_SYNC_SETTINGS getMasterSyncAutomatically lancia
      // SecurityException, che il canale traduceva in «Permesso del
      // calendario negato» anche con il calendario consentito
      final m = read('android/app/src/main/AndroidManifest.xml');
      expect(
        m,
        contains('android:name="android.permission.READ_SYNC_SETTINGS"'),
      );
      final kt = read(
        'android/app/src/main/kotlin/io/github/simomagnus/universitynotes/'
        'UniNotesCalendar.kt',
      );
      final i = kt.indexOf('getMasterSyncAutomatically');
      expect(i, greaterThan(0));
      expect(kt.substring(i - 200, i), contains('try {'));
    });
  });
}
