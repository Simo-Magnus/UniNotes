// Widget della schermata Home di UniNotes (WidgetKit, iOS 15.6+ e macOS 12+).
//
// NON è agganciato alla build: va aggiunto in Xcode come target «Widget
// Extension» seguendo docs/widget.md (App Group
// group.io.github.simomagnus.universitynotes su app ed estensione).
// Su iPhone l'estensione è in app/ios/WidgetUniNotes/ (stessi widget più la
// Live Activity) e la aggiunge la build automatica.
//
// Dati: JSON scritto dall'app nella chiave «uninotes_widget_data» delle
// UserDefaults dell'App Group (AppDelegate.swift / MainFlutterWindow.swift,
// canale io.github.simomagnus.universitynotes/widgets), formato in
// lib/core/reminders/home_widgets.dart (widgetPayload, fino a 6 prove più
// «total»).
//
// Grafica come i widget Android (docs/SPEC_DESIGN_3.md): vetro scuro o
// chiaro secondo il tema del sistema, titolo piccolo in maiuscolo, righe
// come card interne, giorni mancanti come nell'app (rossi entro 7 giorni,
// azzurri dopo), pulsante arancione per registrare.
//
// Prove per famiglia: piccolo 1 (grande), medio 3 (righe compatte), grande
// 5 (con la data). Le altre come «+N».
//
// Tocchi: URL uninotes://widget/<schermata> (prova:<id>, sezione:Esami,
// registra), gestiti dall'app come descritto in docs/widget.md. Il widget
// «Registra lezione» apre il registratore: l'avvio diretto della
// registrazione da un widget su iOS richiede AudioRecordingIntent (iOS 18)
// e la Live Activity, vedi docs/widget.md.

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

  /// «Esame · martedì 12 gennaio alle 9:30».
  var whenText: String {
    let day = date.map { d in time.map { "\(d) alle \($0)" } ?? d }
    return [kind, day].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

struct WidgetData: Decodable {
  let exams: [WidgetExam]
  let total: Int?
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

/// Non si chiama «widgetURL»: dentro una View il nome indicherebbe il
/// modificatore View.widgetURL(_:) e non compilerebbe.
func uninotesURL(_ route: String) -> URL {
  var c = URLComponents()
  c.scheme = "uninotes"
  c.host = "widget"
  c.path = "/" + route
  return c.url ?? URL(string: "uninotes://widget/sezione:Esami")!
}

/// Colore da «#RRGGBB» e opacità.
func hex(_ v: UInt32, _ alpha: Double = 1) -> Color {
  Color(
    red: Double((v >> 16) & 0xFF) / 255,
    green: Double((v >> 8) & 0xFF) / 255,
    blue: Double(v & 0xFF) / 255
  ).opacity(alpha)
}

// MARK: - Colori (docs/SPEC_DESIGN_3.md, gli stessi dei widget Android)

struct Palette {
  let top: Color
  let mid: Color
  let bottom: Color
  let border: Color
  let inner: Color
  let innerBorder: Color
  let text: Color
  let secondary: Color
  let muted: Color
  let accent: Color
  let urgent: Color

  static func of(_ scheme: ColorScheme) -> Palette {
    scheme == .dark
      ? Palette(
        top: hex(0x1D2634, 0.92),
        mid: hex(0x0F1928, 0.92),
        bottom: hex(0x050F1D, 0.92),
        border: hex(0xA0CDFF, 0.11),
        inner: Color.white.opacity(0.05),
        innerBorder: Color.white.opacity(0.10),
        text: hex(0xF3F7FB),
        secondary: hex(0xEBF5FF, 0.75),
        muted: hex(0x8FA9C4),
        accent: hex(0x38BDF8),
        urgent: hex(0xF87171))
      : Palette(
        top: hex(0xFFFFFF),
        mid: hex(0xFDFEFF),
        bottom: hex(0xFAFCFF),
        border: hex(0xDAE3ED),
        inner: hex(0x0369A1, 0.05),
        innerBorder: hex(0x0369A1, 0.14),
        text: hex(0x0F172A),
        secondary: hex(0x334155),
        muted: hex(0x52627A),
        accent: hex(0x0369A1),
        urgent: hex(0xB91C1C))
  }

  var glass: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: top, location: 0),
        .init(color: mid, location: 0.34),
        .init(color: bottom, location: 1),
      ],
      startPoint: .top, endPoint: .bottom)
  }
}

/// Arancione del pulsante primario (§7.3) e testo sopra.
let orangeGradient = LinearGradient(
  stops: [
    .init(color: hex(0xFFB064), location: 0),
    .init(color: hex(0xFF8A1F), location: 0.52),
    .init(color: hex(0xE86F08), location: 1),
  ],
  startPoint: .top, endPoint: .bottom)
let onOrange = hex(0x1A0B00)

extension View {
  /// Sfondo di vetro del widget (iOS 17 / macOS 14 vogliono
  /// containerBackground).
  @ViewBuilder
  func widgetGlass(_ p: Palette) -> some View {
    if #available(iOS 17.0, macOS 14.0, *) {
      self.containerBackground(for: .widget) { p.glass }
    } else {
      self.padding().background(p.glass)
    }
  }
}

// MARK: - Pezzi comuni

/// Titolo piccolo della card (11 pt, peso 600, testo secondario).
struct CardTitle: View {
  let text: String
  let p: Palette
  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 11, weight: .semibold))
      .kerning(0.6)
      .foregroundColor(p.secondary)
      .lineLimit(1)
  }
}

/// Giorni mancanti come nell'app: rosso entro 7 giorni, azzurro dopo.
struct DaysChip: View {
  let days: Int
  let p: Palette
  var body: some View {
    let tint = days <= 7 ? p.urgent : p.accent
    HStack(spacing: 4) {
      Image(systemName: "clock")
        .font(.system(size: 10, weight: .semibold))
      Text(daysLabel(days))
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundColor(tint)
    .padding(.horizontal, 7)
    .padding(.vertical, 2)
    .background(
      RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.12))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.5), lineWidth: 1)
    )
    .fixedSize()
  }
}

/// Una prova in una card interna; [rich] = con la data sotto il titolo.
struct ExamRow: View {
  let exam: WidgetExam
  let days: Int
  let rich: Bool
  let p: Palette
  var body: some View {
    Link(destination: uninotesURL(exam.route ?? "prova:\(exam.id)")) {
      HStack(alignment: .center, spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text(exam.title)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(p.text)
            .lineLimit(1)
          if rich && !exam.whenText.isEmpty {
            Text(exam.whenText)
              .font(.system(size: 12))
              .foregroundColor(p.muted)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 4)
        DaysChip(days: days, p: p)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, rich ? 7 : 5)
      .background(RoundedRectangle(cornerRadius: 16).fill(p.inner))
      .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.innerBorder, lineWidth: 1))
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
    let all = (entry.data?.exams ?? [])
      .compactMap { e -> (WidgetExam, Int)? in
        let d = daysUntil(e.isoDate, from: entry.date) ?? e.days ?? 0
        return d < 0 ? nil : (e, d)
      }
    let past = (entry.data?.exams.count ?? 0) - all.count
    let total = max(all.count, (entry.data?.total ?? all.count) - past)
    let listRoute = entry.data?.route ?? "sezione:Esami"
    // piccolo: il tocco apre la prova mostrata; altrimenti la pagina Esami
    // (le righe hanno i loro Link)
    let route = family == .systemSmall
      ? (all.first.map { $0.0.route ?? "prova:\($0.0.id)" } ?? listRoute)
      : listRoute
    Group {
      if family == .systemSmall {
        single(all.first, p: p)
      } else {
        list(all, total: total, p: p)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .widgetURL(uninotesURL(route))
    .widgetGlass(p)
  }

  /// Piccolo: la prossima prova, grande.
  @ViewBuilder
  func single(_ item: (WidgetExam, Int)?, p: Palette) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      CardTitle(text: "Prossima prova", p: p)
      if let e = item?.0, let days = item?.1 {
        DaysChip(days: days, p: p)
          .padding(.top, 2)
        Text(e.title)
          .font(.system(size: e.title.count > 28 ? 15 : 17, weight: .semibold))
          .foregroundColor(p.text)
          .lineLimit(2)
        if !e.whenText.isEmpty {
          Text(e.whenText)
            .font(.system(size: 12))
            .foregroundColor(p.muted)
            .lineLimit(2)
        }
      } else {
        Text(entry.data?.emptyText ?? "Nessuna prova in programma")
          .font(.system(size: 13))
          .foregroundColor(p.muted)
      }
      Spacer(minLength: 0)
    }
  }

  /// Medio: 3 righe compatte; grande: 5 con la data.
  @ViewBuilder
  func list(_ all: [(WidgetExam, Int)], total: Int, p: Palette) -> some View {
    let large = family == .systemLarge
    // grande: 5 righe con la data entrano anche negli iPhone più piccoli
    // (widget grande da 292×311 pt, margini compresi)
    let rows = Array(all.prefix(large ? 5 : 3))
    let more = max(0, total - rows.count)
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        CardTitle(text: "Prossime prove", p: p)
        Spacer(minLength: 4)
        if more > 0 {
          Text("+\(more)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(p.muted)
        }
      }
      if rows.isEmpty {
        Text(entry.data?.emptyText ?? "Nessuna prova in programma")
          .font(.system(size: 13))
          .foregroundColor(p.muted)
          .padding(.top, 4)
      }
      ForEach(rows, id: \.0.id) { item in
        ExamRow(exam: item.0, days: item.1, rich: large, p: p)
      }
      Spacer(minLength: 0)
    }
  }
}

struct UpcomingExamsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "UniNotesProssimeProve", provider: ExamsProvider()) { entry in
      ExamsView(entry: entry)
    }
    .configurationDisplayName("Prossime prove")
    .description("Le prossime prove con i giorni che mancano: una nel piccolo, tre nel medio, cinque nel grande. Tocca una prova per aprirla.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
    VStack(spacing: 8) {
      ZStack {
        Circle().fill(orangeGradient)
        Image(systemName: "mic.fill")
          .font(.system(size: 24, weight: .semibold))
          .foregroundColor(onOrange)
      }
      .frame(width: 56, height: 56)
      Text("Registra lezione")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(p.text)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .widgetURL(uninotesURL("registra"))
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
