import Flutter
import UIKit
import UserNotifications
import WidgetKit
#if canImport(ActivityKit)
  import ActivityKit
#endif
// FlutterLocalNotificationsPlugin.setPluginRegistrantCallback (pulsanti delle
// notifiche premuti ad app chiusa).
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// App Group condiviso con l'estensione dei widget (docs/widget.md).
  static let appGroup = "group.io.github.simomagnus.universitynotes"
  /// Dati JSON dei widget scritti dall'app (lib/core/reminders/home_widgets.dart).
  static let widgetDataKey = "uninotes_widget_data"
  static let widgetChannelName = "io.github.simomagnus.universitynotes/widgets"
  /// Live Activity della registrazione (lib/features/notes/recorder/
  /// background_controls.dart, docs/widget.md).
  static let liveActivityChannelName =
    "io.github.simomagnus.universitynotes/live_activity"
  /// Comandi dei pulsanti della Live Activity (App Intents eseguiti
  /// nell'app, ios/LiveActivity_da_aggiungere/RecordingIntents.swift).
  static let recordingCommandNotification = Notification.Name(
    "io.github.simomagnus.universitynotes.recordingCommand")

  private var widgetChannel: FlutterMethodChannel?
  private var liveActivityChannel: FlutterMethodChannel?
  /// Trascrizione istantanea delle lezioni (LiveSpeech.swift).
  private var liveSpeech: LiveSpeech?

  /// Schermata chiesta da un widget (`registra`, `prova:12`…), letta una volta
  /// da Flutter con `takeRoute`.
  var pendingWidgetRoute: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // notifiche locali anche con l'app in primo piano e tocchi sulle notifiche
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UniNotesWidgets") {
      let channel = FlutterMethodChannel(
        name: AppDelegate.widgetChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "update":
          // dati dei widget nell'App Group, poi WidgetKit li ridisegna
          if let args = call.arguments as? [String: Any],
            let json = args["json"] as? String
          {
            UserDefaults(suiteName: AppDelegate.appGroup)?
              .set(json, forKey: AppDelegate.widgetDataKey)
            WidgetCenter.shared.reloadAllTimelines()
          }
          result(nil)
        case "takeRoute":
          result(self?.pendingWidgetRoute)
          self?.pendingWidgetRoute = nil
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      widgetChannel = channel
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UniNotesLiveSpeech") {
      liveSpeech = LiveSpeech(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UniNotesLiveActivity") {
      let channel = FlutterMethodChannel(
        name: AppDelegate.liveActivityChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleLiveActivity(call, result: result)
      }
      liveActivityChannel = channel
      NotificationCenter.default.addObserver(
        forName: AppDelegate.recordingCommandNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let command = note.userInfo?["command"] as? String else { return }
        self?.liveActivityChannel?.invokeMethod("command", arguments: command)
      }
    }
  }

  /// Avvio, aggiornamento e chiusura della Live Activity. Senza l'estensione
  /// (target «LiveActivityUniNotes» aggiunto in Xcode) o con le Live
  /// Activity disattivate non fa nulla e risponde false.
  private func handleLiveActivity(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    #if canImport(ActivityKit)
      if #available(iOS 16.2, *), RecordingLiveActivity.available {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "start":
          RecordingLiveActivity.start(args)
          result(true)
        case "update":
          RecordingLiveActivity.update(args)
          result(true)
        case "end":
          RecordingLiveActivity.end()
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
        return
      }
    #endif
    result(false)
  }

  /// Tocco su un widget (`uninotes://widget/<schermata>`): con l'app aperta
  /// la schermata si apre subito, altrimenti Flutter la chiede all'avvio.
  /// Da chiamare dalla SceneDelegate (vedi docs/widget.md).
  func openWidgetURL(_ url: URL) {
    guard url.scheme == "uninotes", url.host == "widget" else { return }
    let route = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !route.isEmpty else { return }
    if let channel = widgetChannel {
      channel.invokeMethod("route", arguments: route)
    } else {
      pendingWidgetRoute = route
    }
  }
}

#if canImport(ActivityKit)
  /// Dati della Live Activity della registrazione. Deve restare identico a
  /// ios/LiveActivity_da_aggiungere/RecordingActivityAttributes.swift
  /// (stesso nome e stessi campi: il sistema li confronta così).
  @available(iOS 16.1, *)
  struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
      /// Registrazione in pausa (tempo fermo).
      var paused: Bool
      /// Inizio «virtuale» per il cronometro nativo: adesso meno il tempo
      /// già registrato (Text(timerInterval:)).
      var timerStart: Date
      /// Tempo registrato, mostrato fermo durante la pausa.
      var elapsedSeconds: Int
    }

    /// Nome del corso.
    var course: String
  }

  @available(iOS 16.2, *)
  enum RecordingLiveActivity {
    static var current: Activity<RecordingActivityAttributes>?

    /// Nome del target dell'estensione (docs/widget.md).
    static let extensionName = "LiveActivityUniNotes.appex"

    /// L'estensione c'è e l'utente non ha disattivato le Live Activity.
    static var available: Bool {
      guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
      let ext = plugins.appendingPathComponent(extensionName)
      guard FileManager.default.fileExists(atPath: ext.path) else { return false }
      return ActivityAuthorizationInfo().areActivitiesEnabled
    }

    static func state(_ args: [String: Any]) -> RecordingActivityAttributes.ContentState {
      let elapsedMs = (args["elapsedMs"] as? NSNumber)?.doubleValue ?? 0
      return RecordingActivityAttributes.ContentState(
        paused: args["paused"] as? Bool ?? false,
        timerStart: Date().addingTimeInterval(-elapsedMs / 1000),
        elapsedSeconds: Int(elapsedMs / 1000)
      )
    }

    static func start(_ args: [String: Any]) {
      end()
      let attributes = RecordingActivityAttributes(
        course: args["course"] as? String ?? "Lezione")
      let content = ActivityContent(state: state(args), staleDate: nil)
      current = try? Activity.request(
        attributes: attributes, content: content, pushType: nil)
    }

    static func update(_ args: [String: Any]) {
      guard let activity = current else { return }
      let content = ActivityContent(state: state(args), staleDate: nil)
      Task { await activity.update(content) }
    }

    static func end() {
      guard let activity = current else { return }
      current = nil
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
  }
#endif
