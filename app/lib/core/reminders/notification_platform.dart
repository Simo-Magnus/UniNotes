import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color, DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'notification_plan.dart';

/// Tocco su una notifica o su uno dei suoi pulsanti.
class NotificationTap {
  const NotificationTap(this.payload, [this.action]);
  final String payload;

  /// Id del pulsante (vedi [NotificationActions]); null = tocco sul testo.
  final String? action;

  /// Risposta del pacchetto → tocco. Su Windows pulsanti e tocco arrivano
  /// come stringa unica (`act:<azione>|<payload>`, vedi [windowsArguments]).
  static NotificationTap? from(String? payload, String? actionId) {
    final p = payload ?? '';
    if (p.startsWith('act:')) {
      final rest = p.substring(4);
      final bar = rest.indexOf('|');
      if (bar < 0) return null;
      return NotificationTap(rest.substring(bar + 1), rest.substring(0, bar));
    }
    if (p.isEmpty) return null;
    final a = actionId == null || actionId.isEmpty || actionId == p
        ? null
        : actionId;
    return NotificationTap(p, a);
  }

  static String windowsArguments(String action, String payload) =>
      'act:$action|$payload';

  Map<String, String?> toJson() => {'payload': payload, 'action': action};
}

/// Notifiche del sistema (nei test: finte). Tutto è pianificato in anticipo
/// sul dispositivo, senza server.
abstract class NotificationPlatform {
  /// Prepara canali e categorie; [onTap] riceve i tocchi con l'app aperta.
  Future<void> init(void Function(NotificationTap tap) onTap);

  /// Tocco che ha aperto l'app (null se aperta normalmente).
  Future<NotificationTap?> launchTap();

  /// Pulsanti premuti con l'app chiusa (Android, iOS), in coda.
  Future<List<NotificationTap>> takeQueuedTaps();

  Future<bool> permissionGranted();

  /// Richiesta del permesso del sistema (Android 13+, iOS, macOS).
  Future<bool> requestPermission();

  Future<void> schedule(PlannedNotification n);
  Future<void> show(PlannedNotification n);
  Future<void> cancel(int id);
  Future<void> openSystemSettings();
}

/// Coda dei pulsanti premuti a app chiusa (SharedPreferences: la scrive il
/// processo in background, la legge l'app all'avvio).
const String _queueKey = 'uninotes_notification_queue';

/// Pulsanti premuti senza aprire l'app («Più tardi», «Non chiedermelo
/// più», «Non ricordarmelo per questa prova»): girano in un isolate in
/// background, che li mette in coda per l'app.
@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse r) async {
  try {
    DartPluginRegistrant.ensureInitialized();
    final tap = NotificationTap.from(r.payload, r.actionId);
    if (tap == null) return;
    final prefs = await SharedPreferences.getInstance();
    final list = [...?prefs.getStringList(_queueKey)];
    list.add(jsonEncode(tap.toJson()));
    await prefs.setStringList(_queueKey, list);
  } catch (e) {
    debugPrint('Azione della notifica non salvata: $e');
  }
}

/// Pulsanti che aprono l'app (gli altri lavorano in background).
const Set<String> _uiActions = {
  NotificationActions.review,
  NotificationActions.donate,
  NotificationActions.recordOutcome,
};

/// flutter_local_notifications su Android, iOS, macOS e Windows.
class LocalNotificationPlatform implements NotificationPlatform {
  LocalNotificationPlatform([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  static bool get supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  /// Icona piccola (bianca, monocromatica; tools/genera_icona.py) e
  /// azzurro dell'app.
  static const _icon = 'ic_stat_uninotes';
  static const _accent = Color(0xFF38BDF8);

  /// App non pacchettizzata su Windows: nome e identità fissi (il GUID
  /// registra l'attivazione al tocco anche ad app chiusa).
  static const _windowsGuid = '5d3f2b7e-91c4-4a8e-b6f1-0c7a2e9d4b13';

  static String _category(NotificationType t) => 'uninotes_${t.channelId}';

  static List<DarwinNotificationCategory> _categories() => [
    for (final t in NotificationType.values)
      DarwinNotificationCategory(
        _category(t),
        actions: [
          for (final (id, title) in _actionsOf(t))
            DarwinNotificationAction.plain(
              id,
              title,
              options: _uiActions.contains(id)
                  ? const {DarwinNotificationActionOption.foreground}
                  : const <DarwinNotificationActionOption>{},
            ),
        ],
      ),
  ];

  /// Pulsanti di ogni tipo (uguali per tutte le notifiche del tipo).
  static List<(String, String)> _actionsOf(NotificationType t) => switch (t) {
    NotificationType.outcome => const [
      (NotificationActions.recordOutcome, 'Registra l\'esito'),
      (NotificationActions.skipExam, 'Non ricordarmelo per questa prova'),
    ],
    NotificationType.review => const [
      (NotificationActions.review, 'Recensisci'),
      (NotificationActions.later, 'Più tardi'),
      (NotificationActions.never, 'Non chiedermelo più'),
    ],
    NotificationType.donation => const [
      (NotificationActions.donate, 'Dona'),
      (NotificationActions.later, 'Più tardi'),
      (NotificationActions.never, 'Non chiedermelo più'),
    ],
    _ => const [],
  };

  @override
  Future<void> init(void Function(NotificationTap tap) onTap) async {
    if (_ready) return;
    // i permessi si chiedono solo quando lo studente attiva le notifiche
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestSoundPermission: false,
      requestBadgePermission: false,
      notificationCategories: _categories(),
    );
    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings(_icon),
        iOS: darwin,
        macOS: darwin,
        linux: const LinuxInitializationSettings(defaultActionName: 'Apri'),
        windows: const WindowsInitializationSettings(
          appName: 'UniNotes',
          appUserModelId: 'io.github.simomagnus.universitynotes',
          guid: _windowsGuid,
        ),
      ),
      onDidReceiveNotificationResponse: (r) {
        final tap = NotificationTap.from(r.payload, r.actionId);
        if (tap != null) onTap(tap);
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      for (final t in NotificationType.values) {
        await android.createNotificationChannel(
          AndroidNotificationChannel(
            t.channelId,
            t.channelName,
            description: t.description,
            importance: _importance(t),
            // avvisi di inizio e fine pausa e di fine sessione: passano
            // anche con il Non disturbare della sessione Focus (serve
            // l'«Accesso a Non disturbare»; senza, il sistema lo ignora)
            bypassDnd: _bypassDnd(t),
          ),
        );
      }
    }
    _ready = true;
  }

  /// Canali che superano il Non disturbare: solo `focus_avvisi`.
  static bool _bypassDnd(NotificationType t) =>
      t == NotificationType.focusAlert;

  static Importance _importance(NotificationType t) => switch (t) {
    NotificationType.exam ||
    NotificationType.session ||
    NotificationType.focusAlert => Importance.high,
    NotificationType.review ||
    NotificationType.donation ||
    NotificationType.focus => Importance.low,
    _ => Importance.defaultImportance,
  };

  @override
  Future<NotificationTap?> launchTap() async {
    final d = await _plugin.getNotificationAppLaunchDetails();
    final r = d?.notificationResponse;
    if (d == null || !d.didNotificationLaunchApp || r == null) return null;
    return NotificationTap.from(r.payload, r.actionId);
  }

  @override
  Future<List<NotificationTap>> takeQueuedTaps() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final list = prefs.getStringList(_queueKey) ?? const [];
    if (list.isEmpty) return const [];
    await prefs.remove(_queueKey);
    return [
      for (final s in list)
        if (jsonDecode(s) case {'payload': final String p, 'action': final a})
          NotificationTap(p, a is String ? a : null),
    ];
  }

  @override
  Future<bool> permissionGranted() async {
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.areNotificationsEnabled() ??
          false;
    }
    if (Platform.isIOS) {
      final o = await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
      return o?.isEnabled ?? false;
    }
    if (Platform.isMacOS) {
      final o = await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
      return o?.isEnabled ?? false;
    }
    return Platform.isWindows;
  }

  @override
  Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: false, sound: true) ??
          false;
    }
    if (Platform.isMacOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: false, sound: true) ??
          false;
    }
    return Platform.isWindows;
  }

  NotificationDetails _details(PlannedNotification n) {
    final t = n.type;
    final countdown = n.countdownTo;
    return NotificationDetails(
      android: AndroidNotificationDetails(
        t.channelId,
        t.channelName,
        channelDescription: t.description,
        icon: _icon,
        color: _accent,
        importance: _importance(t),
        channelBypassDnd: _bypassDnd(t),
        priority: t.promotional || n.ongoing
            ? Priority.low
            : (t == NotificationType.focusAlert
                  ? Priority.high
                  : Priority.defaultPriority),
        styleInformation: BigTextStyleInformation(n.body),
        category: t == NotificationType.exam || t == NotificationType.session
            ? AndroidNotificationCategory.reminder
            : (t == NotificationType.focusAlert
                  ? AndroidNotificationCategory.alarm
                  : null),
        // sessione Focus: notifica fissa con il conto alla rovescia del
        // sistema (si aggiorna da solo anche ad app chiusa)
        ongoing: n.ongoing,
        autoCancel: !n.ongoing,
        onlyAlertOnce: n.ongoing,
        silent: n.silent,
        showWhen: countdown != null,
        when: countdown?.millisecondsSinceEpoch,
        usesChronometer: countdown != null,
        chronometerCountDown: countdown != null,
        timeoutAfter: countdown
            ?.difference(DateTime.now())
            .inMilliseconds
            .clamp(1000, 1 << 31),
        actions: [
          for (final (id, title) in n.actions)
            AndroidNotificationAction(
              id,
              title,
              showsUserInterface: _uiActions.contains(id),
            ),
        ],
      ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: _category(t),
        threadIdentifier: t.channelId,
        presentSound: n.silent ? false : null,
        // la fine della sessione arriva anche con la Full immersion attiva
        // (se l'utente lo permette nelle impostazioni del sistema)
        interruptionLevel: t == NotificationType.focusAlert
            ? InterruptionLevel.timeSensitive
            : null,
      ),
      macOS: DarwinNotificationDetails(
        categoryIdentifier: _category(t),
        threadIdentifier: t.channelId,
        presentSound: n.silent ? false : null,
      ),
      windows: WindowsNotificationDetails(
        audio: n.silent ? WindowsNotificationAudio.silent() : null,
        actions: [
          for (final (id, title) in n.actions)
            WindowsAction(
              content: title,
              arguments: NotificationTap.windowsArguments(id, n.payload),
            ),
        ],
      ),
    );
  }

  @override
  Future<void> schedule(PlannedNotification n) => _plugin.zonedSchedule(
    id: n.id,
    title: n.title,
    body: n.body,
    payload: n.payload,
    // istante locale convertito in UTC: nessun bisogno del fuso del sistema
    scheduledDate: tz.TZDateTime.from(n.at, tz.UTC),
    notificationDetails: _details(n),
    // niente SCHEDULE_EXACT_ALARM: qualche minuto di ritardo va bene
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
  );

  @override
  Future<void> show(PlannedNotification n) => _plugin.show(
    id: n.id,
    title: n.title,
    body: n.body,
    payload: n.payload,
    notificationDetails: _details(n),
  );

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<void> openSystemSettings() async {
    try {
      await _plugin.openAppNotificationSettings();
    } catch (_) {}
  }
}
