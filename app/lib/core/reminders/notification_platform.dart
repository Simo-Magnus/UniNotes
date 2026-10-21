import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color, DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../constants/build_flags.dart';
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

/// Pulsanti premuti senza aprire l'app («Più tardi», «Non chiedere più»,
/// «Non ricordarmelo per questa prova»): girano in un isolate in
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
  LocalNotificationPlatform([
    FlutterLocalNotificationsPlugin? plugin,
    this.donationsAllowed = kShowDonationLink,
  ]) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;

  /// Build con le donazioni consentite (`DONATIONS=link`): altrimenti il
  /// canale, la categoria e la notifica del sostegno non esistono.
  final bool donationsAllowed;

  /// La notifica [n] esiste in questa build?
  bool allows(PlannedNotification n) =>
      n.type != NotificationType.donation || donationsAllowed;
  bool _ready = false;

  static bool get supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  /// Icona piccola (bianca, monocromatica; tools/genera_icona.py) e
  /// blu del logo (#0F72F2): leggibile (nome dell'app e icona colorati dal
  /// sistema) sia sulla tendina chiara sia su quella scura.
  static const _icon = 'ic_stat_uninotes';
  static const _accent = Color(0xFF0F72F2);

  /// App non pacchettizzata su Windows: nome e identità fissi (il GUID
  /// registra l'attivazione al tocco anche ad app chiusa).
  static const _windowsGuid = '5d3f2b7e-91c4-4a8e-b6f1-0c7a2e9d4b13';

  static String _category(NotificationType t) => 'uninotes_${t.channelId}';

  /// Categorie di iOS e macOS (pulsanti di ogni tipo): quella del sostegno,
  /// con «Dona», solo nelle build che consentono le donazioni.
  @visibleForTesting
  static List<DarwinNotificationCategory> categoriesFor({
    required bool donationsAllowed,
  }) => [
    for (final t in NotificationType.available(
      donationsAllowed: donationsAllowed,
    ))
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
      (NotificationActions.never, 'Non chiedere più'),
    ],
    NotificationType.donation => const [
      (NotificationActions.donate, 'Dona'),
      (NotificationActions.later, 'Più tardi'),
      (NotificationActions.never, 'Non chiedere più'),
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
      notificationCategories: categoriesFor(
        donationsAllowed: donationsAllowed,
      ),
    );
    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings(_icon),
        iOS: darwin,
        macOS: darwin,
        linux: const LinuxInitializationSettings(defaultActionName: 'Apri'),
        // logo dell'app nei toast (senza, Windows mostra un'icona vuota
        // per le app non pacchettizzate)
        windows: WindowsInitializationSettings(
          appName: 'UniNotes',
          appUserModelId: 'io.github.simomagnus.universitynotes',
          guid: _windowsGuid,
          iconPath: _windowsArt('uninotes.png'),
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
      // canali raggruppati per sezione nelle impostazioni del sistema
      for (final MapEntry(key: id, value: (name, description))
          in kNotificationGroups.entries) {
        await android.createNotificationChannelGroup(
          AndroidNotificationChannelGroup(id, name, description: description),
        );
      }
      // niente canale «Sostieni il progetto» dove le donazioni non sono
      // consentite (se c'era da una versione precedente, si toglie)
      if (!donationsAllowed) {
        await android.deleteNotificationChannel(
          channelId: NotificationType.donation.channelId,
        );
      }
      for (final t in NotificationType.available(
        donationsAllowed: donationsAllowed,
      )) {
        await android.createNotificationChannel(
          AndroidNotificationChannel(
            t.channelId,
            t.channelName,
            description: t.description,
            groupId: t.groupId,
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

  /// Grafica di Windows accanto all'eseguibile (data/flutter_assets, anche
  /// nelle build di debug e nel pacchetto MSIX): percorso assoluto, così
  /// funziona anche quando l'app parte da un toast con un'altra cartella di
  /// lavoro. Null se il file manca (il toast esce senza immagine).
  static String? _windowsArt(String name) {
    if (!Platform.isWindows) return null;
    try {
      final dir = File(Platform.resolvedExecutable).parent.path;
      final f = File('$dir\\data\\flutter_assets\\assets\\notifiche\\$name');
      return f.existsSync() ? f.path : null;
    } catch (_) {
      return null;
    }
  }

  /// Copia per iOS e macOS dell'immagine larga [name] da allegare: il
  /// sistema sposta il file allegato nel suo archivio, quindi serve una
  /// copia per ogni notifica. Null se non riesce (notifica senza allegato).
  static Future<String?> _darwinArt(String name, int id) async {
    if (!(Platform.isIOS || Platform.isMacOS)) return null;
    try {
      final data = await rootBundle.load('assets/notifiche/$name');
      final dir = Directory(
        '${(await getTemporaryDirectory()).path}/notifiche',
      );
      await dir.create(recursive: true);
      final f = File('${dir.path}/${id}_$name');
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return f.path;
    } catch (e) {
      debugPrint('Immagine della notifica non preparata: $e');
      return null;
    }
  }

  Future<NotificationDetails> _details(PlannedNotification n) async {
    final t = n.type;
    return detailsFor(
      n,
      windowsLogo: _windowsArt('${t.artwork}.png'),
      windowsHero: t.hasHero ? _windowsArt('hero_${t.artwork}.png') : null,
      darwinAttachment: t.hasHero
          ? await _darwinArt('hero_${t.artwork}.png', n.id)
          : null,
    );
  }

  /// Aspetto della notifica [n] su ogni piattaforma (funzione pura, test in
  /// test/notification_design_test.dart):
  /// - Android: icona piccola monocromatica, azzurro dell'app, icona grande
  ///   del tipo, sezione accanto al nome dell'app, testo esteso (le prove:
  ///   una riga per data e luogo), pulsanti;
  /// - iOS e macOS: sezione come sottotitolo, notifiche impilate per
  ///   sezione, immagine larga allegata per le notifiche rare;
  /// - Windows: logo del tipo al posto di quello dell'app, immagine larga
  ///   per le notifiche rare, intestazione della sezione nel Centro
  ///   notifiche, pulsanti.
  @visibleForTesting
  static NotificationDetails detailsFor(
    PlannedNotification n, {
    String? windowsLogo,
    String? windowsHero,
    String? darwinAttachment,
  }) {
    final t = n.type;
    final countdown = n.countdownTo;
    final section = t.section;
    // le prove: «martedì 20 gennaio alle 9:00 · Aula 5» diventa un elenco
    final lines = t == NotificationType.exam
        ? n.body.split(' · ').where((l) => l.trim().isNotEmpty).toList()
        : const <String>[];
    final StyleInformation style = lines.length > 1
        ? InboxStyleInformation(
            lines,
            contentTitle: n.title,
            summaryText: section,
          )
        : BigTextStyleInformation(
            n.body,
            contentTitle: n.title,
            summaryText: section,
          );
    final threadId = 'uninotes_${t.groupId}';
    return NotificationDetails(
      android: AndroidNotificationDetails(
        t.channelId,
        t.channelName,
        channelDescription: t.description,
        icon: _icon,
        color: _accent,
        largeIcon: DrawableResourceAndroidBitmap('ic_notif_${t.artwork}'),
        subText: section,
        ticker: n.title,
        importance: _importance(t),
        channelBypassDnd: _bypassDnd(t),
        priority: t.promotional || n.ongoing
            ? Priority.low
            : (t == NotificationType.focusAlert
                  ? Priority.high
                  : Priority.defaultPriority),
        styleInformation: style,
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
        threadIdentifier: threadId,
        subtitle: section,
        presentSound: n.silent ? false : null,
        attachments: darwinAttachment == null
            ? null
            : [DarwinNotificationAttachment(darwinAttachment)],
        // la fine della sessione arriva anche con la Full immersion attiva
        // (se l'utente lo permette nelle impostazioni del sistema)
        interruptionLevel: t == NotificationType.focusAlert
            ? InterruptionLevel.timeSensitive
            : null,
      ),
      macOS: DarwinNotificationDetails(
        categoryIdentifier: _category(t),
        threadIdentifier: threadId,
        subtitle: section,
        presentSound: n.silent ? false : null,
        attachments: darwinAttachment == null
            ? null
            : [DarwinNotificationAttachment(darwinAttachment)],
      ),
      windows: WindowsNotificationDetails(
        audio: n.silent ? WindowsNotificationAudio.silent() : null,
        // prove, sessioni, esiti e avvisi Focus restano più a lungo
        duration: switch (t) {
          NotificationType.exam ||
          NotificationType.session ||
          NotificationType.outcome ||
          NotificationType.focusAlert => WindowsNotificationDuration.long,
          _ => null,
        },
        header: section == null
            ? null
            : WindowsHeader(
                id: threadId,
                title: section,
                arguments: 'sezione:$section',
              ),
        images: [
          if (windowsLogo != null)
            WindowsImage(
              Uri.file(windowsLogo, windows: true),
              altText: section ?? 'UniNotes',
              placement: WindowsImagePlacement.appLogoOverride,
            ),
          if (windowsHero != null)
            WindowsImage(
              Uri.file(windowsHero, windows: true),
              altText: n.title,
              placement: WindowsImagePlacement.hero,
            ),
        ],
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

  // Ultimo controllo: una notifica che non esiste in questa build (il
  // sostegno senza DONATIONS=link) non si pianifica né si mostra.
  @override
  Future<void> schedule(PlannedNotification n) async {
    if (!allows(n)) return;
    await _plugin.zonedSchedule(
      id: n.id,
      title: n.title,
      body: n.body,
      payload: n.payload,
      // istante locale convertito in UTC: nessun bisogno del fuso del sistema
      scheduledDate: tz.TZDateTime.from(n.at, tz.UTC),
      notificationDetails: await _details(n),
      // niente SCHEDULE_EXACT_ALARM: qualche minuto di ritardo va bene
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  @override
  Future<void> show(PlannedNotification n) async {
    if (!allows(n)) return;
    await _plugin.show(
      id: n.id,
      title: n.title,
      body: n.body,
      payload: n.payload,
      notificationDetails: await _details(n),
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<void> openSystemSettings() async {
    try {
      await _plugin.openAppNotificationSettings();
    } catch (_) {}
  }
}
