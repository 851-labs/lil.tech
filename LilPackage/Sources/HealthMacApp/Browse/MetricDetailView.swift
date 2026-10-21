import Charts
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import SQLiteData
import SwiftUI

/// One metric over a chosen period, as in Health: D, W, M, 6M or Y, earlier periods with the
/// arrows (both in the toolbar, as in Calendar), the period's summary, and a chart whose bars show
/// their value on hover. Follows the local database as sync changes it.
struct MetricDetailView: View {
  let type: HealthDataType
  @State private var range = ChartRange.week
  @State private var offset = 0
  /// Loaded by the view's task, for quantity types and the category types charted like them.
  @Fetch private var chart: MetricChart? = nil
  /// Lines drawn over the chart, for the same period: heart rate's resting and walking averages.
  @Fetch private var overlays: [MetricOverlay] = []

  init(type: HealthDataType) {
    self.type = type
  }

  var body: some View {
    Group {
      if type.id == HealthDatabase.sleepType {
        SleepDetailView(type: type)
      } else if HealthDatabase.opensCycleTracking(type.id) {
        // Every Cycle Tracking type, on its latest sample's day (851-2830).
        CycleTrackingView(typeID: type.id)
      } else if type.kind == .activitySummary {
        ActivityRingsView()
      } else if type.kind == .workout {
        WorkoutsView()
      } else if type.kind == .electrocardiogram {
        ElectrocardiogramsView()
      } else if type.kind == .audiogram {
        AudiogramsView()
      } else if type.kind == .visionPrescription {
        VisionPrescriptionsView()
      } else if type.kind == .medication || type.kind == .medicationDoseEvent {
        MedicationsView()
      } else if type.kind == .heartbeatSeries {
        HeartbeatSeriesView()
      } else if type.kind == .stateOfMind {
        StateOfMindView()
      } else if type.kind == .scoredAssessment, let kind = AssessmentKind(rawValue: type.id) {
        ScoredAssessmentsView(kind: kind, name: type.name)
      } else if type.kind == .quantity || HealthDatabase.categoryChartTypes.contains(type.id) {
        MetricDetailContent(
          type: type, range: $range, offset: $offset,
          state: $chart.loadError.map { .failed($0.localizedDescription) }
            ?? ($chart.isLoading ? .loading : chart.map { .loaded($0) } ?? .loading),
          overlays: overlays)
      } else {
        // Other kinds without a chart of their own yet.
        ContentUnavailableView(
          type.name, systemImage: type.category?.symbolName ?? "questionmark",
          description: Text("A chart for \(type.name) is coming."))
      }
    }
    .task(id: [range.rawValue, String(offset)]) {
      guard type.kind == .quantity || HealthDatabase.categoryChartTypes.contains(type.id)
      else { return }
      async let overlaid: Void = loadOverlays()
      _ = try? await $chart.load(
        MetricChartRequest(typeID: type.id, range: range, offset: offset),
        scheduler: MainQueueScheduler())
      await overlaid
    }
  }

  private func loadOverlays() async {
    guard type.id == HealthDatabase.heartRateType else { return }
    _ = try? await $overlays.load(
      MetricOverlaysRequest(
        lines: [
          .init(typeID: HealthDatabase.restingHeartRateType, name: "Resting", color: .blue),
          .init(
            typeID: HealthDatabase.walkingHeartRateType, name: "Walking Average", color: .orange),
        ],
        range: range, offset: offset),
      scheduler: MainQueueScheduler())
  }
}

struct MetricChartRequest: FetchKeyRequest {
  let typeID: String
  let range: ChartRange
  let offset: Int

  func fetch(_ db: Database) throws -> MetricChart? {
    guard let type = HealthCatalog.type(id: typeID) else { return nil }
    if HealthDatabase.categoryChartTypes.contains(typeID) {
      // Stand hours, mindful minutes, handwashing and toothbrushing (851-2831).
      return try HealthDatabase.categoryChart(
        of: typeID, range: range, offset: offset, now: .now, calendar: .current, db)
    }
    return try HealthDatabase.metricChart(
      of: type, range: range, offset: offset, now: .now, calendar: .current, db)
  }
}

/// Other types' values for the same period, as lines over a chart.
struct MetricOverlaysRequest: FetchKeyRequest {
  struct Line: Hashable {
    let typeID: String
    let name: String
    let color: Color
  }

  let lines: [Line]
  let range: ChartRange
  let offset: Int

  func fetch(_ db: Database) throws -> [MetricOverlay] {
    try lines.compactMap { line in
      guard let type = HealthCatalog.type(id: line.typeID) else { return nil }
      let chart = try HealthDatabase.metricChart(
        of: type, range: range, offset: offset, now: .now, calendar: .current, db)
      return MetricOverlay(
        name: line.name, color: line.color, points: chart.points, range: range, offset: offset)
    }
  }
}

/// A line over a chart: another type's value for each of its periods, for the range and period
/// it was loaded for.
struct MetricOverlay: Equatable, Sendable {
  let name: String
  let color: Color
  let points: [ChartPoint]
  let range: ChartRange
  let offset: Int
}

/// What the detail shows, however it got it.
struct MetricDetailContent: View {
  enum State {
    case loading
    case loaded(MetricChart)
    case failed(String)
  }

  let type: HealthDataType
  @Binding var range: ChartRange
  @Binding var offset: Int
  let state: State
  var overlays: [MetricOverlay] = []
  var calendar = Calendar.current
  @SwiftUI.State private var hovered: Date?

  private var color: Color { type.category?.color ?? .accentColor }
  /// Totals per bucket: a cumulative type's, or a category type charted like one.
  private var isCumulative: Bool {
    type.aggregation?.isCumulative == true || HealthDatabase.categoryChartTypes.contains(type.id)
  }
  /// What the values are in: the type's unit, or a category chart's (hours, minutes, times).
  private var unit: String? { type.unit ?? HealthDatabase.categoryChartUnit(type.id) }

  /// The lines to draw: those loaded for the period shown, with values, over a chart with data.
  private var shownOverlays: [MetricOverlay] {
    guard case .loaded(let chart) = state, !chart.points.isEmpty else { return [] }
    return overlays.filter {
      $0.range == range && $0.offset == offset && !$0.points.isEmpty
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 12) {
          header
          chartArea
            .frame(height: 280)
          if !shownOverlays.isEmpty {
            HStack(spacing: 16) {
              ForEach(shownOverlays, id: \.name) { overlay in
                Label {
                  Text(overlay.name)
                } icon: {
                  Circle().fill(overlay.color).frame(width: 8, height: 8)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
          }
        }
        .padding(16)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))

        VStack(spacing: 0) {
          if HealthDatabase.heartRateVariabilityTypes.contains(type.id) {
            NavigationLink {
              // Built when opened: it fetches the series.
              Lazy { HeartbeatSeriesView() }
            } label: {
              linkRow("Beat-to-Beat Measurements")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 14)
          }
          NavigationLink {
            AllDataView(type: type)
          } label: {
            linkRow("Show All Data")
          }
          .buttonStyle(.plain)
          Divider().padding(.leading, 14)
          NavigationLink {
            DataSourcesView(type: type)
          } label: {
            linkRow("Data Sources")
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
    // The range and ‹ Today › in the toolbar, and the View menu's commands (`PeriodCommands`).
    .periodControls(PagePeriod(range: $range, offset: $offset))
  }

  // MARK: Header

  @ViewBuilder private var header: some View {
    let chart: MetricChart? = if case .loaded(let chart) = state { chart } else { nil }
    let point = chart.flatMap { hoveredPoint(in: $0) }
    HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        Text(label(chart, point: point))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        valueText(chart, point: point)
        Text(
          point.map { ChartFormat.bucket($0.start, range: range, calendar: calendar) }
            ?? ChartFormat.span(
              chart?.interval ?? range.interval(offset: offset, now: .now, calendar: calendar),
              range: range, calendar: calendar)
        )
        .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private func label(_ chart: MetricChart?, point: ChartPoint?) -> String {
    let cumulative = isCumulative
    if let point {
      if cumulative { return range == .sixMonths || range == .year ? "DAILY AVERAGE" : "TOTAL" }
      return point.minimum == point.maximum ? "AVERAGE" : "RANGE"
    }
    switch chart?.summary {
    case .total: return "TOTAL"
    case .dailyAverage: return "DAILY AVERAGE"
    case .range: return "RANGE"
    case .average: return "AVERAGE"
    case .averageDuration: return "AVERAGE DURATION"
    case nil: return cumulative && range == .day ? "TOTAL" : cumulative ? "DAILY AVERAGE" : "RANGE"
    }
  }

  private func valueText(_ chart: MetricChart?, point: ChartPoint?) -> some View {
    let values: [Double]? =
      if let point {
        point.minimum == point.maximum ? [point.value] : [point.minimum, point.maximum]
      } else {
        switch chart?.summary {
        case .total(let value), .dailyAverage(let value), .average(let value): [value]
        case .range(let low, let high): [low, high]
        case .averageDuration(let seconds): [seconds]
        case nil: nil
        }
      }
    let formatted = values?.map { value in
      if point == nil, case .averageDuration = chart?.summary {
        return MetricFormat.duration(value)
      }
      return MetricFormat.value(value, unit: unit, typeID: type.id)
    }
    return HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text(formatted?.map(\.number).joined(separator: "–") ?? (chart == nil ? "–" : "No Data"))
        .font(.system(.largeTitle, design: .rounded).bold())
        .foregroundStyle(formatted == nil ? .secondary : .primary)
      if let unit = formatted?.first?.unit {
        Text(unit)
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Chart

  @ViewBuilder private var chartArea: some View {
    switch state {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load \(type.name)", systemImage: "exclamationmark.triangle",
        description: Text(reason))
    case .loaded(let chart):
      Chart {
        ForEach(chart.points, id: \.start) { point in
          bar(point, in: chart)
        }
        ForEach(shownOverlays, id: \.name) { overlay in
          ForEach(overlay.points, id: \.start) { point in
            LineMark(
              x: .value("Date", point.start, unit: range.barUnit),
              y: .value(overlay.name, point.value),
              series: .value("Line", overlay.name)
            )
            .foregroundStyle(overlay.color)
            .lineStyle(StrokeStyle(lineWidth: 2))
            PointMark(
              x: .value("Date", point.start, unit: range.barUnit),
              y: .value(overlay.name, point.value)
            )
            .foregroundStyle(overlay.color)
            .symbolSize(24)
          }
        }
        // Sound above this over time can affect hearing.
        if HealthDatabase.soundLevelTypes.contains(type.id), !chart.points.isEmpty {
          RuleMark(y: .value("Loud", HealthDatabase.loudSoundLevel))
            .foregroundStyle(.orange)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .annotation(position: .top, alignment: .leading) {
              Text("Loud: \(Int(HealthDatabase.loudSoundLevel)) dB")
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
      }
      .chartXScale(domain: domain(chart))
      .chartPlotStyle { $0.clipped() }
      .chartXSelection(value: $hovered)
      .chartYAxis {
        AxisMarks(position: .trailing)
      }
      .overlay {
        if chart.points.isEmpty {
          Text("No Data")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// A period's bar: its total for a cumulative type, otherwise its range.
  @ChartContentBuilder
  private func bar(_ point: ChartPoint, in chart: MetricChart) -> some ChartContent {
    if isCumulative {
      BarMark(
        x: .value("Date", point.start, unit: range.barUnit),
        y: .value("Value", point.value)
      )
      .foregroundStyle(color.opacity(isHovered(point, in: chart) ? 1 : 0.8))
    } else {
      BarMark(
        x: .value("Date", point.start, unit: range.barUnit),
        yStart: .value("Minimum", point.minimum),
        yEnd: .value("Maximum", point.maximum),
        width: .ratio(0.35)
      )
      .clipShape(Capsule())
      .foregroundStyle(color.opacity(isHovered(point, in: chart) ? 1 : 0.8))
    }
  }

  private func isHovered(_ point: ChartPoint, in chart: MetricChart) -> Bool {
    hoveredPoint(in: chart) == point
  }

  /// The point of the bar under the pointer, if that bar has data.
  private func hoveredPoint(in chart: MetricChart) -> ChartPoint? {
    guard let hovered, let bar = calendar.dateInterval(of: range.barUnit, for: hovered)
    else { return nil }
    return chart.points.first { $0.start == bar.start }
  }

  /// The chart's span, widened to whole bars: six months' first and last weeks run past them.
  private func domain(_ chart: MetricChart) -> ClosedRange<Date> {
    let start = calendar.dateInterval(of: range.barUnit, for: chart.interval.start)?.start
    let end = calendar.dateInterval(
      of: range.barUnit, for: chart.interval.end.addingTimeInterval(-1))?.end
    return (start ?? chart.interval.start)...(end ?? chart.interval.end)
  }

  // MARK: Links

  private func linkRow(_ title: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption.bold())
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }
}

/// How the detail writes its periods.
enum ChartFormat {
  /// The period shown: "Oct 15, 2025", "Oct 12 – 18, 2025", "Oct 2025", "May – Oct 2025", "2025".
  static func span(_ interval: DateInterval, range: ChartRange, calendar: Calendar) -> String {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    // The last moment inside, so a week doesn't end on the next Sunday.
    let last = interval.end.addingTimeInterval(-1)
    switch range {
    case .day: return interval.start.formatted(style.month(.abbreviated).day().year())
    case .week:
      return (interval.start..<last).formatted(
        Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
    case .month: return interval.start.formatted(style.month(.abbreviated).year())
    case .sixMonths:
      // The year on both ends when the months span two.
      let sameYear =
        calendar.component(.year, from: interval.start) == calendar.component(.year, from: last)
      let first = sameYear ? style.month(.abbreviated) : style.month(.abbreviated).year()
      return
        "\(interval.start.formatted(first)) – \(last.formatted(style.month(.abbreviated).year()))"
    case .year: return interval.start.formatted(style.year())
    }
  }

  /// One bar's period: an hour, a day, a week or a month.
  static func bucket(_ start: Date, range: ChartRange, calendar: Calendar) -> String {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    switch range {
    case .day: return start.formatted(style.month(.abbreviated).day().hour())
    case .week, .month:
      return start.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
    case .sixMonths: return "Week of \(start.formatted(style.month(.abbreviated).day()))"
    case .year: return start.formatted(style.month(.wide).year())
    }
  }
}
