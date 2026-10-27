import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../../core/reminders/home_widgets.dart' show recordingWidgetState;

/// Comandi arrivati da fuori dell'app (notifica e widget Android, Live
/// Activity di iOS, icona nell'area di notifica del PC). [discard] arriva
/// solo dal widget «Registra lezione», dopo il secondo tocco su «Elimina»:
/// la registrazione va in «Eliminati di recente».
enum RecorderCommand { pause, resume, toggle, save, open, discard }

/// Controlli della registrazione con l'app in background:
/// - **Android**: la notifica del servizio in primo piano mostra tempo
///   (cronometro del sistema) e corso con i pulsanti «Pausa»/«Riprendi» e
///   «Salva» sempre visibili, anche a schermo bloccato; il tocco apre il
///   registratore;
/// - **iOS**: Live Activity (schermata di blocco e Dynamic Island, iOS
///   16.2+), con l'estensione aggiunta dalla build automatica (docs/widget.md);
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

/// Id dei pulsanti della notifica (gli stessi nella notifica nativa,
/// RecordingNotification.kt, e in quella di riserva del pacchetto).
const btnPause = 'pausa';
const btnResume = 'riprendi';
const btnSave = 'salva';

/// «Elimina» del widget «Registra lezione», già confermato con il secondo
/// tocco (RecordWidget.kt).
const btnDiscard = 'elimina';
const _cmdOpen = 'apri';

/// Il servizio è partito (la sua notifica va sostituita con la nostra).
const _cmdReady = 'pronto';

/// L'utente ha tolto la notifica dalla tendina (Android 14+): si rimette.
const _cmdDismissed = 'nascosta';

/// Id della notifica del servizio in primo piano (e della nostra, che la
/// sostituisce).
const recordingNotificationId = 4100;

/// Testi e pulsanti della notifica della registrazione.
class RecordingNotificationContent {
  const RecordingNotificationContent({
    required this.title,
    required this.course,
    required this.primaryId,
    required this.primaryText,
    required this.saveText,
  });

  final String title;
  final String course;

  /// «Pausa» durante la registrazione, «Riprendi» in pausa.
  final String primaryId;
  final String primaryText;
  final String saveText;

  List<NotificationButton> get buttons => [
    NotificationButton(id: primaryId, text: primaryText),
    NotificationButton(id: btnSave, text: saveText),
  ];
}

RecordingNotificationContent recordingNotificationContent({
  required String course,
  required bool paused,
}) => RecordingNotificationContent(
  title: paused ? 'Registrazione in pausa' : 'Registrazione in corso',
  course: course,
  primaryId: paused ? btnResume : btnPause,
  primaryText: paused ? 'Riprendi' : 'Pausa',
  saveText: 'Salva',
);

/// Argomenti di `show` per la notifica nativa (RecordingNotification.kt):
/// testi, pulsanti, tempo e lo stato della registrazione che il lato nativo
/// passa anche al widget «Registra lezione» (stessa fonte). Funzione pura.
Map<String, Object?> recordingShowArgs(
  RecordingNotificationContent c, {
  required Duration elapsed,
  required bool paused,
}) => {
  ...recordingWidgetState(
    active: true,
    paused: paused,
    elapsed: elapsed,
    course: c.course,
  ),
  'id': recordingNotificationId,
  'title': c.title,
  'primary': c.primaryText,
  'primaryId': c.primaryId,
  'save': c.saveText,
};

/// Comando del registratore per il pulsante [id] della notifica (null se
/// non è un pulsante).
RecorderCommand? recorderCommandFor(Object? id) => switch (id) {
  btnPause => RecorderCommand.pause,
  btnResume => RecorderCommand.resume,
  btnSave => RecorderCommand.save,
  btnDiscard => RecorderCommand.discard,
  _cmdOpen => RecorderCommand.open,
  _ => null,
};

/// Comandi accettati dal servizio di flutter_foreground_task (porta dei
/// dati). Su Android 7–12 il suo ricevitore dei pulsanti è registrato senza
/// `RECEIVER_NOT_EXPORTED` (il flag esiste da Android 13) e controlla solo
/// il pacchetto scritto nell'intent: un'altra app può mandargli un id
/// qualsiasi. Da qui passano quindi solo gli eventi del servizio (pronto,
/// notifica tolta, tocco che apre l'app) e i pulsanti della notifica di
/// riserva solo mentre è davvero mostrata ([fallbackShown]); mai
/// «Elimina», che arriva solo dal widget (ricevitore non esportato, doppio
/// tocco) sul canale nativo.
bool packageCommandAllowed(Object? id, {required bool fallbackShown}) =>
    switch (id) {
      _cmdReady || _cmdDismissed || _cmdOpen => true,
      btnPause || btnResume || btnSave => fallbackShown,
      _ => false,
    };

/// Avvio del servizio in primo piano (isolate separato): passa all'app i
/// pulsanti della notifica di riserva e gli eventi del servizio. Il tempo
/// lo mostra il cronometro del sistema nella notifica nativa: niente
/// aggiornamenti ogni secondo.
@pragma('vm:entry-point')
void recordingServiceCallback() {
  FlutterForegroundTask.setTaskHandler(RecordingTaskHandler());
}

class RecordingTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    FlutterForegroundTask.sendDataToMain({'cmd': _cmdReady});
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onNotificationButtonPressed(String id) =>
      FlutterForegroundTask.sendDataToMain({'cmd': id});

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
    FlutterForegroundTask.sendDataToMain({'cmd': _cmdOpen});
  }

  @override
  void onNotificationDismissed() =>
      FlutterForegroundTask.sendDataToMain({'cmd': _cmdDismissed});

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Android: servizio in primo piano di flutter_foreground_task (tiene viva
/// la registrazione a schermo spento) con la notifica sostituita da quella
/// nativa (RecordingNotification.kt): i pulsanti «Pausa»/«Riprendi» e
/// «Salva» sono nella vista compressa, quindi sempre visibili (anche a
/// schermo bloccato), e il tempo scorre con il cronometro del sistema.
///
/// Perché: nella notifica del pacchetto i pulsanti sono «azioni» del
/// modello standard di Android, visibili solo espandendo la notifica; in
/// più il canale aveva l'importanza bassa predefinita del pacchetto, quindi
/// la notifica stava fra le silenziose (compressa in fondo alla tendina e
/// nascosta nella schermata di blocco): i pulsanti di fatto non si vedevano.
/// Se la notifica nativa non si può mostrare resta quella del pacchetto,
/// con gli stessi pulsanti (da espandere).
class AndroidRecordingNotification implements BackgroundControls {
  AndroidRecordingNotification() {
    _native.setMethodCallHandler((call) async {
      if (call.method == 'command') _onButton(call.arguments);
      return null;
    });
  }

  static const _native = MethodChannel(
    'io.github.simomagnus.universitynotes/registrazione',
  );

  /// Canale delle notifiche: importanza predefinita senza suono né
  /// vibrazione (il vecchio «registrazione_lezione», a importanza bassa,
  /// lo elimina RecordingNotification.kt).
  static const channelId = 'registrazione_in_corso';

  static bool _initialized = false;
  void Function(RecorderCommand c)? _onCommand;
  String _course = '';
  bool _running = false;
  bool _paused = false;
  Duration _elapsed = Duration.zero;
  DateTime _at = DateTime.now();

  /// Contenuto mostrato dalla notifica di riserva (null = nessuno).
  RecordingNotificationContent? _fallbackShown;

  @override
  set onCommand(void Function(RecorderCommand c)? f) => _onCommand = f;

  Duration get _now =>
      _paused ? _elapsed : _elapsed + DateTime.now().difference(_at);

  void _onButton(Object? id) {
    if (id == _cmdReady || id == _cmdDismissed) {
      // servizio appena partito o notifica tolta: si (ri)mostra la nostra
      if (_running) unawaited(_show());
      return;
    }
    final cmd = recorderCommandFor(id);
    if (cmd != null) _onCommand?.call(cmd);
  }

  void _onData(Object data) {
    if (data is! Map) return;
    final id = data['cmd'];
    if (packageCommandAllowed(id, fallbackShown: _fallbackShown != null)) {
      _onButton(id);
    }
  }

  Future<void> _show() async {
    final c = recordingNotificationContent(course: _course, paused: _paused);
    bool ok;
    try {
      ok =
          await _native.invokeMethod<bool>(
            'show',
            recordingShowArgs(c, elapsed: _now, paused: _paused),
          ) ??
          false;
    } catch (e) {
      debugPrint('Notifica della registrazione non mostrata: $e');
      ok = false;
    }
    if (ok) {
      // la nostra ha sostituito quella del pacchetto (stesso id): i suoi
      // pulsanti non si vedono più
      _fallbackShown = null;
      return;
    }
    if (!_running) return;
    // riserva: la notifica del pacchetto, con gli stessi pulsanti
    if (_fallbackShown?.primaryId == c.primaryId &&
        _fallbackShown?.title == c.title) {
      return;
    }
    _fallbackShown = c;
    await FlutterForegroundTask.updateService(
      notificationTitle: c.title,
      notificationText: c.course,
      notificationButtons: c.buttons,
    );
  }

  @override
  Future<String?> start({
    required String course,
    required Duration elapsed,
    required bool paused,
  }) async {
    _course = course;
    _elapsed = elapsed;
    _paused = paused;
    _at = DateTime.now();
    _fallbackShown = null;
    if (!_initialized) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: channelId,
          channelName: 'Registrazione lezione',
          channelDescription:
              'Notifica mostrata mentre registri una lezione, con il tempo '
              'e i pulsanti Pausa e Salva.',
          channelImportance: NotificationChannelImportance.DEFAULT,
          priority: NotificationPriority.DEFAULT,
          playSound: false,
          enableVibration: false,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
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
    final c = recordingNotificationContent(course: course, paused: paused);
    final r = await FlutterForegroundTask.startService(
      serviceId: recordingNotificationId,
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: c.title,
      notificationText: c.course,
      // icona monocromatica dell'app e blu del logo delle notifiche (vedi
      // AndroidManifest.xml e LocalNotificationPlatform)
      notificationIcon: const NotificationIcon(
        metaDataName: 'io.github.simomagnus.universitynotes.NOTIFICATION_ICON',
        backgroundColor: Color(0xFF0F72F2),
      ),
      notificationButtons: c.buttons,
      callback: recordingServiceCallback,
    );
    // servizio rimasto acceso dalla registrazione di prima (fermata senza
    // che il sistema lo chiudesse): si riusa, invece di non poter più
    // registrare finché non si chiude l'app
    if (r is ServiceRequestFailure &&
        r.error is! ServiceAlreadyStartedException) {
      FlutterForegroundTask.removeTaskDataCallback(_onData);
      return 'Impossibile mantenere attiva la registrazione a schermo spento: '
          '${r.error}';
    }
    _running = true;
    await _show();
    return null;
  }

  @override
  Future<void> update({required Duration elapsed, required bool paused}) async {
    _elapsed = elapsed;
    _paused = paused;
    _at = DateTime.now();
    if (_running) await _show();
  }

  @override
  Future<void> stop() async {
    _running = false;
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    // il widget «Registra lezione» torna fermo (anche se il servizio non
    // si ferma bene)
    try {
      await _native.invokeMethod<bool>(
        'stopped',
        recordingWidgetState(active: false),
      );
    } catch (e) {
      debugPrint('Widget della registrazione non aggiornato: $e');
    }
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
// ----------------------------------------------------------------- iOS

/// Live Activity della registrazione (iOS 16.2+, pulsanti da iOS 17). Il
/// lato nativo è in `ios/Runner/AppDelegate.swift`; la grafica è
/// nell'estensione `ios/WidgetUniNotes/`, che aggiunge la build automatica
/// (docs/widget.md). Senza estensione le chiamate non fanno nulla.
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
