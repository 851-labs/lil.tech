import Charts
public import HealthCatalog
import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// Sleep, as in Health: a night's stages (D) or a week of nights (W), with time asleep and in
/// bed, the range and earlier nights in the toolbar. Follows the local database as sync changes
/// it.
public struct SleepDetailView: View {
  let type: HealthDataType
  @State private var range = SleepRange.day
  @State private var offset = 0
  /// Today, moved on at midnight, so the nights shown follow.
  @State private var today = Date.now
  @Fetch private var nights: [SleepNight] = []

  public init(type: HealthDataType) {
    self.type = type
  }

  public var body: some View {
    SleepDetailContent(
      type: type, range: $range, offset: $offset,
      state: $nights.loadError.map { .failed($0.localizedDescription) }
        ?? ($nights.isLoading ? .loading : .loaded(nights)), now: today
    )
    .task(id: [range.rawValue, String(offset), today.formatted(.iso8601.year().month().day())]) {
      _ = try? await $nights.load(
        SleepRequest(range: range, offset: offset, day: today), scheduler: MainQueueScheduler())
    }
    .onReceive(calendarDayChanges()) {
      today = .now
    }
  }
}

/// D: one night. W: seven.
enum SleepRange: String, CaseIterable, Hashable, Sendable, PeriodRange {
  case day = "D"
  case week = "W"

  /// D is a night, which runs over two days.
  var periodName: String { self == .day ? "Night" : "Week" }

  var nights: Int { self == .day ? 1 : 7 }

  /// The last night shown, `offset` periods back from today's.
  func lastDay(offset: Int, now: Date, calendar: Calendar) -> Date {
    let today = calendar.startOfDay(for: now)
    return calendar.date(byAdding: .day, value: offset * nights, to: today) ?? today
  }
}

struct SleepRequest: FetchKeyRequest {
  let range: SleepRange
  let offset: Int
  /// The day it's for, so a new day is a new request.
  let day: Date

  init(range: SleepRange, offset: Int, day: Date) {
    self.range = range
    self.offset = offset
    self.day = Calendar.current.startOfDay(for: day)
  }

  func fetch(_ db: Database) throws -> [SleepNight] {
    try HealthDatabase.sleepNights(
      endingOn: range.lastDay(offset: offset, now: day, calendar: .current), count: range.nights,
      calendar: .current, db)
  }
}

/// What the sleep detail shows, however it got it.
struct SleepDetailContent: View {
  enum State {
    case loading
    case loaded([SleepNight])
    case failed(String)
  }

  let type: HealthDataType
  @Binding var range: SleepRange
  @Binding var offset: Int
  let state: State
  var now = Date.now
  var calendar = Calendar.current

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 12) {
          header
          chartArea
            .frame(height: 240)
        }
        .padding(16)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))

        if range == .day, case .loaded(let nights) = state, let night = nights.last {
          stages(night)
        }
        VStack(spacing: 0) {
          NavigationLink {
            AllDataView(type: type)
          } label: {
            PageLinkRow("Show All Data")
          }
          .buttonStyle(.plain)
          Divider().padding(.leading, 14)
          NavigationLink {
            DataSourcesView(type: type)
          } label: {
            PageLinkRow("Data Sources")
          }
          .buttonStyle(.plain)
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .background(Color.pageBackground)
    .navigationTitle(type.name)
    // The range and ‹ Today › in the toolbar, as on other metrics (851-2866).
    .periodControls(PagePeriod(range: $range, offset: $offset))
  }

  // MARK: Header

  private var header: some View {
    let nights: [SleepNight] = if case .loaded(let nights) = state { nights } else { [] }
    let count = Double(max(nights.count, 1))
    let asleep = nights.reduce(0) { $0 + $1.asleep } / count
    let inBed = nights.reduce(0) { $0 + $1.inBed } / count
    return HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        Text(range == .day ? "TIME ASLEEP" : "AVERAGE TIME ASLEEP")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(nights.isEmpty ? (isLoaded ? "No Data" : "–") : SleepFormat.duration(asleep))
          .font(.system(.largeTitle, design: .rounded).bold())
          .foregroundStyle(nights.isEmpty ? .secondary : .primary)
        if !nights.isEmpty {
          Text("In bed \(SleepFormat.duration(inBed))")
            .foregroundStyle(.secondary)
        }
        Text(span)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private var isLoaded: Bool {
    if case .loaded = state { true } else { false }
  }

  /// The night or nights shown: "Oct 15, 2026", or "Oct 9 – 15, 2026".
  private var span: String {
    let last = range.lastDay(offset: offset, now: now, calendar: calendar)
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    guard range == .week,
      let first = calendar.date(byAdding: .day, value: 1 - range.nights, to: last)
    else { return last.formatted(style.month(.abbreviated).day().year()) }
    return (first..<last).formatted(
      Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
  }

  // MARK: Chart

  @ViewBuilder private var chartArea: some View {
    switch state {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load Sleep", systemImage: "exclamationmark.triangle",
        description: Text(reason))
    case .loaded(let nights) where nights.isEmpty:
      ContentUnavailableView(
        "No Sleep Data", systemImage: "bed.double",
        description: Text("Sleep tracked by your Apple Watch or iPhone will appear here."))
    case .loaded(let nights):
      if range == .day, let night = nights.last {
        stagesChart(night)
      } else {
        weekChart(nights)
      }
    }
  }

  /// The night's stages over time, a row each, as in Health.
  private func stagesChart(_ night: SleepNight) -> some View {
    let rows = SleepFormat.rows(for: night)
    return Chart(Array(night.segments.enumerated()), id: \.offset) { _, segment in
      BarMark(
        xStart: .value("Start", segment.start), xEnd: .value("End", segment.end),
        y: .value("Stage", SleepFormat.name(segment.stage)), height: .ratio(0.7)
      )
      .foregroundStyle(SleepFormat.color(segment.stage))
      .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    .chartYScale(domain: rows.map(SleepFormat.name))
    // The stages' names, which Charts drew white on the light card (851-2869), as did the
    // secondary styles (`.secondary`, `Color.secondary`) set on them. The primary color, faded,
    // follows the appearance.
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let name = value.as(String.self) {
            Text(name)
              .foregroundStyle(Color.primary.opacity(0.6))
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
        AxisGridLine()
        AxisValueLabel(format: .dateTime.hour())
      }
    }
  }

  /// Each night's time asleep, by stage, with a slot for every night of the week.
  private func weekChart(_ nights: [SleepNight]) -> some View {
    let last = range.lastDay(offset: offset, now: now, calendar: calendar)
    let first = calendar.date(byAdding: .day, value: 1 - range.nights, to: last) ?? last
    let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
    let bars = nights.flatMap { night in
      SleepStage.allCases.filter(\.isAsleep).compactMap { stage -> (Date, SleepStage, Double)? in
        guard let duration = night.durations[stage], duration > 0 else { return nil }
        return (night.day, stage, duration / 3600)
      }
    }
    return Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
      BarMark(x: .value("Night", bar.0, unit: .day), y: .value("Hours", bar.2))
        .foregroundStyle(SleepFormat.color(bar.1))
    }
    .chartXScale(domain: first...end)
    .chartYAxis {
      AxisMarks(position: .trailing) { value in
        AxisGridLine()
        AxisValueLabel { if let hours = value.as(Double.self) { Text("\(Int(hours)) hr") } }
      }
    }
  }

  // MARK: Stages

  /// Each stage's time and share of the night's sleep.
  private func stages(_ night: SleepNight) -> some View {
    let durations = night.durations
    let asleep = max(night.asleep, 1)
    let rows = SleepFormat.rows(for: night)
    return VStack(alignment: .leading, spacing: 8) {
      Text("Stages")
        .font(.title3.bold())
      VStack(spacing: 0) {
        ForEach(rows, id: \.self) { stage in
          let duration = durations[stage] ?? 0
          HStack {
            Circle()
              .fill(SleepFormat.color(stage))
              .frame(width: 10, height: 10)
            Text(SleepFormat.name(stage))
            Spacer()
            Text(SleepFormat.duration(duration))
              .foregroundStyle(.secondary)
            if stage.isAsleep {
              Text((duration / asleep).formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            } else {
              Spacer().frame(width: 44)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          if stage != rows.last { Divider().padding(.leading, 14) }
        }
      }
      .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
  }
}

/// How sleep reads and looks.
enum SleepFormat {
  /// The chart's rows, top to bottom: Health's order for stages, or Awake and Asleep for a
  /// source that didn't record stages.
  static func rows(for night: SleepNight) -> [SleepStage] {
    guard night.hasStages else { return [.awake, .asleep] }
    // Asleep (unspecified) joins the stages if a staged night has some too, so it all shows.
    let unspecified = night.segments.contains { $0.stage == .asleep }
    return [.awake, .rem, .core, .deep] + (unspecified ? [.asleep] : [])
  }

  static func name(_ stage: SleepStage) -> String {
    switch stage {
    case .inBed: "In Bed"
    case .asleep: "Asleep"
    case .awake: "Awake"
    case .core: "Core"
    case .deep: "Deep"
    case .rem: "REM"
    }
  }

  static func color(_ stage: SleepStage) -> Color {
    switch stage {
    case .inBed: .gray
    case .asleep: .teal
    case .awake: Color(red: 1, green: 0.45, blue: 0.35)
    case .rem: .cyan
    case .core: .blue
    case .deep: .indigo
    }
  }

  /// "7 hr 32 min", "45 min".
  static func duration(_ interval: TimeInterval) -> String {
    let minutes = Int((interval / 60).rounded())
    let (hours, rest) = (minutes / 60, minutes % 60)
    if hours == 0 { return "\(rest) min" }
    return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
  }
}
