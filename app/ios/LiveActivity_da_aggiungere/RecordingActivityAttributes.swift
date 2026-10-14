// Solo nel target dell'estensione «LiveActivityUniNotes» (NON in Runner:
// l'app ha già la stessa struttura in Runner/AppDelegate.swift).
//
// Dati della Live Activity della registrazione: deve restare identico alla
// copia in AppDelegate.swift (stesso nome, stessi campi).

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct RecordingActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// Registrazione in pausa (tempo fermo).
    var paused: Bool
    /// Inizio «virtuale» per il cronometro nativo: adesso meno il tempo già
    /// registrato (Text(timerInterval:)).
    var timerStart: Date
    /// Tempo registrato, mostrato fermo durante la pausa.
    var elapsedSeconds: Int
  }

  /// Nome del corso.
  var course: String
}
