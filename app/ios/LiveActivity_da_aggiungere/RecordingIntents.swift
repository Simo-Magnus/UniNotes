// In ENTRAMBI i target: Runner e LiveActivityUniNotes.
//
// Pulsanti della Live Activity (iOS 17+). Con il file anche nel target
// dell'app, il sistema esegue l'intento nel processo dell'app (anche in
// background): l'intento avvisa AppDelegate, che passa il comando a Flutter
// sul canale io.github.simomagnus.universitynotes/live_activity.

import AppIntents
import Foundation

/// Stesso nome di AppDelegate.recordingCommandNotification.
private let recordingCommand = Notification.Name(
  "io.github.simomagnus.universitynotes.recordingCommand")

private func sendRecordingCommand(_ command: String) async {
  await MainActor.run {
    NotificationCenter.default.post(
      name: recordingCommand, object: nil, userInfo: ["command": command])
  }
}

/// «Pausa» / «Riprendi».
@available(iOS 17.0, *)
struct ToggleRecordingPauseIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Pausa o ripresa della registrazione"
  static var description = IntentDescription(
    "Mette in pausa o riprende la registrazione della lezione.")

  init() {}

  func perform() async throws -> some IntentResult {
    await sendRecordingCommand("toggle")
    return .result()
  }
}

/// «Salva»: ferma e salva la registrazione.
@available(iOS 17.0, *)
struct SaveRecordingIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Salva la registrazione"
  static var description = IntentDescription(
    "Ferma la registrazione e la salva negli appunti del corso.")

  init() {}

  func perform() async throws -> some IntentResult {
    await sendRecordingCommand("save")
    return .result()
  }
}
