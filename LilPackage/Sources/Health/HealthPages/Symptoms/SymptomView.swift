import Charts
import Dependencies
public import HealthCatalog
import HealthDatabase
import HealthUI
import LilUI
import SQLiteData
public import SwiftUI

/// A symptom, as in Health (851-2828): its entries over D, W, M, 6M or Y at their severity (each
/// entry over its hours for a day, each day's highest for a week or a month, the days with it per
/// week or month for longer), the days it was present, and the period's entries. Follows the local
/// database as sync changes it.
public struct SymptomView: View {
  let type: HealthDataType
  @State private var range = ChartRange.week
  @State private var offset = 0
  /// Moves at midnight, so the periods do. From the `date` dependency, as the calendar is.
  @State private var today: Date
  /// The last period loaded. While another loads, the page keeps showing it (851-3089).
  @Fetch private var chart: SymptomChart? = nil

  @Dependency(\.date) private var date
  @Dependency(\.calendar) private var calendar

  public init(type: HealthDataType) {
    self.type = type
    @Dependency(\.date.now) var now
    _today = State(initialValue: now)
  }

  public var body: some View {
    SymptomContent(type: type, range: $range, offset: $offset, state: state, now: today)
      // Today's start in the page's calendar, so a new day is a new load.
      .task(id: [
        type.id, range.rawValue, String(offset),
        "\(calendar.startOfDay(for: today).timeIntervalSince1970)",
      ]) {
        _ = try? await $chart.load(
          SymptomRequest(
            typeID: type.id, range: range, offset: offset, now: today, calendar: calendar),
          scheduler: MainQueueScheduler())
      }
      .onReceive(calendarDayChanges()) {
        today = date.now
      }
  }

  /// The chart loaded last, updating while it's another period's or a load is running.
  private var state: SymptomContent.State {
    if let error = $chart.loadError { return .failed(error.localizedDescription) }
    guard let chart else { return .loading }
    let interval = range.interval(offset: offset, now: today, calendar: calendar)
    return .loaded(
      chart, isUpdating: $chart.isLoading || chart.range != range || chart.interval != interval)
  }
}

struct SymptomRequest: FetchKeyRequest {
  let typeID: String
  let range: ChartRange
  let offset: Int
  /// The day it's for, so a new day is a new request.
  let now: Date
  let calendar: Calendar

  func fetch(_ db: Database) throws -> SymptomChart? {
    try HealthDatabase.symptomChart(
      of: typeID, range: range, offset: offset, now: now, calendar: calendar, db)
  }
}

/// What a symptom's page shows, however it got it.
struct SymptomContent: View {
  enum State {
    /// Nothing to show yet: placeholders take the loaded page's space (851-3089).
    case loading
    /// A period's chart. Updating while another period, or the same one again, loads: it stays
    /// on screen, with a spinner, rather than the page blanking.
    case loaded(SymptomChart, isUpdating: Bool = false)
    case failed(String)

    var isLoading: Bool {
      if case .loading = self { true } else { false }
    }
  }

  let type: HealthDataType
  /// The period chosen in the toolbar, which can be ahead of the one shown (`range`).
  @Binding private var selectedRange: ChartRange
  @Binding private var selectedOffset: Int
  let state: State
  /// Today, as the page loads it, for the period shown while it loads.
  let now: Date
  /// From dependencies, so snapshot catalogs fix it (`previewCalendar`).
  @Dependency(\.calendar) private var calendar
  @SwiftUI.State private var hovered: Date?

  /// How many of the period's entries the list shows.
  static let entryLimit = 100
  /// An entry shorter than this is a thin mark at its start, rather than a bar over its time.
  static let shortEntry: TimeInterval = 20 * 60

  private var color: Color { type.color }

  init(
    type: HealthDataType, range: Binding<ChartRange>, offset: Binding<Int>, state: State, now: Date
  ) {
    self.type = type
    _selectedRange = range
    _selectedOffset = offset
    self.state = state
    self.now = now
  }

  private var chart: SymptomChart? {
    if case .loaded(let chart, _) = state { chart } else { nil }
  }

  /// The range shown: the loaded chart's, which stays while another loads, or the one chosen
  /// before any has loaded. Everything drawn uses it, never the selection.
  private var range: ChartRange { chart?.range ?? selectedRange }

  private var isUpdating: Bool {
    if case .loaded(_, let isUpdating) = state { isUpdating } else { false }
  }

  var body: some View {
    // A grouped form on its own background, as Metric Detail is (851-2989, 851-3004): the summary
    // and the chart, the pages it opens, then the period's entries. The entries last, so the
    // links don't move as a period's entries load, or with how many it has (851-3089).
    Form {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          header
          chartArea
            .delayedProgress(isLoading: state.isLoading)
            .frame(height: 280)
        }
        .padding(.vertical, 6)
      }
      Section {
        NavigationLink("Show All Data") {
          AllDataView(type: type)
        }
        .layoutAnchor("Show All Data")
        NavigationLink("Data Sources") {
          DataSourcesView(type: type)
        }
      }
      if let chart, !chart.entries.isEmpty {
        entries(chart.entries)
      }
    }
    .formStyle(.grouped)
    .navigationTitle(type.name)
    .periodControls(PagePeriod(range: $selectedRange, offset: $selectedOffset))
  }

  // MARK: Header

  private var header: some View {
    let points = chart.map { hoveredPoints(in: $0) } ?? []
    // The big line, and whether it's data (else it's secondary).
    let value: (text: String, isData: Bool) =
      if let point = points.first, let chart {
        // A week's or month's days, else each level hovered by name: an entry's, a day's highest,
        // or every appetite change a day has.
        range == .sixMonths || range == .year
          ? (SymptomFormat.days(point.value), true)
          : (
            points.map { chart.scale.levels[safe: $0.value - 1] ?? "Present" }
              .joined(separator: ", "), true
          )
      } else if let chart {
        chart.days > 0
          ? (SymptomFormat.days(chart.days), true)
          // Entries saying it wasn't there are listed, not counted.
          : (chart.entries.isEmpty ? "No Data" : "Not Present", false)
      } else {
        ("–", false)
      }
    let detail =
      if let point = points.first {
        range == .day
          ? SymptomFormat.time(point.entries[0], calendar: calendar)
          : ChartFormat.bucket(point.start, range: range, calendar: calendar)
      } else {
        ChartFormat.span(
          chart?.interval
            ?? selectedRange.interval(offset: selectedOffset, now: now, calendar: calendar),
          range: range, calendar: calendar)
      }
    return VStack(alignment: .leading, spacing: 2) {
      Text(value.text)
        .font(.system(.largeTitle, design: .rounded).bold())
        .foregroundStyle(value.isData ? .primary : .secondary)
      Text(detail)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // While another period loads, over the one shown.
    .updatingIndicator(isUpdating)
  }

  // MARK: Chart

  @ViewBuilder private var chartArea: some View {
    switch state {
    case .loading:
      // Its space, under the spinner `delayedProgress` shows (851-3086).
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load \(type.name)", systemImage: "exclamationmark.triangle",
        description: Text(reason)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let chart, _):
      let hovered = hoveredPoints(in: chart)
      if isCategorical(chart) {
        decorated(
          Chart {
            ForEach(Array(chart.points.enumerated()), id: \.offset) { _, point in
              change(point, in: chart.scale, isHovered: hovered.contains(point))
            }
          }
          // Kinds of change as rows, the scale's first at the bottom.
          .chartYScale(domain: 0.5...(Double(chart.scale.levels.count) + 0.5))
          .chartYAxis {
            AxisMarks(position: .trailing, values: Array(1...chart.scale.levels.count)) { value in
              AxisGridLine()
              AxisValueLabel {
                if let row = value.as(Int.self), let name = chart.scale.levels[safe: row - 1] {
                  Text(name)
                }
              }
            }
          },
          chart)
      } else {
        decorated(
          Chart {
            ForEach(Array(chart.points.enumerated()), id: \.offset) { _, point in
              bar(point, isHovered: hovered.contains(point))
            }
          }
          .chartYScale(domain: yDomain(chart))
          .chartYAxis {
            if range == .sixMonths || range == .year {
              AxisMarks(position: .trailing)
            } else {
              // Levels by name: Present, Mild, Moderate, Severe.
              AxisMarks(position: .trailing, values: Array(1...chart.scale.levels.count)) {
                value in
                AxisGridLine()
                AxisValueLabel {
                  if let level = value.as(Int.self),
                    let name = chart.scale.levels[safe: level - 1]
                  {
                    Text(name)
                  }
                }
              }
            }
          },
          chart)
      }
    }
  }

  /// Whether the chart's levels are rows of kinds rather than heights: appetite's, for D, W, M.
  private func isCategorical(_ chart: SymptomChart) -> Bool {
    !chart.scale.isOrdered && range != .sixMonths && range != .year
  }

  /// What either chart has: its span and axis, hover, and VoiceOver's label when there's nothing
  /// to chart.
  private func decorated(_ content: some View, _ chart: SymptomChart) -> some View {
    content
      .chartXScale(domain: domain(chart))
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: range == .day ? 6 : 7)) { _ in
          AxisGridLine()
          AxisValueLabel(format: axisFormat)
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geometry in
          Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                guard let frame = proxy.plotFrame else { return }
                let x = location.x - geometry[frame].origin.x
                hovered = proxy.value(atX: x, as: Date.self)
              case .ended:
                hovered = nil
              }
            }
        }
      }
      // Nothing over an empty period's plot: the header says No Data, or Not Present for
      // entries saying it wasn't there, which are listed, not charted (851-3102).
      .emptyChartAccessibility(chart.points.isEmpty, label: emptyLabel(chart))
  }

  /// What VoiceOver reads for a period with nothing charted: "No data for Oct 2025", or "Not
  /// present, Oct 2025" when its entries say it wasn't there.
  private func emptyLabel(_ chart: SymptomChart) -> String {
    let span = ChartFormat.span(chart.interval, range: range, calendar: calendar)
    return chart.entries.isEmpty ? ChartFormat.noData(span) : "Not present, \(span)"
  }

  /// A bar: an entry over its time (a day), a day's highest level, or a week's or month's days.
  @ChartContentBuilder
  private func bar(_ point: SymptomPoint, isHovered: Bool) -> some ChartContent {
    let style = color.opacity(isHovered ? 1 : 0.8)
    if range == .day {
      if point.end.timeIntervalSince(point.start) >= Self.shortEntry {
        RectangleMark(
          xStart: .value("Start", point.start), xEnd: .value("End", point.end),
          yStart: .value("Level", 0), yEnd: .value("Level", point.value)
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .foregroundStyle(style)
      } else {
        BarMark(
          x: .value("Time", point.start), yStart: .value("Level", 0),
          yEnd: .value("Level", point.value), width: .fixed(6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .foregroundStyle(style)
      }
    } else {
      BarMark(
        x: .value("Date", point.start, unit: range.barUnit),
        y: .value(range == .sixMonths || range == .year ? "Days" : "Level", point.value)
      )
      .foregroundStyle(style)
    }
  }

  /// An appetite change in its row: over an entry's time (a day), or a day's cell.
  @ChartContentBuilder
  private func change(
    _ point: SymptomPoint, in scale: SymptomScale, isHovered: Bool
  ) -> some ChartContent {
    let style = color.opacity(isHovered ? 1 : 0.8)
    // A row per kind, numbered from 1 at the bottom, so the axis keeps room for its names.
    let row = Double(min(max(point.value, 1), scale.levels.count))
    if range == .day {
      if point.end.timeIntervalSince(point.start) >= Self.shortEntry {
        RectangleMark(
          xStart: .value("Start", point.start), xEnd: .value("End", point.end),
          yStart: .value("Change", row - 0.25), yEnd: .value("Change", row + 0.25)
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .foregroundStyle(style)
      } else {
        PointMark(x: .value("Time", point.start), y: .value("Change", row))
          .symbolSize(80)
          .foregroundStyle(style)
      }
    } else {
      BarMark(
        x: .value("Date", point.start, unit: range.barUnit),
        yStart: .value("Change", row - 0.25), yEnd: .value("Change", row + 0.25)
      )
      .clipShape(RoundedRectangle(cornerRadius: 3))
      .foregroundStyle(style)
    }
  }

  private var axisFormat: Date.FormatStyle {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    switch range {
    case .day: return style.hour()
    case .week, .month: return style.month(.abbreviated).day()
    case .sixMonths, .year: return style.month(.abbreviated)
    }
  }

  /// The chart's span, widened to whole bars: six months' first and last weeks run past them.
  private func domain(_ chart: SymptomChart) -> ClosedRange<Date> {
    guard range != .day else { return chart.interval.start...chart.interval.end }
    let start = calendar.dateInterval(of: range.barUnit, for: chart.interval.start)?.start
    let end = calendar.dateInterval(
      of: range.barUnit, for: chart.interval.end.addingTimeInterval(-1))?.end
    return (start ?? chart.interval.start)...(end ?? chart.interval.end)
  }

  /// Levels from none to the scale's highest, or days from none to the most in a bar (at least a
  /// week's, so one day isn't a full bar).
  private func yDomain(_ chart: SymptomChart) -> ClosedRange<Int> {
    guard range == .sixMonths || range == .year else { return 0...chart.scale.levels.count }
    return 0...max(chart.points.map(\.value).max() ?? 0, 7)
  }

  /// The marks under the pointer: the entry nearest it on a day, else its day's, week's or
  /// month's (each of a day's appetite changes).
  private func hoveredPoints(in chart: SymptomChart) -> [SymptomPoint] {
    guard let hovered else { return [] }
    if range == .day {
      func distance(_ point: SymptomPoint) -> TimeInterval {
        if hovered < point.start { return point.start.timeIntervalSince(hovered) }
        return max(0, hovered.timeIntervalSince(point.end))
      }
      return chart.points
        .filter { distance($0) < Self.shortEntry }
        .min { distance($0) < distance($1) }
        .map { [$0] } ?? []
    }
    guard let bar = calendar.dateInterval(of: range.barUnit, for: hovered) else { return [] }
    return chart.points.filter { $0.start == bar.start }
  }

  // MARK: Entries

  /// The period's entries, a row each, newest first.
  private func entries(_ entries: [SymptomEntry]) -> some View {
    Section {
      ForEach(entries.prefix(Self.entryLimit)) { entry in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
              .font(.body.weight(.semibold))
              .foregroundStyle(entry.level == nil ? .secondary : .primary)
            Text(entry.sourceName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text(SymptomFormat.time(entry, calendar: calendar))
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Entries")
    } footer: {
      if entries.count > Self.entryLimit {
        Text("Showing the \(Self.entryLimit) most recent entries in this period.")
      }
    }
  }

}

/// How a symptom's page writes days and times.
enum SymptomFormat {
  /// "1 Day", "4 Days".
  static func days(_ count: Int) -> String {
    count == 1 ? "1 Day" : "\(count) Days"
  }

  /// "Oct 15, 2025 at 9:41 AM", or "Oct 15, 2025, 9:41 – 11:05 AM" for an entry that lasts more
  /// than a minute.
  static func time(_ entry: SymptomEntry, calendar: Calendar) -> String {
    guard entry.end.timeIntervalSince(entry.start) > 60 else {
      return entry.start.formatted(
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
          .month(.abbreviated).day().year().hour().minute())
    }
    return (entry.start..<entry.end).formatted(
      Date.IntervalFormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone))
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
