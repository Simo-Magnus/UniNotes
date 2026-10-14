import Cocoa
import FlutterMacOS
import WidgetKit

class MainFlutterWindow: NSWindow {
  /// App Group condiviso con l'estensione dei widget (docs/widget.md).
  static let appGroup = "group.io.github.simomagnus.universitynotes"
  /// Dati JSON dei widget scritti dall'app (lib/core/reminders/home_widgets.dart).
  static let widgetDataKey = "uninotes_widget_data"

  private var widgetChannel: FlutterMethodChannel?
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
    liveSpeech = LiveSpeech(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
