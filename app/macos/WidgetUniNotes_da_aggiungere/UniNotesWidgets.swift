// Widget della schermata Home di UniNotes (WidgetKit, iOS 15.6+ e macOS 12+).
//
// NON è agganciato alla build: va aggiunto in Xcode come target «Widget
// Extension» seguendo docs/widget.md (App Group
// group.io.github.simomagnus.universitynotes su app ed estensione).
//
// Dati: JSON scritto dall'app nella chiave «uninotes_widget_data» delle
// UserDefaults dell'App Group (AppDelegate.swift / MainFlutterWindow.swift,
// canale io.github.simomagnus.universitynotes/widgets), formato in
// lib/core/reminders/home_widgets.dart (widgetPayload).
//
// Tocchi: URL uninotes://widget/<schermata> (prova:<id>, sezione:Esami,
// registra), gestiti dall'app come descritto in docs/widget.md.

import SwiftUI
import WidgetKit

// MARK: - Dati condivisi

private let appGroup = "group.io.github.simomagnus.universitynotes"
private let dataKey = "uninotes_widget_data"

struct WidgetExam: Decodable, Identifiable {
  let id: Int
  let title: String
  let kind: String?
  let date: String?
  let isoDate: String?
  let time: String?
  let days: Int?
  let route: String?
}

struct WidgetData: Decodable {
  let exams: [WidgetExam]
  let emptyText: String?
  let route: String?

  static func load() -> WidgetData? {
    guard let raw = UserDefaults(suiteName: appGroup)?.string(forKey: dataKey),
      let data = raw.data(using: .utf8)
    else { return nil }
    return try? JSONDecoder().decode(WidgetData.self, from: data)
  }
}

/// Giorni da oggi alla data «aaaa-mm-gg» (ricalcolati a ogni timeline).
func daysUntil(_ iso: String?, from now: Date) -> Int? {
  guard let iso = iso else { return nil }
  let f = DateFormatter()
  f.calendar = Calendar(identifier: .gregorian)
  f.locale = Locale(identifier: "en_US_POSIX")
  f.dateFormat = "yyyy-MM-dd"
  guard let day = f.date(from: iso) else { return nil }
  let cal = Calendar.current
  return cal.dateComponents(
    [.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: day)
  ).day
}

func daysLabel(_ n: Int) -> String {
  switch n {
  case ..<1: return "Oggi"
  case 1: return "Domani"
  default: return "Tra \(n) giorni"
  }
}

func widgetURL(_ route: String) -> URL {
  var c = URLComponents()
  c.scheme = "uninotes"
  c.host = "widget"
  c.path = "/" + route
  return c.url ?? URL(string: "uninotes://widget/sezione:Esami")!
}

// MARK: - Colori (vetro scuro o chiaro, azzurro dell'app)

struct Palette {
  let background: Color
  let border: Color
  let text: Color
  let muted: Color
  let accent: Color
  let badge: Color

  static func of(_ scheme: ColorScheme) -> Palette {
    scheme == .dark
      ? Palette(
        background: Color(red: 0.03, green: 0.07, blue: 0.13),
        border: Color(red: 0.63, green: 0.80, blue: 1.0).opacity(0.2),
        text: Color(red: 0.95, green: 0.97, blue: 0.98),
        muted: Color(red: 0.56, green: 0.66, blue: 0.77),
        accent: Color(red: 0.22, green: 0.74, blue: 0.97),
        badge: Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.15))
      : Palette(
        background: Color(red: 0.96, green: 0.98, blue: 1.0),
        border: Color(red: 0.06, green: 0.16, blue: 0.30).opacity(0.1),
        text: Color(red: 0.04, green: 0.09, blue: 0.15),
        muted: Color(red: 0.36, green: 0.44, blue: 0.54),
        accent: Color(red: 0.01, green: 0.41, blue: 0.63),
        badge: Color(red: 0.01, green: 0.41, blue: 0.63).opacity(0.12))
  }
}

extension View {
  /// Sfondo del widget (iOS 17 / macOS 14 vogliono containerBackground).
  @ViewBuilder
  func widgetGlass(_ p: Palette) -> some View {
    if #available(iOS 17.0, macOS 14.0, *) {
      self.containerBackground(p.background, for: .widget)
    } else {
      self.padding().background(p.background)
    }
  }
}

// MARK: - «Prossime prove»

struct ExamsEntry: TimelineEntry {
  let date: Date
  let data: WidgetData?
}

struct ExamsProvider: TimelineProvider {
  func placeholder(in context: Context) -> ExamsEntry {
    ExamsEntry(date: Date(), data: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (ExamsEntry) -> Void) {
    completion(ExamsEntry(date: Date(), data: WidgetData.load()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ExamsEntry>) -> Void) {
    let now = Date()
    let entry = ExamsEntry(date: now, data: WidgetData.load())
    // i giorni mancanti cambiano a mezzanotte
    let midnight = Calendar.current.date(
      byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)
    ) ?? now.addingTimeInterval(6 * 3600)
    completion(Timeline(entries: [entry], policy: .after(midnight)))
  }
}

struct ExamsView: View {
  let entry: ExamsEntry
  @Environment(\.colorScheme) var scheme
  @Environment(\.widgetFamily) var family

  var body: some View {
    let p = Palette.of(scheme)
    let max = family == .systemSmall ? 2 : 3
    let exams = (entry.data?.exams ?? [])
      .compactMap { e -> (WidgetExam, Int)? in
        let d = daysUntil(e.isoDate, from: entry.date) ?? e.days ?? 0
        return d < 0 ? nil : (e, d)
      }
      .prefix(max)
    VStack(alignment: .leading, spacing: 6) {
      Text("PROSSIME PROVE")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(p.accent)
      if exams.isEmpty {
        Text(entry.data?.emptyText ?? "Nessuna prova in programma")
          .font(.system(size: 13))
          .foregroundColor(p.muted)
      }
      ForEach(Array(exams), id: \.0.id) { item in
        let (e, days) = item
        Link(destination: widgetURL(e.route ?? "prova:\(e.id)")) {
          HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
              Text(e.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(p.text)
                .lineLimit(1)
              Text(
                [e.kind, e.date.map { d in e.time.map { "\(d) alle \($0)" } ?? d }]
                  .compactMap { $0 }.joined(separator: " · ")
              )
              .font(.system(size: 12))
              .foregroundColor(p.muted)
              .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(daysLabel(days))
              .font(.system(size: 12, weight: .medium))
              .foregroundColor(p.accent)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(RoundedRectangle(cornerRadius: 10).fill(p.badge))
          }
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .widgetURL(widgetURL(entry.data?.route ?? "sezione:Esami"))
    .widgetGlass(p)
  }
}

struct UpcomingExamsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "UniNotesProssimeProve", provider: ExamsProvider()) { entry in
      ExamsView(entry: entry)
    }
    .configurationDisplayName("Prossime prove")
    .description("Le prossime tre prove con i giorni che mancano. Tocca una prova per aprirla.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

// MARK: - «Registra lezione»

struct RecordEntry: TimelineEntry {
  let date: Date
}

struct RecordProvider: TimelineProvider {
  func placeholder(in context: Context) -> RecordEntry { RecordEntry(date: Date()) }

  func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) {
    completion(RecordEntry(date: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
    completion(Timeline(entries: [RecordEntry(date: Date())], policy: .never))
  }
}

struct RecordView: View {
  @Environment(\.colorScheme) var scheme

  var body: some View {
    let p = Palette.of(scheme)
    VStack(spacing: 6) {
      ZStack {
        Circle()
          .fill(
            LinearGradient(
              colors: [
                Color(red: 1.0, green: 0.69, blue: 0.39),
                Color(red: 0.91, green: 0.44, blue: 0.03),
              ],
              startPoint: .top, endPoint: .bottom))
        Image(systemName: "mic.fill")
          .font(.system(size: 22, weight: .semibold))
          .foregroundColor(Color(red: 0.10, green: 0.04, blue: 0.0))
      }
      .frame(width: 52, height: 52)
      Text("Registra")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(p.text)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .widgetURL(widgetURL("registra"))
    .widgetGlass(p)
  }
}

struct RecordWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "UniNotesRegistra", provider: RecordProvider()) { _ in
      RecordView()
    }
    .configurationDisplayName("Registra lezione")
    .description("Apre UniNotes direttamente nella registrazione della lezione.")
    .supportedFamilies([.systemSmall])
  }
}

// MARK: - Pacchetto dei widget

@main
struct UniNotesWidgets: WidgetBundle {
  var body: some Widget {
    UpcomingExamsWidget()
    RecordWidget()
  }
}
