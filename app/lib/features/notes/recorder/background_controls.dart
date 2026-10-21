import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Comandi arrivati da fuori dell'app (notifica Android, Live Activity di
/// iOS, icona nell'area di notifica del PC).
enum RecorderCommand { pause, resume, toggle, save, open }

/// Controlli della registrazione con l'app in background:
/// - **Android**: la notifica del servizio in primo piano mostra corso e
///   tempo (aggiornato ogni secondo) con i pulsanti «Pausa»/«Riprendi» e
///   «Salva»; il tocco apre il registratore;
/// - **iOS**: Live Activity (schermata di blocco e Dynamic Island), se
///   l'estensione è stata aggiunta in Xcode (docs/widget.md);
/// - altrove: niente (sul PC c'è l'icona nell'area di notifica).
abstract class BackgroundControls {
  factory BackgroundControls.forPlatform() {
    if (Platform.isAndroid) return AndroidRecordingNotification();
    if (Platform.isIOS) return IosLiveActivity();
    return const NoBackgroundControls();
  }

  /// Riceve i comandi (pulsanti premuti fuori dall'app).
  set onCommand(void Function(RecorderCommand c)? f);

  /// Inizio della registrazione. Restituisce un messaggio d'errore se il
  /// sistema non permette di registrare in background.
  Future<String?> start({
    required String course,
    required Duration elapsed,
    required bool paused,
  });

  Future<void> update({required Duration elapsed, required bool paused});

  Future<void> stop();
}

class NoBackgroundControls implements BackgroundControls {
  const NoBackgroundControls();
  @override
  set onCommand(void Function(RecorderCommand c)? f) {}
  @override
  Future<String?> start({
    required String course,
    required Duration elapsed,
    required bool paused,
  }) async => null;
  @override
  Future<void> update({
    required Duration elapsed,
    required bool paused,
  }) async {}
  @override
  Future<void> stop() async {}
}

// ------------------------------------------------------------- Android

/// Chiave dello stato condiviso con il servizio (corso, tempo, pausa).
const _stateKey = 'uninotes_registrazione';

/// Pulsanti della notifica.
const _btnPause = 'pausa';
const _btnResume = 'riprendi';
const _btnSave = 'salva';
const _cmdOpen = 'apri';

List<NotificationButton> _buttons(bool paused) => [
  paused
      ? const NotificationButton(id: _btnResume, text: 'Riprendi')
      : const NotificationButton(id: _btnPause, text: 'Pausa'),
  const NotificationButton(id: _btnSave, text: 'Salva'),
];

String _clock(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

/// Avvio del servizio in primo piano (isolate separato): aggiorna la
/// notifica ogni secondo e passa i pulsanti all'app.
@pragma('vm:entry-point')
void recordingServiceCallback() {
  FlutterForegroundTask.setTaskHandler(RecordingTaskHandler());
}

class RecordingTaskHandler extends TaskHandler {
  String _course = '';
  int _elapsedMs = 0;
  int _atMs = 0;
  bool _paused = false;
  bool? _shownPaused;

  void _apply(Object? data) {
    Object? m = data;
    if (m is String) {
      try {
        m = jsonDecode(m);
      } catch (_) {
        return;
      }
    }
    if (m is! Map) return;
    _course = '${m['corso'] ?? _course}';
    _elapsedMs = (m['ms'] as num?)?.toInt() ?? _elapsedMs;
    _atMs = (m['alle'] as num?)?.toInt() ?? _atMs;
    _paused = m['pausa'] == true;
  }

  Duration get _elapsed => Duration(
    milliseconds:
        _elapsedMs +
        (_paused ? 0 : DateTime.now().millisecondsSinceEpoch - _atMs),
  );

  void _render({bool force = false}) {
    final changed = _shownPaused != _paused;
    if (_paused && !changed && !force) return;
    _shownPaused = _paused;
    FlutterForegroundTask.updateService(
      notificationTitle: _paused
          ? 'Registrazione in pausa'
          : 'Registrazione in corso',
      notificationText: '$_course · ${_clock(_elapsed)}',
      notificationButtons: changed ? _buttons(_paused) : null,
    );
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _apply(await FlutterForegroundTask.getData<String>(key: _stateKey));
    _render(force: true);
  }

  @override
  void onRepeatEvent(DateTime timestamp) => _render();

  @override
  void onReceiveData(Object data) {
    _apply(data);
    _render(force: true);
  }

  @override
  void onNotificationButtonPressed(String id) =>
      FlutterForegroundTask.sendDataToMain({'cmd': id});

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
    FlutterForegroundTask.sendDataToMain({'cmd': _cmdOpen});
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class AndroidRecordingNotification implements BackgroundControls {
  static bool _initialized = false;
  void Function(RecorderCommand c)? _onCommand;
  String _course = '';

  @override
  set onCommand(void Function(RecorderCommand c)? f) => _onCommand = f;

  void _onData(Object data) {
    if (data is! Map) return;
    final cmd = switch (data['cmd']) {
      _btnPause => RecorderCommand.pause,
      _btnResume => RecorderCommand.resume,
      _btnSave => RecorderCommand.save,
      _cmdOpen => RecorderCommand.open,
      _ => null,
    };
    if (cmd != null) _onCommand?.call(cmd);
  }

  Map<String, Object?> _state(Duration elapsed, bool paused) => {
    'corso': _course,
    'ms': elapsed.inMilliseconds,
    'alle': DateTime.now().millisecondsSinceEpoch,
    'pausa': paused,
  };

  @override
  Future<String?> start({
    required String course,
    required Duration elapsed,
    required bool paused,
  }) async {
    _course = course;
    if (!_initialized) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'registrazione_lezione',
          channelName: 'Registrazione lezione',
          channelDescription:
              'Notifica mostrata mentre registri una lezione, con il tempo '
              'e i pulsanti Pausa e Salva.',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(1000),
          allowWakeLock: true,
        ),
      );
      _initialized = true;
    }
    try {
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (_) {}
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(_onData);
    await FlutterForegroundTask.saveData(
      key: _stateKey,
      value: jsonEncode(_state(elapsed, paused)),
    );
    final r = await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: 'Registrazione in corso',
      notificationText: '$course · ${_clock(elapsed)}',
      // icona monocromatica dell'app e blu del logo delle notifiche (vedi
      // AndroidManifest.xml e LocalNotificationPlatform)
      notificationIcon: const NotificationIcon(
        metaDataName: 'io.github.simomagnus.universitynotes.NOTIFICATION_ICON',
        backgroundColor: Color(0xFF0F72F2),
      ),
      notificationButtons: _buttons(paused),
      callback: recordingServiceCallback,
    );
    if (r is ServiceRequestFailure) {
      FlutterForegroundTask.removeTaskDataCallback(_onData);
      return 'Impossibile mantenere attiva la registrazione a schermo spento: '
          '${r.error}';
    }
    return null;
  }

  @override
  Future<void> update({required Duration elapsed, required bool paused}) async {
    final s = _state(elapsed, paused);
    try {
      await FlutterForegroundTask.saveData(
        key: _stateKey,
        value: jsonEncode(s),
      );
      FlutterForegroundTask.sendDataToTask(s);
    } catch (e) {
      debugPrint('Notifica della registrazione non aggiornata: $e');
    }
  }

  @override
  Future<void> stop() async {
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    try {
      await FlutterForegroundTask.removeData(key: _stateKey);
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}

// ----------------------------------------------------------------- iOS

/// Live Activity della registrazione (iOS 16.2+, pulsanti da iOS 17). Il
/// lato nativo è in `ios/Runner/AppDelegate.swift`; l'estensione con la
/// grafica va aggiunta in Xcode (`ios/LiveActivity_da_aggiungere/`,
/// docs/widget.md). Senza estensione le chiamate non fanno nulla.
class IosLiveActivity implements BackgroundControls {
  IosLiveActivity() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'command') return null;
      final cmd = switch (call.arguments) {
        'toggle' => RecorderCommand.toggle,
        'pause' => RecorderCommand.pause,
        'resume' => RecorderCommand.resume,
        'save' => RecorderCommand.save,
        'open' => RecorderCommand.open,
        _ => null,
      };
      if (cmd != null) _onCommand?.call(cmd);
      return null;
    });
  }

  static const _channel = MethodChannel(
    'io.github.simomagnus.universitynotes/live_activity',
  );
  void Function(RecorderCommand c)? _onCommand;
  String _course = '';

  @override
  set onCommand(void Function(RecorderCommand c)? f) => _onCommand = f;

  Map<String, Object?> _args(Duration elapsed, bool paused) => {
    'course': _course,
    'elapsedMs': elapsed.inMilliseconds,
    // inizio «virtuale» per il cronometro nativo (Text(timerInterval:))
    'startedAtMs':
        DateTime.now().millisecondsSinceEpoch - elapsed.inMilliseconds,
    'paused': paused,
  };

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<Object?>(method, args);
    } catch (e) {
      debugPrint('Live Activity non aggiornata: $e');
    }
  }

  @override
  Future<String?> start({
    required String course,
    required Duration elapsed,
    required bool paused,
  }) async {
    _course = course;
    await _call('start', _args(elapsed, paused));
    return null;
  }

  @override
  Future<void> update({required Duration elapsed, required bool paused}) =>
      _call('update', _args(elapsed, paused));

  @override
  Future<void> stop() => _call('end');
}
