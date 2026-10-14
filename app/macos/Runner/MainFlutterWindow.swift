import Cocoa
import FlutterMacOS
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
        // i tocchi sui widget arrivano come URL (vedi docs/widget.md)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    widgetChannel = channel

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

    super.awakeFromNib()
  }
}
