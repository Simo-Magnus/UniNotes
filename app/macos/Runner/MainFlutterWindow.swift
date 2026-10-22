import Cocoa
import EventKit
import FlutterMacOS
import UniformTypeIdentifiers
import WidgetKit

class MainFlutterWindow: NSWindow {
  /// App Group condiviso con l'estensione dei widget (docs/widget.md).
  static let appGroup = "group.io.github.simomagnus.universitynotes"
  /// Dati JSON dei widget scritti dall'app (lib/core/reminders/home_widgets.dart).
  static let widgetDataKey = "uninotes_widget_data"

  private var widgetChannel: FlutterMethodChannel?
  /// «Disinstalla UniNotes» (lib/core/services/app_uninstall.dart).
  private var uninstallChannel: FlutterMethodChannel?
  /// Trascrizione istantanea delle lezioni (LiveSpeech.swift).
  private var liveSpeech: LiveSpeech?
  /// Prove nel calendario del Mac (UniNotesCalendar, sotto).
  private var calendar: UniNotesCalendar?
  /// Controllo ortografico dei campi di testo (UniNotesSpellCheck, sotto).
  private var spellCheck: UniNotesSpellCheck?
  /// «Apri con…»: scelta dell'app con cui aprire un file (UniNotesOpenWith).
  private var openWith: UniNotesOpenWith?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Widget «Prossime prove» e «Registra lezione»: l'app scrive i dati
    // nell'App Group e chiede a WidgetKit di ridisegnarli.
    let channel = FlutterMethodChannel(
      name: "io.github.simomagnus.universitynotes/widgets",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "update":
        if let args = call.arguments as? [String: Any],
          let json = args["json"] as? String
        {
          UserDefaults(suiteName: MainFlutterWindow.appGroup)?
            .set(json, forKey: MainFlutterWindow.widgetDataKey)
          WidgetCenter.shared.reloadAllTimelines()
        }
        result(nil)
      case "takeRoute":
        // tocco su un widget che ha aperto l'app (AppLinks, sotto)
        result(AppLinks.shared.pendingRoute)
        AppLinks.shared.pendingRoute = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    widgetChannel = channel
    AppLinks.shared.widgetChannel = channel
    // esito del comando «UniNotes Focus» (Non disturbare durante Focus)
    AppLinks.shared.focusChannel = FlutterMethodChannel(
      name: "io.github.simomagnus.universitynotes/focus",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    // Disinstallazione dall'app e identità dell'installazione (per
    // riconoscere una reinstallazione con i dati rimasti nel contenitore).
    let uninstall = FlutterMethodChannel(
      name: "io.github.simomagnus.universitynotes/disinstalla",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    uninstall.setMethodCallHandler { call, result in
      let bundle = Bundle.main.bundleURL
      switch call.method {
      case "installIdentity":
        // data di creazione e inode di UniNotes.app: cambiano reinstallando
        let attrs = try? FileManager.default.attributesOfItem(atPath: bundle.path)
        let created = (attrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
        result("mac:\(Int64(created * 1000)):\(inode)")
      case "trashApp":
        // nella sandbox di solito non è permesso: allora l'app mostra il
        // pacchetto nel Finder e spiega come trascinarlo nel Cestino
        do {
          try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
          result(true)
        } catch {
          result(false)
        }
      case "revealApp":
        NSWorkspace.shared.activateFileViewerSelecting([bundle])
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    uninstallChannel = uninstall
    liveSpeech = LiveSpeech(messenger: flutterViewController.engine.binaryMessenger)
    calendar = UniNotesCalendar(messenger: flutterViewController.engine.binaryMessenger)
    spellCheck = UniNotesSpellCheck(messenger: flutterViewController.engine.binaryMessenger)
    openWith = UniNotesOpenWith(
      messenger: flutterViewController.engine.binaryMessenger, window: self)

    super.awakeFromNib()
  }
}

/// Collegamenti `uninotes://` (schema in CFBundleURLTypes dell'Info.plist),
/// ricevuti da AppDelegate.application(_:open:):
/// - `uninotes://widget/<schermata>`: tocco su un widget (con l'app aperta
///   la schermata si apre subito, altrimenti Flutter la chiede con
///   `takeRoute`);
/// - `uninotes://focus/ok|errore|annullato`: Comandi torna nell'app dopo il
///   comando «UniNotes Focus» (x-callback-url) e Flutter riceve l'esito con
///   `shortcutResult` (lib/features/study/focus/focus_system.dart);
/// - `uninotes://auth`: ritorno dall'accesso a OneDrive o Google Drive nel
///   browser (lib/core/services/app_return.dart).
final class AppLinks {
  static let shared = AppLinks()

  var widgetChannel: FlutterMethodChannel?
  var focusChannel: FlutterMethodChannel?
  var pendingRoute: String?

  /// true se il collegamento è dell'app.
  func handle(_ url: URL) -> Bool {
    guard url.scheme == "uninotes" else { return false }
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    switch url.host ?? "" {
    case "widget":
      if path.isEmpty { return true }
      if let channel = widgetChannel {
        channel.invokeMethod("route", arguments: path)
      } else {
        pendingRoute = path
      }
      return true
    case "focus":
      focusChannel?.invokeMethod("shortcutResult", arguments: path)
      return true
    case "auth":
      // ritorno dall'accesso nel browser (OneDrive, Google Drive): basta
      // riportare l'app in primo piano, l'esito lo mostra Flutter
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first?.makeKeyAndOrderFront(nil)
      return true
    default:
      return false
    }
  }
}

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

  /// Calendari per la scelta in Impostazioni → Calendario: `primary` =
  /// predefinito per i nuovi eventi, dove l'app scrive se lo studente non ne
  /// sceglie un altro; `legacy` = «UniNotes» delle versioni precedenti (si
  /// svuota e si toglie).
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

/// Controllo ortografico di macOS (NSSpellChecker) per i campi di testo
/// dell'app: trascrizione dal vivo, note e appunti
/// (lib/features/notes/spell_check.dart). Canale
/// `io.github.simomagnus.universitynotes/spellcheck`:
/// - `languages` → {it: Bool, en: Bool} lingue con il dizionario nel Mac;
/// - `check` {texts: [String], languages: ["it", "en"]} → per ogni testo
///   [[inizio, fine, [suggerimenti]]] (indici UTF-16, come le stringhe di
///   Dart e NSString). Una parola è errata solo se nessuna delle lingue
///   installate la riconosce; i suggerimenti arrivano dalla prima lingua.
final class UniNotesSpellCheck: NSObject {
  static let channelName = "io.github.simomagnus.universitynotes/spellcheck"
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: UniNotesSpellCheck.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handle(call, result: result)
    }
  }

  /// Codice della lingua fra quelle del Mac («it», «it_IT», «en», «en_GB»…).
  private func language(_ code: String) -> String? {
    let all = NSSpellChecker.shared.availableLanguages
    if all.contains(code) { return code }
    return all.first(where: { $0.hasPrefix(code + "_") || $0.hasPrefix(code + "-") })
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "languages":
      result(["it": language("it") != nil, "en": language("en") != nil])
    case "check":
      let langs = (args["languages"] as? [String] ?? []).compactMap { language($0) }
      let texts = args["texts"] as? [String] ?? []
      result(texts.map { check($0, langs) })
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func check(_ text: String, _ langs: [String]) -> [[Any]] {
    guard let first = langs.first, !text.isEmpty else { return [] }
    let checker = NSSpellChecker.shared
    let ns = text as NSString
    var out: [[Any]] = []
    var start = 0
    while start < ns.length {
      let r = checker.checkSpelling(
        of: text, startingAt: start, language: first, wrap: false,
        inSpellDocumentWithTag: 0, wordCount: nil)
      if r.location == NSNotFound || r.length == 0 || r.location < start { break }
      start = r.location + r.length
      let word = ns.substring(with: r)
      let known = langs.dropFirst().contains { lang in
        checker.checkSpelling(
          of: word, startingAt: 0, language: lang, wrap: false,
          inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
      }
      if known { continue }
      var guesses: [String] = []
      for lang in langs where guesses.isEmpty {
        guesses = checker.guesses(
          forWordRange: r, in: text, language: lang, inSpellDocumentWithTag: 0) ?? []
      }
      out.append([r.location, r.location + r.length, Array(guesses.prefix(5))])
    }
    return out
  }
}

/// «Apri con…» (canale "io.github.simomagnus.universitynotes/apri_con", vedi
/// lib/core/services/external_launcher.dart): un pannello sulla cartella
/// Applicazioni per scegliere l'app, poi il file si apre con quella
/// (NSWorkspace). Risponde "ok", "annullato" o "errore".
final class UniNotesOpenWith: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(
      name: "io.github.simomagnus.universitynotes/apri_con",
      binaryMessenger: messenger
    )
    self.window = window
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

  private func open(_ path: String, result: @escaping FlutterResult) {
    let file = URL(fileURLWithPath: path)
    let panel = NSOpenPanel()
    panel.title = "Apri con"
    panel.message = "Scegli l'app con cui aprire «\(file.lastPathComponent)»"
    panel.prompt = "Apri"
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.application]
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let app = panel.url else {
        result("annullato")
        return
      }
      NSWorkspace.shared.open(
        [file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()
      ) { _, error in
        DispatchQueue.main.async { result(error == nil ? "ok" : "errore") }
      }
    }
    if let window = window {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      finish(panel.runModal())
    }
  }
}
