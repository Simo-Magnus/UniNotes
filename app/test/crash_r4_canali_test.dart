import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/notification_platform.dart';

/// Caccia ai crash, quarto giro, «contratti tra Dart e codice nativo e
/// motori che lavorano insieme» (R4-C).
///
/// La prima parte legge i sorgenti: ogni metodo che Dart chiama su un
/// canale deve esistere sul lato nativo di ogni piattaforma da cui la
/// chiamata può partire (altrimenti MissingPluginException, o peggio una
/// risposta che non arriva), con gli stessi nomi degli argomenti; ogni
/// metodo che il nativo manda a Dart deve avere chi lo riceve. Le chiamate
/// nuove in Dart senza una riga nella tabella fanno fallire il test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String read(String path) => File(path).readAsStringSync();
  String readAll(List<String> paths) => [for (final p in paths) read(p)].join(
    '\n',
  );

  group('canali: metodi e argomenti uguali in Dart e nel codice nativo', () {
    for (final c in _contracts) {
      group(c.name, () {
        final dart = readAll(c.dart);

        test('il nome del canale è lo stesso ovunque', () {
          expect(dart, contains("'${c.name}'"), reason: 'Dart: ${c.dart}');
          for (final MapEntry(key: platform, value: files) in c.native.entries) {
            expect(
              readAll(files),
              contains('"${c.name}"'),
              reason: '$platform: $files',
            );
          }
        });

        test('ogni metodo chiamato da Dart esiste dove può partire', () {
          for (final MapEntry(key: method, value: platforms)
              in c.fromDart.entries) {
            for (final platform in platforms) {
              final files = c.native[platform];
              expect(
                files,
                isNotNull,
                reason: '$method su $platform: nessun file nativo in tabella',
              );
              expect(
                readAll(files!),
                contains('"$method"'),
                reason: '«$method» non gestito su $platform ($files)',
              );
            }
          }
        });

        test('nessuna chiamata in Dart manca dalla tabella', () {
          final called = <String>{};
          final receivers = c.receivers.map(RegExp.escape).join('|');
          if (receivers.isNotEmpty) {
            called.addAll(
              RegExp(
                '\\b(?:$receivers)\\s*\\.\\s*invoke(?:List|Map)?Method'
                "(?:<[^()]*>)?\\(\\s*'(\\w+)'",
              ).allMatches(dart).map((m) => m.group(1)!),
            );
          }
          final wrappers = c.wrappers.map(RegExp.escape).join('|');
          if (wrappers.isNotEmpty) {
            called.addAll(
              RegExp(
                "\\b(?:$wrappers)(?:<[^()]*>)?\\(\\s*'(\\w+)'",
              ).allMatches(dart).map((m) => m.group(1)!),
            );
          }
          expect(called, isNotEmpty, reason: 'nessuna chiamata trovata');
          expect(
            called.difference(c.fromDart.keys.toSet()),
            isEmpty,
            reason: 'metodi chiamati da Dart ma non in tabella',
          );
        });

        test('ogni metodo mandato dal nativo ha chi lo riceve in Dart', () {
          for (final MapEntry(key: method, value: platforms)
              in c.toDart.entries) {
            expect(dart, contains("'$method'"), reason: 'Dart non gestisce $method');
            for (final platform in platforms) {
              expect(
                readAll(c.native[platform]!),
                contains('"$method"'),
                reason: '$platform non manda «$method»',
              );
            }
          }
        });

        test('gli argomenti letti dal nativo sono quelli mandati da Dart', () {
          for (final MapEntry(key: platform, value: keys) in c.args.entries) {
            final native = readAll(c.native[platform]!);
            for (final k in keys) {
              expect(dart, contains("'$k'"), reason: 'Dart non manda «$k»');
              expect(
                native,
                contains('"$k"'),
                reason: '$platform non legge «$k»',
              );
            }
          }
        });
      });
    }
  });

  group('tipi degli argomenti', () {
    test('Android: i numeri si leggono come Number (un int di Dart arriva '
        'come Int o come Long secondo il valore)', () {
      for (final f in _kotlinFiles()) {
        final src = read(f.path);
        expect(
          RegExp(r'argument<(Int|Long|Double|Float)>').hasMatch(src),
          isFalse,
          reason: f.path,
        );
        expect(
          RegExp(r'arguments as (Int|Long|Double)\b').hasMatch(src),
          isFalse,
          reason: f.path,
        );
      }
    });

    test('Windows: chi legge un int32 legge anche un int64', () {
      for (final f in Directory('windows/runner').listSync()) {
        if (f is! File || !f.path.endsWith('.cpp')) continue;
        final src = f.readAsStringSync();
        if (src.contains('get_if<int32_t>') || src.contains('get_if<int64_t>')) {
          expect(src, contains('get_if<int32_t>'), reason: f.path);
          expect(src, contains('get_if<int64_t>'), reason: f.path);
        }
      }
    });

    test('iOS e macOS: niente conversioni forzate degli argomenti', () {
      for (final path in const [
        'ios/Runner/AppDelegate.swift',
        'ios/Runner/LiveSpeech.swift',
        'macos/Runner/MainFlutterWindow.swift',
        'macos/Runner/LiveSpeech.swift',
        'macos/Runner/AppDelegate.swift',
      ]) {
        final src = read(path);
        expect(src.contains(' as! '), isFalse, reason: path);
        expect(src.contains('try!'), isFalse, reason: path);
      }
    });
  });

  group('motori che lavorano insieme', () {
    test('Android: il motore senza interfaccia della sincronizzazione ha i '
        'canali che il suo codice Dart usa', () {
      final kt = read('$_kt/BackgroundSync.kt');
      final headless = kt.substring(
        kt.indexOf('fun startHeadless'),
        kt.indexOf('private fun stopHeadless'),
      );
      // sincronizzazione, calendario del telefono e widget (aggiornati da
      // RemindersService.refresh in runBackgroundSync)
      for (final ch in const [
        'MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)',
        'UniNotesCalendar.CHANNEL',
        'WidgetSupport.CHANNEL',
      ]) {
        expect(headless, contains(ch));
      }
      for (final m in const ['done', 'schedule', 'cancel', 'busy', 'update', 'takeRoute']) {
        expect(headless, contains('"$m"'), reason: m);
      }
      // calendario senza attività: «request» risponde false, mai un crash
      expect(headless, contains('calendar.handle(null, call, result)'));
      // il punto d'ingresso Dart esiste e non viene tolto dalla compilazione
      expect(headless, contains('"backgroundSyncMain"'));
      expect(
        read('lib/main.dart'),
        matches(
          RegExp(
            r"@pragma\('vm:entry-point'\)\s*Future<void> backgroundSyncMain\(\)",
          ),
        ),
      );
    });

    test('punti d\'ingresso degli isolate in background mantenuti', () {
      expect(
        read('lib/core/reminders/notification_platform.dart'),
        matches(
          RegExp(
            r"@pragma\('vm:entry-point'\)\s*Future<void> "
            r'notificationTapBackground\(',
          ),
        ),
      );
      expect(
        read('lib/features/notes/recorder/background_controls.dart'),
        matches(
          RegExp(r"@pragma\('vm:entry-point'\)\s*void recordingServiceCallback\("),
        ),
      );
    });

    test('Android: chiudendo un\'attività non si tolgono gli avvisi messi da '
        'quella nuova (file condivisi, pulsanti della registrazione)', () {
      final kt = read('$_kt/MainActivity.kt');
      final clean = kt.substring(kt.indexOf('override fun cleanUpFlutterEngine'));
      expect(
        RegExp(
          r'^\s*(IncomingShare\.onAvailable|RecordingNotification\.onCommand) = null',
          multiLine: true,
        ).hasMatch(clean),
        isFalse,
      );
      expect(
        clean,
        contains('if (IncomingShare.onAvailable === onAvailable)'),
      );
      expect(
        clean,
        contains('if (RecordingNotification.onCommand === onCommand)'),
      );
      // la sincronizzazione confronta già il motore
      expect(read('$_kt/BackgroundSync.kt'), contains('appEngine === engine'));
    });

    test('Windows: ogni canale del runner è creato con il motore e tolto '
        'prima che il motore si chiuda', () {
      final w = read('windows/runner/flutter_window.cpp');
      final destroy = w.substring(w.indexOf('void FlutterWindow::OnDestroy'));
      for (final field in const [
        'audio_channel_',
        'focus_channel_',
        'speech_channel_',
        'spell_channel_',
        'open_with_channel_',
        'notification_identity_channel_',
      ]) {
        expect(
          RegExp('$field\\s*=\\s*std::make_unique').hasMatch(w),
          isTrue,
          reason: field,
        );
        final reset = destroy.indexOf('$field = nullptr');
        expect(reset, greaterThan(0), reason: field);
        expect(
          reset,
          lessThan(destroy.indexOf('flutter_controller_ = nullptr')),
          reason: '$field dopo il motore',
        );
      }
    });

    test('iOS: il compito in background chiede «run» al canale della '
        'sincronizzazione e chiude il compito una volta sola', () {
      final s = read('ios/Runner/AppDelegate.swift');
      expect(s, contains('channel.invokeMethod("run", arguments: nil)'));
      expect(s, contains('task.expirationHandler'));
      expect(s, contains('if done { return }'));
    });
  });

  group('database aperto da due motori (Android)', () {
    tearDown(() => AppDatabase.otherEngineWorking = null);

    test('una transazione rimasta a metà da un motore chiuso si annulla '
        'aprendo, quella di un motore vivo no', () async {
      // nessun altro motore (app appena aperta, motore senza interfaccia)
      expect(await AppDatabase.rollbackOrphanOnOpen(), isTrue);
      AppDatabase.otherEngineWorking = () async => true;
      expect(await AppDatabase.rollbackOrphanOnOpen(), isFalse);
      AppDatabase.otherEngineWorking = () async => false;
      expect(await AppDatabase.rollbackOrphanOnOpen(), isTrue);
      // canale assente o in errore: come nessun altro motore
      AppDatabase.otherEngineWorking = () async => throw MissingPluginException();
      expect(await AppDatabase.rollbackOrphanOnOpen(), isTrue);
    });

    test('la scelta arriva a sqflite (in release il predefinito è «mai»)', () {
      final on = AppDatabase.optionsFor(rollbackOrphan: true) as dynamic;
      final off = AppDatabase.optionsFor(rollbackOrphan: false) as dynamic;
      // campi della classe interna di sqflite, non dell'interfaccia
      // pubblica: si leggono senza tipo apposta
      // ignore: avoid_dynamic_calls
      expect(on.rollbackActiveTransactionOnOpen, isTrue);
      // ignore: avoid_dynamic_calls
      expect(off.rollbackActiveTransactionOnOpen, isFalse);
      // ignore: avoid_dynamic_calls
      expect(on.singleInstance, isTrue);
    });

    test('l\'app imposta il controllo prima di aprire il database', () {
      final main = read('lib/main.dart');
      final hook = main.indexOf(
        'AppDatabase.otherEngineWorking = BackgroundSync.headlessBusy',
      );
      expect(hook, greaterThan(0));
      expect(hook, lessThan(main.indexOf('await AppDatabase.open()')));
    });
  });

  group('pulsanti delle notifiche premuti con l\'app chiusa', () {
    // preferenze del sistema finte, condivise fra «isolate»: quello dei
    // pulsanti (questo test) e l'app, che qui scrive direttamente
    final store = <String, Object>{};
    const prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');

    setUp(() {
      store.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(prefsChannel, (call) async {
            final a = (call.arguments as Map?) ?? const {};
            switch (call.method) {
              case 'getAll':
              case 'getAllWithParameters':
                final prefix = (a['prefix'] as String?) ?? '';
                return {
                  for (final e in store.entries)
                    if (e.key.startsWith(prefix)) e.key: e.value,
                };
              case 'remove':
                store.remove(a['key']);
                return true;
              case 'clear':
              case 'clearWithParameters':
                store.clear();
                return true;
              default:
                if (call.method.startsWith('set')) {
                  store[a['key'] as String] = a['value'] as Object;
                  return true;
                }
                return null;
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(prefsChannel, null);
    });

    NotificationResponse press(String payload, String action) =>
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: payload,
          actionId: action,
        );

    List<NotificationTap> queue() => NotificationTap.parseQueue([
      ...?(store['flutter.uninotes_notification_queue'] as List?)
          ?.cast<String>(),
    ]);

    test('il motore dei pulsanti resta vivo: dopo che l\'app ha preso la '
        'coda, il pulsante dopo non rimette in coda quelli già eseguiti', () async {
      await notificationTapBackground(press('recensione', 'later'));
      expect(queue().map((t) => t.action), ['later']);
      // l'app (un altro isolate) prende la coda
      store.remove('flutter.uninotes_notification_queue');
      await notificationTapBackground(press('recensione', 'never'));
      expect(queue().map((t) => t.action), ['never']);
      // e i pulsanti premuti uno dopo l'altro restano tutti
      await notificationTapBackground(press('esito:3', 'skipExam'));
      expect(queue().map((t) => t.action), ['never', 'skipExam']);
    });
  });
}

const _kt = 'android/app/src/main/kotlin/io/github/simomagnus/universitynotes';

Iterable<File> _kotlinFiles() => Directory(
  'android/app/src/main/kotlin',
).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.kt'));

/// Un canale: dove sta in Dart, dove sta sul lato nativo di ogni piattaforma
/// e che cosa si scambiano i due lati.
class _Contract {
  const _Contract(
    this.name, {
    required this.dart,
    required this.native,
    required this.fromDart,
    this.toDart = const {},
    this.args = const {},
    this.receivers = const [],
    this.wrappers = const [],
  });

  final String name;

  /// File Dart che usano il canale.
  final List<String> dart;

  /// Piattaforma → file nativi dove il canale è registrato e gestito.
  final Map<String, List<String>> native;

  /// Metodo chiamato da Dart → piattaforme da cui la chiamata può partire.
  final Map<String, List<String>> fromDart;

  /// Metodo mandato dal nativo a Dart → piattaforme che lo mandano.
  final Map<String, List<String>> toDart;

  /// Piattaforma → argomenti che il nativo legge per nome.
  final Map<String, List<String>> args;

  /// Variabili del canale in Dart (`x.invokeMethod('m')`) e funzioni che lo
  /// avvolgono (`_call('m')`): servono a trovare tutte le chiamate.
  final List<String> receivers;
  final List<String> wrappers;
}

const _android = 'android';
const _ios = 'ios';
const _macos = 'macos';
const _windows = 'windows';

const _main = '$_kt/MainActivity.kt';
const _appDelegate = 'ios/Runner/AppDelegate.swift';
const _macWindow = 'macos/Runner/MainFlutterWindow.swift';

const _contracts = <_Contract>[
  _Contract(
    'io.github.simomagnus.universitynotes/widgets',
    dart: ['lib/core/reminders/home_widgets.dart'],
    native: {
      _android: [_main, '$_kt/widgets/WidgetSupport.kt', '$_kt/BackgroundSync.kt'],
      _ios: [_appDelegate],
      _macos: [_macWindow],
    },
    fromDart: {
      'update': [_android, _ios, _macos],
      'takeRoute': [_android, _ios, _macos],
      // dopo l'avvio della registrazione dal widget (solo Android)
      'moveToBack': [_android],
    },
    toDart: {
      'route': [_android, _ios, _macos],
    },
    args: {
      _ios: ['json'],
      _macos: ['json'],
    },
    receivers: ['_channel'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/focus',
    dart: ['lib/features/study/focus/focus_system.dart'],
    native: {
      _android: [_main, '$_kt/FocusDnd.kt'],
      _ios: [_appDelegate],
      _macos: [_macWindow],
      _windows: ['windows/runner/focus_session.cpp'],
    },
    fromDart: {
      'dndAccess': [_android],
      'dndActive': [_android],
      'openDndSettings': [_android],
      'setDnd': [_android],
      'winFocusStart': [_windows],
      'winFocusActive': [_windows],
      'winFocusEnd': [_windows],
    },
    toDart: {
      'shortcutResult': [_ios, _macos],
    },
    args: {
      _android: ['on', 'untilMs'],
      _windows: ['endMs', 'lafToken', 'lafAttestation'],
    },
    wrappers: ['_call'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/speech',
    dart: ['lib/features/notes/recorder/system_speech.dart'],
    native: {
      _android: [_main, '$_kt/LiveSpeech.kt'],
      _ios: ['ios/Runner/LiveSpeech.swift', _appDelegate],
      _macos: ['macos/Runner/LiveSpeech.swift', _macWindow],
      _windows: ['windows/runner/live_speech.cpp'],
    },
    fromDart: {
      'support': [_android, _ios, _macos, _windows],
      'start': [_android, _ios, _macos, _windows],
      'feed': [_android, _ios, _macos, _windows],
      'pause': [_android, _ios, _macos, _windows],
      'resume': [_android, _ios, _macos, _windows],
      'stop': [_android, _ios, _macos, _windows],
    },
    toDart: {
      'partial': [_android, _ios, _macos, _windows],
      'result': [_android, _ios, _macos, _windows],
      'error': [_android, _ios, _macos, _windows],
      'ended': [_android, _ios, _macos, _windows],
    },
    args: {
      _android: ['locale', 'sampleRate', 'session'],
      _ios: ['locale', 'session'],
      _macos: ['locale', 'session'],
      _windows: ['locale', 'session'],
    },
    receivers: ['_channel'],
    wrappers: ['_quiet'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/incoming',
    dart: ['lib/features/cloud/incoming_files.dart'],
    native: {
      _android: [_main, '$_kt/IncomingShare.kt'],
      _ios: [_appDelegate],
    },
    fromDart: {
      'take': [_android, _ios],
    },
    toDart: {
      'available': [_android, _ios],
    },
    receivers: ['_channel'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/registrazione',
    // lo stato della registrazione (paused, elapsedMs, course) lo prepara
    // recordingWidgetState, anche per il widget «Registra lezione»
    dart: [
      'lib/features/notes/recorder/background_controls.dart',
      'lib/core/reminders/home_widgets.dart',
    ],
    native: {
      _android: [_main, '$_kt/RecordingNotification.kt'],
    },
    fromDart: {
      'show': [_android],
      // fine della registrazione: il widget torna fermo
      'stopped': [_android],
    },
    toDart: {
      'command': [_android],
    },
    args: {
      _android: [
        'id',
        'title',
        'course',
        'elapsedMs',
        'paused',
        'primary',
        'primaryId',
        'save',
      ],
    },
    receivers: ['_native'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/live_activity',
    dart: ['lib/features/notes/recorder/background_controls.dart'],
    native: {
      _ios: [_appDelegate],
    },
    fromDart: {
      'start': [_ios],
      'update': [_ios],
      'end': [_ios],
    },
    toDart: {
      'command': [_ios],
    },
    args: {
      _ios: ['course', 'elapsedMs', 'paused'],
    },
    // `_call` è il solo modo in cui la Live Activity chiama il canale
    wrappers: ['_call'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/calendario',
    dart: [
      'lib/core/reminders/native_calendar_backend.dart',
      'lib/core/reminders/device_calendar_backend.dart',
      'lib/core/reminders/apple_calendar_backend.dart',
    ],
    native: {
      _android: [_main, '$_kt/UniNotesCalendar.kt', '$_kt/BackgroundSync.kt'],
      _ios: [_appDelegate],
      _macos: [_macWindow],
    },
    fromDart: {
      'access': [_android, _ios, _macos],
      'request': [_android, _ios, _macos],
      'calendars': [_android, _ios, _macos],
      'health': [_android, _ios, _macos],
      'events': [_android, _ios, _macos],
      'write': [_android, _ios, _macos],
      'delete': [_android, _ios, _macos],
      'deleteCalendarIfEmpty': [_android, _ios, _macos],
      // conferma dell'account del calendario (solo Android 13+)
      'accountAccess': [_android],
      'confirmAccount': [_android],
    },
    args: {
      _android: [
        'calendarId',
        'eventId',
        'title',
        'notes',
        'location',
        'allDay',
        'startMs',
        'endMs',
        'alarms',
        'name',
        'account',
        'accountType',
        'description',
      ],
      _ios: [
        'calendarId',
        'eventId',
        'title',
        'notes',
        'location',
        'allDay',
        'startMs',
        'endMs',
        'alarms',
        'name',
      ],
      _macos: [
        'calendarId',
        'eventId',
        'title',
        'notes',
        'location',
        'allDay',
        'startMs',
        'endMs',
        'alarms',
        'name',
      ],
    },
    wrappers: ['call'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/sincronizzazione',
    dart: ['lib/core/services/background_sync.dart'],
    native: {
      _android: [_main, '$_kt/BackgroundSync.kt'],
      _ios: [_appDelegate],
    },
    fromDart: {
      // solo Android: l'app aspetta il motore senza interfaccia
      'busy': [_android],
      'schedule': [_android, _ios],
      'cancel': [_android, _ios],
      // solo dal motore senza interfaccia di Android (runBackgroundSync)
      'done': [_android],
    },
    toDart: {
      'run': [_android, _ios],
    },
    args: {
      _android: ['minutes'],
      _ios: ['minutes'],
    },
    receivers: ['channel'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/apri_con',
    dart: ['lib/core/services/external_launcher.dart'],
    native: {
      _android: [_main, '$_kt/OpenWith.kt'],
      _ios: [_appDelegate],
      _macos: [_macWindow],
      _windows: ['windows/runner/open_with.cpp'],
    },
    fromDart: {
      'openWith': [_android, _ios, _macos, _windows],
    },
    args: {
      _android: ['path'],
      _ios: ['path'],
      _macos: ['path'],
      _windows: ['path'],
    },
    receivers: ['openWithChannel'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/audio',
    dart: ['lib/core/services/audio_codec.dart'],
    native: {
      _windows: ['windows/runner/audio_transcoder.cpp'],
    },
    fromDart: {
      'toM4a': [_windows],
      'toWav': [_windows],
    },
    args: {
      _windows: ['input', 'output', 'bitRate', 'sampleRate', 'channels'],
    },
    receivers: ['channel'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/disinstalla',
    dart: ['lib/core/services/app_uninstall.dart'],
    native: {
      _macos: [_macWindow],
    },
    fromDart: {
      'installIdentity': [_macos],
    },
    receivers: ['channel'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/spellcheck',
    dart: ['lib/features/notes/spell_check.dart'],
    native: {
      _macos: [_macWindow],
      _windows: ['windows/runner/spell_check.cpp'],
    },
    fromDart: {
      'check': [_macos, _windows],
      'languages': [_macos, _windows],
    },
    args: {
      _macos: ['texts', 'languages'],
      _windows: ['texts', 'languages'],
    },
    receivers: ['_channel', 'channel'],
  ),
  _Contract(
    'io.github.simomagnus.universitynotes/notifiche',
    dart: ['lib/core/reminders/windows_aumid.dart'],
    native: {
      _windows: ['windows/runner/notification_identity.cpp'],
    },
    fromDart: {
      'migraAumid': [_windows],
    },
    args: {
      _windows: ['vecchio'],
    },
    receivers: ['_channel'],
  ),
];
