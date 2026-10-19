import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Collegamenti `uninotes://` (widget, comando Focus: AppLinks in
  /// MainFlutterWindow.swift); gli altri vanno ai plugin come prima.
  override func application(_ application: NSApplication, open urls: [URL]) {
    let others = urls.filter { !AppLinks.shared.handle($0) }
    if !others.isEmpty { super.application(application, open: others) }
  }
}
