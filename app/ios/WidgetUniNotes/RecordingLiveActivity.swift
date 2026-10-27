// Estensione «WidgetUniNotes» (solo lì, non in Runner).
//
// Live Activity della registrazione delle lezioni (iOS 16.2+): schermata di
// blocco e Dynamic Island con nome del corso, tempo (cronometro nativo,
// nessun aggiornamento ogni secondo dall'app) e, da iOS 17, i pulsanti
// «Pausa» / «Riprendi» e «Salva». Il tocco apre il registratore
// (uninotes://widget/registra, vedi docs/widget.md). Entra nel pacchetto dei
// widget (UniNotesWidgets.swift, @main) con if #available(iOS 16.2, *):
// sotto iOS 16.2 l'estensione ha solo i widget.
//
// Colori come l'app: vetro scuro, testo chiaro, accento azzurro, pallino
// rosso della registrazione, arancione per l'azione principale.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Nome diverso da «Palette» dei widget (stesso modulo).
private enum LivePalette {
  static let background = Color(red: 0.027, green: 0.051, blue: 0.098)
  static let text = Color(red: 0.93, green: 0.96, blue: 1.0)
  static let muted = Color(red: 0.62, green: 0.70, blue: 0.80)
  static let cyan = Color(red: 0.22, green: 0.74, blue: 0.97)
  static let orange = Color(red: 0.98, green: 0.55, blue: 0.20)
  static let red = Color(red: 0.94, green: 0.27, blue: 0.27)
}

private let recorderURL = URL(string: "uninotes://widget/registra")!

@available(iOS 16.2, *)
private struct RecordingClock: View {
  let state: RecordingActivityAttributes.ContentState

  var body: some View {
    if state.paused {
      Text(Self.format(state.elapsedSeconds))
    } else {
      Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
    }
  }

  static func format(_ s: Int) -> String {
    String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
  }
}

@available(iOS 16.2, *)
private struct RecordingControls: View {
  let paused: Bool

  var body: some View {
    if #available(iOS 17.0, *) {
      HStack(spacing: 10) {
        Button(intent: ToggleRecordingPauseIntent()) {
          Label(paused ? "Riprendi" : "Pausa",
                systemImage: paused ? "play.fill" : "pause.fill")
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .tint(LivePalette.cyan)
        Button(intent: SaveRecordingIntent()) {
          Label("Salva", systemImage: "checkmark")
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .tint(LivePalette.orange)
      }
      .font(.subheadline.weight(.semibold))
    } else {
      // iOS 16: niente pulsanti interattivi, il tocco apre il registratore
      Link(destination: recorderURL) {
        Text("Apri il registratore")
          .font(.subheadline.weight(.semibold))
          .foregroundColor(LivePalette.cyan)
      }
    }
  }
}

@available(iOS 16.2, *)
private struct LockScreenView: View {
  let context: ActivityViewContext<RecordingActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Circle()
          .fill(context.state.paused ? LivePalette.muted : LivePalette.red)
          .frame(width: 12, height: 12)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(context.attributes.course)
            .font(.headline)
            .foregroundColor(LivePalette.text)
            .lineLimit(1)
          Text(context.state.paused ? "Registrazione in pausa" : "Registrazione in corso")
            .font(.caption)
            .foregroundColor(LivePalette.muted)
        }
        Spacer()
        RecordingClock(state: context.state)
          .font(.title2.monospacedDigit().weight(.semibold))
          .foregroundColor(LivePalette.text)
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 110, alignment: .trailing)
      }
      RecordingControls(paused: context.state.paused)
    }
    .padding(16)
    .accessibilityElement(children: .contain)
  }
}

@available(iOS 16.2, *)
struct RecordingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
      LockScreenView(context: context)
        .activityBackgroundTint(LivePalette.background)
        .activitySystemActionForegroundColor(LivePalette.text)
        .widgetURL(recorderURL)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label {
            Text(context.attributes.course).lineLimit(1)
          } icon: {
            Image(systemName: "mic.fill")
              .foregroundColor(context.state.paused ? LivePalette.muted : LivePalette.red)
          }
          .font(.subheadline.weight(.semibold))
        }
        DynamicIslandExpandedRegion(.trailing) {
          RecordingClock(state: context.state)
            .font(.title3.monospacedDigit())
            .frame(maxWidth: 96, alignment: .trailing)
        }
        DynamicIslandExpandedRegion(.bottom) {
          RecordingControls(paused: context.state.paused)
        }
      } compactLeading: {
        Image(systemName: context.state.paused ? "pause.fill" : "mic.fill")
          .foregroundColor(context.state.paused ? LivePalette.orange : LivePalette.red)
      } compactTrailing: {
        RecordingClock(state: context.state)
          .monospacedDigit()
          .frame(maxWidth: 56)
      } minimal: {
        Image(systemName: "mic.fill").foregroundColor(LivePalette.red)
      }
      .widgetURL(recorderURL)
      .keylineTint(LivePalette.cyan)
    }
  }
}
