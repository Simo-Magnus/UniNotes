import BackgroundTasks
import Flutter
import UIKit
import UserNotifications
import EventKit
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
  /// Esito del comando «UniNotes Focus» (Non disturbare durante le sessioni
  /// Focus, lib/features/study/focus/focus_system.dart).
  static let focusChannelName = "io.github.simomagnus.universitynotes/focus"
  /// Live Activity della registrazione (lib/features/notes/recorder/
  /// background_controls.dart, docs/widget.md).
  static let liveActivityChannelName =
    "io.github.simomagnus.universitynotes/live_activity"
  /// Comandi dei pulsanti della Live Activity (App Intents eseguiti
  /// nell'app, ios/WidgetUniNotes/RecordingIntents.swift).
  static let recordingCommandNotification = Notification.Name(
    "io.github.simomagnus.universitynotes.recordingCommand")

  private var widgetChannel: FlutterMethodChannel?
  private var focusChannel: FlutterMethodChannel?
  /// Prove nel calendario del dispositivo (UniNotesCalendar, sotto).
  private var calendar: UniNotesCalendar?
  private var liveActivityChannel: FlutterMethodChannel?
  /// Osservatore dei pulsanti della Live Activity (uno solo).
  private var recordingObserver: NSObjectProtocol?
  /// Trascrizione istantanea delle lezioni (LiveSpeech.swift).
  private var liveSpeech: LiveSpeech?
  /// File aperti con «Apri in UniNotes» / «Condividi» (IncomingFiles, sotto).
  private var incomingFiles: IncomingFiles?
  /// «Apri con…» di un file dell'app (UniNotesOpenWith, in fondo).
  private var openWith: UniNotesOpenWith?

  /// Schermata chiesta da un widget (`registra`, `prova:12`…), letta una volta
  /// da Flutter con `takeRoute`.
  var pendingWidgetRoute: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // notifiche locali anche con l'app in primo piano e tocchi sulle notifiche
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    // sincronizzazione con OneDrive e Google Drive in background (il
    // compito va registrato prima della fine dell'avvio)
    _ = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: AppDelegate.syncTaskId, using: nil
    ) { [weak self] task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self?.handleSync(refresh)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Aggiornamento in background di iOS per la sincronizzazione
  /// (lib/core/services/background_sync.dart): il sistema sceglie quando;
  /// ogni volta Flutter riceve `run` e risponde a fine lavoro.
  static let syncTaskId = "io.github.simomagnus.universitynotes.sync"
  static let syncChannelName = "io.github.simomagnus.universitynotes/sincronizzazione"
  static let syncMinutesKey = "uninotes_sync_minutes"
  private var syncChannel: FlutterMethodChannel?

  private func handleSync(_ task: BGAppRefreshTask) {
    scheduleSync()
    var done = false
    let finish: (Bool) -> Void = { ok in
      DispatchQueue.main.async {
        if done { return }
        done = true
        task.setTaskCompleted(success: ok)
      }
    }
    task.expirationHandler = { finish(false) }
    DispatchQueue.main.async { [weak self] in
      guard let channel = self?.syncChannel else {
        finish(false)
        return
      }
      channel.invokeMethod("run", arguments: nil) { result in
        finish((result as? Bool) ?? false)
      }
    }
  }

  /// Prossimo aggiornamento non prima dell'intervallo scelto (minimo 15
  /// minuti; il sistema può aspettare di più).
  private func scheduleSync() {
    let minutes = UserDefaults.standard.integer(forKey: AppDelegate.syncMinutesKey)
    guard minutes > 0 else { return }
    let request = BGAppRefreshTaskRequest(identifier: AppDelegate.syncTaskId)
    request.earliestBeginDate = Date(timeIntervalSinceNow: Double(max(minutes, 15)) * 60)
    try? BGTaskScheduler.shared.submit(request)
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UniNotesIncomingFiles") {
      let incoming = IncomingFiles(messenger: registrar.messenger())
      // collegamenti uninotes:// (widget, comando Focus)
      incoming.onAppLink = { [weak self] url in self?.openAppURL(url) ?? false }
      // eventi della scena (apertura di file, anche all'avvio)
      registrar.addSceneDelegate(incoming)
      incomingFiles = incoming
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UniNotesFocus") {
      focusChannel = FlutterMethodChannel(
        name: AppDelegate.focusChannelName,
        binaryMessenger: registrar.messenger()
      )
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UniNotesCalendar") {
      calendar = UniNotesCalendar(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UniNotesBackgroundSync") {
      let channel = FlutterMethodChannel(
        name: AppDelegate.syncChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "schedule":
          let args = call.arguments as? [String: Any] ?? [:]
          let minutes = (args["minutes"] as? NSNumber)?.intValue ?? 15
          UserDefaults.standard.set(minutes, forKey: AppDelegate.syncMinutesKey)
          self?.scheduleSync()
          result(true)
        case "cancel":
          UserDefaults.standard.removeObject(forKey: AppDelegate.syncMinutesKey)
          BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppDelegate.syncTaskId)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      syncChannel = channel
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UniNotesLiveSpeech") {
      liveSpeech = LiveSpeech(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UniNotesOpenWith") {
      openWith = UniNotesOpenWith(messenger: registrar.messenger())
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
      // un solo osservatore anche se il motore viene ricreato (scena chiusa
      // dal sistema e riaperta): con due, ogni pulsante della Live Activity
      // arrivava due volte a Flutter («Pausa» subito annullata)
      if let old = recordingObserver { NotificationCenter.default.removeObserver(old) }
      recordingObserver = NotificationCenter.default.addObserver(
        forName: AppDelegate.recordingCommandNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let command = note.userInfo?["command"] as? String else { return }
        self?.liveActivityChannel?.invokeMethod("command", arguments: command)
      }
    }
  }

  /// Avvio, aggiornamento e chiusura della Live Activity. Senza l'estensione
  /// (target «WidgetUniNotes», aggiunto dalla build automatica con
  /// tool/aggiungi_estensioni_ios.rb), sotto iOS 16.2 o con le Live Activity
  /// disattivate non fa nulla e risponde false.
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

  /// Collegamenti `uninotes://` (schema in CFBundleURLTypes dell'Info.plist),
  /// ricevuti dalla scena tramite IncomingFiles:
  /// - `uninotes://widget/<schermata>`: tocco su un widget;
  /// - `uninotes://focus/ok|errore|annullato`: Comandi torna nell'app dopo
  ///   il comando «UniNotes Focus» (x-callback-url) e Flutter riceve
  ///   l'esito con `shortcutResult`.
  /// true se il collegamento è dell'app.
  func openAppURL(_ url: URL) -> Bool {
    guard url.scheme == "uninotes" else { return false }
    switch url.host ?? "" {
    case "widget":
      openWidgetURL(url)
      return true
    case "focus":
      let result = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      focusChannel?.invokeMethod("shortcutResult", arguments: result)
      return true
    default:
      return false
    }
  }

  /// Tocco su un widget (`uninotes://widget/<schermata>`): con l'app aperta
  /// la schermata si apre subito, altrimenti Flutter la chiede all'avvio.
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

/// File arrivati da altre app con «Apri in UniNotes» o dal foglio
/// «Condividi» (tipi dichiarati in CFBundleDocumentTypes dell'Info.plist).
/// Ogni file si copia nella cartella temporanea dell'app (anche quelli
/// aperti sul posto, con accesso protetto) e resta in attesa finché Flutter
/// non lo prende con `take` (lib/features/cloud/incoming_files.dart); con
/// l'app aperta Flutter riceve `available`.
final class IncomingFiles: NSObject, FlutterSceneLifeCycleDelegate {
  static let channelName = "io.github.simomagnus.universitynotes/incoming"
  private let channel: FlutterMethodChannel
  private var pending: [[String: Any]] = []
  /// Collegamenti `uninotes://` (non file): li gestisce l'AppDelegate.
  var onAppLink: ((URL) -> Bool)?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: IncomingFiles.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "take" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.pending ?? [])
      self?.pending = []
    }
  }

  /// App avviata aprendo un file.
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let contexts = connectionOptions?.urlContexts, !contexts.isEmpty else { return false }
    return receive(contexts)
  }

  /// File aperto con l'app già avviata.
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    return receive(URLContexts)
  }

  /// File ricevuti finora (numero nel nome della copia, sempre diverso).
  private var received = 0

  private func receive(_ contexts: Set<UIOpenURLContext>) -> Bool {
    var files: [(url: URL, inPlace: Bool)] = []
    var linked = false
    for context in contexts {
      if context.url.isFileURL {
        files.append((url: context.url, inPlace: context.options.openInPlace))
      } else if onAppLink?(context.url) == true {
        linked = true
      }
    }
    guard !files.isEmpty else { return linked }
    // La copia fuori dal filo principale: un file di iCloud Drive non
    // ancora sul telefono si scarica durante la lettura coordinata, e un file
    // grande richiede tempo; sul filo principale l'app restava bloccata e
    // all'avvio (aperta da «Apri in UniNotes») iOS la chiudeva (watchdog).
    // Flutter riceve `available` quando le copie sono pronte.
    let first = received
    received += files.count
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var items: [[String: Any]] = []
      for (i, file) in files.enumerated() {
        if let item = IncomingFiles.copy(file.url, inPlace: file.inPlace, index: first + i) {
          items.append(item)
        }
      }
      DispatchQueue.main.async {
        guard let self = self, !items.isEmpty else { return }
        self.pending.append(contentsOf: items)
        self.channel.invokeMethod("available", arguments: nil)
      }
    }
    return true
  }

  private static func copy(_ url: URL, inPlace: Bool, index: Int) -> [String: Any]? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("condivisi", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = url.lastPathComponent
    let stamp = Int(Date().timeIntervalSince1970 * 1000)
    let target = dir.appendingPathComponent(
      "\(stamp)_\(index)_\(IncomingFiles.shortName(name))")
    // lettura coordinata: file di iCloud Drive o di altri fornitori
    var coordError: NSError?
    var copyError: Error?
    NSFileCoordinator().coordinate(
      readingItemAt: url, options: .withoutChanges, error: &coordError
    ) { readURL in
      do {
        try fm.copyItem(at: readURL, to: target)
      } catch {
        copyError = error
      }
    }
    if coordError != nil || copyError != nil { return nil }
    // copia messa dal sistema in Documents/Inbox: non serve più
    if !inPlace { try? fm.removeItem(at: url) }
    return ["path": target.path, "name": name, "temporary": true]
  }

  /// Nome entro il limite del file system (255 byte, con il prefisso
  /// aggiunto in `copy`): con un nome già vicino al limite la copia non
  /// riusciva e il file andava perso. Si accorcia tenendo l'estensione.
  static func shortName(_ name: String, maxBytes: Int = 200) -> String {
    if name.utf8.count <= maxBytes { return name }
    var ext = (name as NSString).pathExtension
    if ext.utf8.count > 15 { ext = "" }
    let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    let budget = maxBytes - (ext.isEmpty ? 0 : ext.utf8.count + 1)
    var cut = ""
    var used = 0
    for ch in base {
      let bytes = String(ch).utf8.count
      if used + bytes > budget { break }
      cut.append(ch)
      used += bytes
    }
    if cut.isEmpty { cut = "File condiviso" }
    return ext.isEmpty ? cut : "\(cut).\(ext)"
  }
}

#if canImport(ActivityKit)
  /// Dati della Live Activity della registrazione. Deve restare identico a
  /// ios/WidgetUniNotes/RecordingActivityAttributes.swift
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

    /// Estensione con i widget e la Live Activity (docs/widget.md).
    static let extensionName = "WidgetUniNotes.appex"

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

/// Calendario del dispositivo con EventKit, per le prove dell'app
/// (lib/core/reminders/apple_calendar_backend.dart). Canale
/// `io.github.simomagnus.universitynotes/calendario`:
/// - `access` → concesso | da_chiedere | solo_scrittura | negato;
/// - `request` → true se l'utente dà l'accesso completo;
/// - `ensureCalendar` {knownId?, name, color} → id del calendario «UniNotes»
///   (lo crea nell'account dove l'utente vede i suoi calendari: iCloud se è
///   attivo, altrimenti sul dispositivo; se nessun account lo permette usa
///   il calendario predefinito);
/// - `events` {calendarId, startMs, endMs} → [{id, notes}] (a blocchi di un
///   anno: EventKit cerca al massimo 4 anni per volta);
/// - `write` {calendarId, eventId?, title, notes, location?, startMs, endMs,
///   allDay, alarms} → id dell'evento creato o aggiornato (errore
///   `non_trovato` se l'evento da aggiornare non c'è più);
/// - `delete` {eventId}; `deleteCalendarIfEmpty` {calendarId, name} → true
///   se il calendario «UniNotes» vuoto è stato eliminato.
/// Senza permesso ogni chiamata risponde con l'errore `permesso`.
final class UniNotesCalendar: NSObject {
  static let channelName = "io.github.simomagnus.universitynotes/calendario"
  /// Riga che lega un evento alla prova (kCalendarMarker in
  /// lib/core/reminders/system_calendar.dart).
  static let marker = "Rif. UniNotes: "
  /// Calendario creato dalle versioni precedenti (ora gli eventi vanno nel
  /// calendario dello studente).
  static let legacyName = "UniNotes"

  private struct Failure: Error {
    let code: String
    let message: String
  }

  private let channel: FlutterMethodChannel
  private var store = EKEventStore()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: UniNotesCalendar.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handle(call, result: result)
    }
  }

  private static func status() -> String {
    let s = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, macOS 14.0, *) {
      if s == .fullAccess { return "concesso" }
      if s == .writeOnly { return "solo_scrittura" }
    }
    switch s {
    case .authorized: return "concesso"
    case .notDetermined: return "da_chiedere"
    default: return "negato"
    }
  }

  private func request(_ result: @escaping FlutterResult) {
    if UniNotesCalendar.status() == "concesso" {
      result(true)
      return
    }
    let done: (Bool, Error?) -> Void = { [weak self] granted, _ in
      DispatchQueue.main.async {
        // l'archivio creato prima del permesso non vede i calendari
        if granted { self?.store = EKEventStore() }
        result(granted)
      }
    }
    if #available(iOS 17.0, macOS 14.0, *) {
      store.requestFullAccessToEvents(completion: done)
    } else {
      store.requestAccess(to: .event, completion: done)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "access":
      result(UniNotesCalendar.status())
      return
    case "request":
      request(result)
      return
    default:
      break
    }
    guard UniNotesCalendar.status() == "concesso" else {
      result(FlutterError(code: "permesso", message: "Permesso del calendario negato.", details: nil))
      return
    }
    do {
      switch call.method {
      case "ensureCalendar":
        result(
          try ensureCalendar(
            knownId: args["knownId"] as? String,
            name: args["name"] as? String ?? "UniNotes",
            color: (args["color"] as? NSNumber)?.intValue ?? 0x38BDF8))
      case "calendars":
        result(calendars())
      case "health":
        result(health(args))
      case "events":
        guard let cal = calendar(args) else {
          throw Failure(code: "calendario", message: "Calendario non trovato.")
        }
        result(events(in: cal, from: date(args["startMs"]), to: date(args["endMs"])))
      case "write":
        result(try write(args))
      case "delete":
        if let id = args["eventId"] as? String, let ev = store.event(withIdentifier: id) {
          try store.remove(ev, span: .thisEvent, commit: true)
        }
        result(nil)
      case "deleteCalendarIfEmpty":
        result(try deleteCalendarIfEmpty(args))
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let f as Failure {
      result(FlutterError(code: f.code, message: f.message, details: nil))
    } catch {
      result(FlutterError(code: "errore", message: error.localizedDescription, details: nil))
    }
  }

  /// Calendari per la scelta in Impostazioni → Calendario (senza quelli che
  /// l'app Calendario non mostra): `primary` = predefinito per i nuovi
  /// eventi, dove l'app scrive se lo studente non ne sceglie un altro;
  /// `legacy` = «UniNotes» delle versioni precedenti (si svuota e si toglie).
  private func calendars() -> [[String: Any]] {
    let def = store.defaultCalendarForNewEvents?.calendarIdentifier
    var out: [[String: Any]] = []
    for c in store.calendars(for: .event) where !hidden(c) {
      let source: EKSource? = c.source
      out.append([
        "id": c.calendarIdentifier,
        "name": c.title,
        "account": source?.title ?? "",
        "accountType": source?.sourceType == .local ? "local" : "account",
        "primary": c.calendarIdentifier == def,
        "synced": true,
        "writable": c.allowsContentModifications,
        "legacy": c.title == UniNotesCalendar.legacyName && c.calendarIdentifier != def,
      ])
    }
    return out
  }

  /// Controllo di salute: il calendario c'è ancora ed è modificabile.
  private func health(_ args: [String: Any]) -> [String: Any] {
    guard let cal = calendar(args) else { return ["exists": false] }
    return ["exists": true, "writable": cal.allowsContentModifications, "synced": true]
  }

  private func date(_ v: Any?) -> Date {
    Date(timeIntervalSince1970: ((v as? NSNumber)?.doubleValue ?? 0) / 1000)
  }

  private func calendar(_ args: [String: Any]) -> EKCalendar? {
    guard let id = args["calendarId"] as? String else { return nil }
    return store.calendar(withIdentifier: id)
  }

  /// iPhone e iPad: con i calendari di iCloud attivi quelli «Sul mio
  /// iPhone» non compaiono nell'app Calendario (sul Mac sì).
  private func hidden(_ cal: EKCalendar) -> Bool {
    #if os(iOS)
      let source: EKSource? = cal.source
      guard source?.sourceType == .local else { return false }
      let main: EKSource? = store.defaultCalendarForNewEvents?.source
      return (main?.sourceType ?? .local) != .local
    #else
      return false
    #endif
  }

  private func setColor(_ cal: EKCalendar, _ argb: Int) {
    let r = CGFloat((argb >> 16) & 0xFF) / 255
    let g = CGFloat((argb >> 8) & 0xFF) / 255
    let b = CGFloat(argb & 0xFF) / 255
    #if os(iOS)
      cal.cgColor = UIColor(red: r, green: g, blue: b, alpha: 1).cgColor
    #else
      cal.color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    #endif
  }

  private func ensureCalendar(knownId: String?, name: String, color: Int) throws -> String {
    let all = store.calendars(for: .event)
    var id: String?
    if let known = knownId, let c = store.calendar(withIdentifier: known),
      c.allowsContentModifications, !hidden(c)
    {
      id = known
    }
    if id == nil {
      id = all.first(where: {
        $0.title == name && $0.allowsContentModifications && !hidden($0)
      })?.calendarIdentifier
    }
    let chosen = try id ?? create(name, color: color)
    // calendari «UniNotes» che l'utente non vede (creati da versioni
    // precedenti sul dispositivo con iCloud attivo): eventi dell'app via
    for c in all where c.title == name && hidden(c) && c.calendarIdentifier != chosen {
      moveOut(c)
    }
    return chosen
  }

  private func create(_ name: String, color: Int) throws -> String {
    var sources: [EKSource] = []
    func add(_ s: EKSource?) {
      guard let s = s, !sources.contains(where: { $0.sourceIdentifier == s.sourceIdentifier })
      else { return }
      sources.append(s)
    }
    // dove l'utente vede i suoi calendari, poi iCloud, poi il dispositivo
    add(store.defaultCalendarForNewEvents?.source)
    for s in store.sources where s.sourceType == .calDAV && s.title == "iCloud" { add(s) }
    for s in store.sources where s.sourceType == .local { add(s) }
    for source in sources {
      let cal = EKCalendar(for: .event, eventStore: store)
      cal.title = name
      cal.source = source
      setColor(cal, color)
      if hidden(cal) { continue }
      do {
        try store.saveCalendar(cal, commit: true)
        return cal.calendarIdentifier
      } catch {
        continue
      }
    }
    // nessun account permette di creare calendari: il predefinito (gli
    // eventi dell'app si riconoscono dalla riga «Rif. UniNotes»)
    if let d = store.defaultCalendarForNewEvents, d.allowsContentModifications {
      return d.calendarIdentifier
    }
    if let c = store.calendars(for: .event).first(where: { $0.allowsContentModifications }) {
      return c.calendarIdentifier
    }
    throw Failure(code: "calendario", message: "Nessun calendario modificabile sul dispositivo.")
  }

  /// Toglie gli eventi dell'app da [cal] e il calendario se resta vuoto.
  private func moveOut(_ cal: EKCalendar) {
    let now = Date()
    let from = now.addingTimeInterval(-3 * 365 * 86400)
    let to = now.addingTimeInterval(5 * 365 * 86400)
    for e in events(in: cal, from: from, to: to) {
      guard let notes = e["notes"] as? String, notes.contains(UniNotesCalendar.marker),
        let id = e["id"] as? String, let ev = store.event(withIdentifier: id)
      else { continue }
      try? store.remove(ev, span: .thisEvent, commit: true)
    }
    if !cal.isImmutable, events(in: cal, from: from, to: to).isEmpty {
      try? store.removeCalendar(cal, commit: true)
    }
  }

  private func events(in cal: EKCalendar, from start: Date, to end: Date) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var seen = Set<String>()
    var from = start
    while from < end {
      let to = min(from.addingTimeInterval(365 * 86400), end)
      let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [cal])
      for ev in store.events(matching: predicate) {
        let eventId: String? = ev.eventIdentifier
        guard let id = eventId, !seen.contains(id) else { continue }
        seen.insert(id)
        out.append(["id": id, "notes": ev.notes ?? ""])
      }
      from = to
    }
    return out
  }

  private func write(_ args: [String: Any]) throws -> String {
    guard let cal = calendar(args) else {
      throw Failure(code: "calendario", message: "Calendario non trovato.")
    }
    guard cal.allowsContentModifications else {
      throw Failure(code: "calendario", message: "Il calendario è di sola lettura.")
    }
    let ev: EKEvent
    if let id = args["eventId"] as? String {
      guard let found = store.event(withIdentifier: id) else {
        throw Failure(code: "non_trovato", message: "Evento non trovato.")
      }
      ev = found
    } else {
      ev = EKEvent(eventStore: store)
    }
    ev.calendar = cal
    ev.title = args["title"] as? String ?? ""
    ev.notes = args["notes"] as? String
    ev.location = args["location"] as? String
    let allDay = args["allDay"] as? Bool ?? false
    ev.isAllDay = allDay
    ev.startDate = date(args["startMs"])
    ev.endDate = date(args["endMs"])
    ev.timeZone = allDay ? nil : TimeZone.current
    let minutes = (args["alarms"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
    ev.alarms = minutes.map { EKAlarm(relativeOffset: -$0 * 60) }
    try store.save(ev, span: .thisEvent, commit: true)
    let eventId: String? = ev.eventIdentifier
    guard let id = eventId else {
      throw Failure(code: "errore", message: "Evento non scritto.")
    }
    return id
  }

  private func deleteCalendarIfEmpty(_ args: [String: Any]) throws -> Bool {
    guard let cal = calendar(args), cal.title == (args["name"] as? String ?? "UniNotes"),
      !cal.isImmutable,
      store.defaultCalendarForNewEvents?.calendarIdentifier != cal.calendarIdentifier
    else { return false }
    let now = Date()
    let left = events(
      in: cal, from: now.addingTimeInterval(-10 * 365 * 86400),
      to: now.addingTimeInterval(10 * 365 * 86400))
    if !left.isEmpty { return false }
    try store.removeCalendar(cal, commit: true)
    return true
  }
}

/// «Apri con…» (canale "io.github.simomagnus.universitynotes/apri_con", vedi
/// lib/core/services/external_launcher.dart): il menu «Apri in…» di iOS
/// (UIDocumentInteractionController) con le app che sanno aprire il file.
/// Risponde "ok", "nessuna_app" o "errore".
final class UniNotesOpenWith: NSObject, UIDocumentInteractionControllerDelegate {
  private let channel: FlutterMethodChannel
  /// Il controller resta vivo finché il menu è aperto.
  private var controller: UIDocumentInteractionController?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "io.github.simomagnus.universitynotes/apri_con",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "openWith",
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.open(path, result: result)
    }
  }

  private func open(_ path: String, result: FlutterResult) {
    guard let view = UniNotesOpenWith.topViewController()?.view else {
      result("errore")
      return
    }
    let c = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
    c.delegate = self
    controller = c
    let rect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    result(c.presentOpenInMenu(from: rect, in: view, animated: true) ? "ok" : "nessuna_app")
  }

  func documentInteractionControllerDidDismissOpenInMenu(
    _ controller: UIDocumentInteractionController
  ) {
    self.controller = nil
  }

  private static func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    var vc = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }
}
