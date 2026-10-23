import Charts
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import LilUI
import SQLiteData
import SwiftUI

/// One metric over a chosen period, as in Health: D, W, M, 6M or Y, earlier periods with the
/// arrows (both in the toolbar, as in Calendar), the period's summary, and a chart whose bars show
/// their value on hover. Follows the local database as sync changes it.
struct MetricDetailView: View {
  let type: HealthDataType
  @State private var range = ChartRange.week
  @State private var offset = 0
  /// Loaded by the view's task, for quantity types and the category types charted like them, with
  /// the period it's for and the lines over it. While another period loads, the page keeps showing
  /// it (851-3084).
  @Fetch private var chart: PeriodChart? = nil

  init(type: HealthDataType) {
    self.type = type
  }

  var body: some View {
    Group {
      if type.kind == .characteristic {
        // A single value, with no chart: Health Details shows it with the others (851-3026), as
        // the sidebar's search opens it.
        HealthDetailsView()
      } else if type.id == HealthDatabase.sleepType {
        SleepDetailView(type: type)
      } else if HealthDatabase.opensCycleTracking(type.id) {
        // Every Cycle Tracking type, on its latest sample's day (851-2830).
        CycleTrackingView(typeID: type.id)
      } else if type.kind == .activitySummary {
        ActivityRingsView()
      } else if type.id == HealthDatabase.bloodPressureType {
        BloodPressureView()
      } else if type.id == HealthDatabase.foodType {
        FoodView()
      } else if type.category == .symptoms {
        // Every symptom, with its severity over time (851-2828).
        SymptomView(type: type)
      } else if type.kind == .workout {
        WorkoutsView()
      } else if type.kind == .workoutRoute {
        // Workouts with a route, then the routes no workout shows (851-2835).
        WorkoutsView(onlyWithRoutes: true)
      } else if type.kind == .electrocardiogram {
        ElectrocardiogramsView()
      } else if type.kind == .audiogram {
        AudiogramsView()
      } else if type.kind == .document {
        HealthDocumentsView()
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
      } else if let kind = HealthNotificationKind(rawValue: type.id) {
        // High heart rate, noise, walking steadiness… notifications (851-2829).
        HealthNotificationsView(kind: kind)
      } else if type.kind == .quantity || HealthDatabase.categoryChartTypes.contains(type.id) {
        MetricDetailContent(
          type: type, range: $range, offset: $offset, state: chartState)
      } else {
        // Other kinds without a chart of their own yet. No catalog type gets here since
        // characteristics open Health Details (851-3026): it's for types added later.
        ContentUnavailableView(
          type.name, systemImage: type.symbolName,
          description: Text("A chart for \(type.name) is coming."))
      }
    }
    .task(id: [range.rawValue, String(offset)]) {
      guard type.kind == .quantity || HealthDatabase.categoryChartTypes.contains(type.id)
      else { return }
      _ = try? await $chart.load(
        MetricChartRequest(typeID: type.id, range: range, offset: offset),
        scheduler: MainQueueScheduler())
    }
  }

  /// The chart loaded last, updating while it's another period's or a load is running.
  private var chartState: MetricDetailContent.State {
    if let error = $chart.loadError { return .failed(error.localizedDescription) }
    guard let chart else { return .loading }
    return .loaded(
      chart, isUpdating: $chart.isLoading || chart.range != range || chart.offset != offset)
  }
}

/// A chart, with the range and period it's for, and the lines drawn over it for that period.
/// Loaded together, so a page showing one period while the next loads never shows another
/// period's lines, or loses its own (851-3084).
struct PeriodChart: Equatable, Sendable {
  let range: ChartRange
  /// 0 is the current period, -1 the one before.
  let offset: Int
  let chart: MetricChart
  var overlays: [MetricOverlay] = []
}

struct MetricChartRequest: FetchKeyRequest {
  let typeID: String
  let range: ChartRange
  let offset: Int

  func fetch(_ db: Database) throws -> PeriodChart? {
    guard let type = HealthCatalog.type(id: typeID) else { return nil }
    // The dependencies where the fetch started (SQLiteData passes them on), so snapshot
    // catalogs fix them.
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    let chart =
      if HealthDatabase.categoryChartTypes.contains(typeID) {
        // Stand hours, mindful minutes, handwashing and toothbrushing (851-2831).
        try HealthDatabase.categoryChart(
          of: typeID, range: range, offset: offset, now: now, calendar: calendar, db)
      } else {
        try HealthDatabase.metricChart(
          of: type, range: range, offset: offset, now: now, calendar: calendar, db)
      }
    let overlays = try MetricOverlay.lines(for: typeID).compactMap { line -> MetricOverlay? in
      guard let type = HealthCatalog.type(id: line.typeID) else { return nil }
      let lineChart = try HealthDatabase.metricChart(
        of: type, range: range, offset: offset, now: now, calendar: calendar, db)
      return MetricOverlay(name: line.name, color: line.color, points: lineChart.points)
    }
    return PeriodChart(range: range, offset: offset, chart: chart, overlays: overlays)
  }
}

/// A line over a chart: another type's value for each of the chart's periods.
struct MetricOverlay: Equatable, Sendable {
  /// What a type's chart draws over it: another type, by name and color.
  struct Line {
    let typeID: String
    let name: String
    let color: Color
  }

  let name: String
  let color: Color
  let points: [ChartPoint]

  /// The lines over a type's chart: heart rate's resting and walking averages.
  static func lines(for typeID: String) -> [Line] {
    guard typeID == HealthDatabase.heartRateType else { return [] }
    return [
      Line(typeID: HealthDatabase.restingHeartRateType, name: "Resting", color: .blue),
      Line(typeID: HealthDatabase.walkingHeartRateType, name: "Walking Average", color: .orange),
    ]
  }
}

/// What the detail shows, however it got it.
struct MetricDetailContent: View {
  enum State {
    /// Nothing to show yet: placeholders take the loaded page's space (851-3084).
    case loading
    /// A period's chart. Updating while another period, or the same one again, loads: it stays
    /// on screen, with a spinner, rather than the page blanking.
    case loaded(PeriodChart, isUpdating: Bool = false)
    case failed(String)

    var isLoading: Bool {
      if case .loading = self { true } else { false }
    }
  }

  let type: HealthDataType
  /// The period chosen in the toolbar, which can be ahead of the one shown (`range`, `offset`).
  @Binding private var selectedRange: ChartRange
  @Binding private var selectedOffset: Int
  let state: State
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`): the header
  /// shows the period around now before a chart loads.
  @Dependency(\.calendar) private var calendar
  @Dependency(\.date.now) private var now
  /// Whose units values are shown in (851-3116).
  @Dependency(\.locale) private var locale
  @SwiftUI.State private var hovered: Date?

  init(
    type: HealthDataType, range: Binding<ChartRange>, offset: Binding<Int>, state: State
  ) {
    self.type = type
    _selectedRange = range
    _selectedOffset = offset
    self.state = state
  }

  private var color: Color { type.color }
  /// Totals per bucket: a cumulative type's, or a category type charted like one.
  private var isCumulative: Bool { Self.isCumulative(type) }
  /// How the chart draws each period: the type's own style (851-3097), bars for a category type
  /// charted like a total.
  private var style: HealthDataType.ChartStyle { Self.style(of: type) }

  static func isCumulative(_ type: HealthDataType) -> Bool {
    type.aggregation?.isCumulative == true || HealthDatabase.categoryChartTypes.contains(type.id)
  }

  static func style(of type: HealthDataType) -> HealthDataType.ChartStyle {
    isCumulative(type) ? .bars : type.chartStyle ?? .ranges
  }
  /// What the values are in: the type's unit, or a category chart's (hours, minutes, times).
  private var unit: String? { type.unit ?? HealthDatabase.categoryChartUnit(type.id) }
  /// What the header writes values in, and so what the chart plots: km/h rather than the m/s
  /// they're stored in, so the axis reads as the header does, with round ticks (851-3105), in the
  /// locale's units (851-3116).
  private var displayUnit: MetricFormat.DisplayUnit {
    MetricFormat.unit(unit, typeID: type.id, locale: locale)
  }

  /// The period shown: the loaded chart's, which stays while another loads, or the one chosen
  /// before any has loaded. Everything drawn uses it, never the selection.
  private var range: ChartRange {
    if case .loaded(let loaded, _) = state { loaded.range } else { selectedRange }
  }

  private var offset: Int {
    if case .loaded(let loaded, _) = state { loaded.offset } else { selectedOffset }
  }

  private var isUpdating: Bool {
    if case .loaded(_, let isUpdating) = state { isUpdating } else { false }
  }

  /// The lines to draw: those loaded with the chart, with values, over a chart with data.
  private var shownOverlays: [MetricOverlay] {
    guard case .loaded(let loaded, _) = state, !loaded.chart.points.isEmpty else { return [] }
    return loaded.overlays.filter { !$0.points.isEmpty }
  }

  /// Whether the type draws lines over its chart (`MetricOverlay.lines(for:)`). Their legend's row
  /// is kept for them while they load or have no values, so they never move the rows below
  /// (851-3084).
  private var hasOverlays: Bool { !MetricOverlay.lines(for: type.id).isEmpty }

  var body: some View {
    // A grouped form on its own background, as Data Sources is (851-2989): one section for the
    // summary and the chart, another for the pages it opens.
    Form {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          header
          chartArea
            .delayedProgress(isLoading: state.isLoading)
            .frame(height: 280)
          if hasOverlays {
            legend
          }
        }
        .padding(.vertical, 6)
      }
      Section {
        if HealthDatabase.heartRateVariabilityTypes.contains(type.id) {
          NavigationLink("Beat-to-Beat Measurements") {
            // Built when opened: it fetches the series.
            Lazy { HeartbeatSeriesView() }
          }
        }
        NavigationLink("Show All Data") {
          AllDataView(type: type)
        }
        .layoutAnchor("Show All Data")
        NavigationLink("Data Sources") {
          DataSourcesView(type: type)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(type.name)
    // The range and ‹ Today › in the toolbar, and the View menu's commands (`PeriodCommands`).
    .periodControls(PagePeriod(range: $selectedRange, offset: $selectedOffset))
  }

  /// What the lines over the chart are. Its row's height whether or not any are drawn.
  private var legend: some View {
    ZStack(alignment: .leading) {
      // A line's height, kept while there's none.
      Text(" ")
        .hidden()
      HStack(spacing: 16) {
        ForEach(shownOverlays, id: \.name) { overlay in
          Label {
            Text(overlay.name)
          } icon: {
            Circle().fill(overlay.color).frame(width: 8, height: 8)
          }
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  // MARK: Header

  @ViewBuilder private var header: some View {
    let chart: MetricChart? = if case .loaded(let loaded, _) = state { loaded.chart } else { nil }
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
              chart?.interval ?? range.interval(offset: offset, now: now, calendar: calendar),
              range: range, calendar: calendar)
        )
        .foregroundStyle(.secondary)
      }
      Spacer()
    }
    // While another period loads, over the one shown.
    .updatingIndicator(isUpdating)
  }

  private func label(_ chart: MetricChart?, point: ChartPoint?) -> String {
    Self.caption(for: type, range: range, summary: chart?.summary, point: point)
  }

  /// The header's caption: what its value is, for the period or the hovered bar or point. A type
  /// that adds up has one caption per period, whether its chart is loading, empty or loaded, so
  /// it never changes as the chart arrives (851-3107).
  static func caption(
    for type: HealthDataType, range: ChartRange, summary: MetricChart.Summary?, point: ChartPoint?
  ) -> String {
    // A line's or dots' points and period are averages, as Health's weight is (851-3097).
    if style(of: type).isAverage { return "AVERAGE" }
    if isCumulative(type) {
      // Handwashing's and toothbrushing's period is their sessions' average length, a bar its
      // number of sessions.
      if point == nil, HealthDatabase.sessionChartTypes.contains(type.id) {
        return "AVERAGE DURATION"
      }
      return periodCaption(range, bar: point != nil)
    }
    if let point { return point.minimum == point.maximum ? "AVERAGE" : "RANGE" }
    switch summary {
    case .average: return "AVERAGE"
    case .range, nil: return "RANGE"
    // Only types that add up have these.
    case .total, .dailyAverage: return periodCaption(range, bar: false)
    case .averageDuration: return "AVERAGE DURATION"
    }
  }

  /// A cumulative type's caption, as Health's (851-3099). For the period: the day's total, then
  /// the average day, which Health calls the week's and month's "AVERAGE", of their daily bars,
  /// and 6 months' and a year's "DAILY AVERAGE", under weekly and monthly bars. For a hovered
  /// `bar`: "TOTAL" for D's hours and W's and M's days, and "DAILY AVERAGE" for 6 months' weekly
  /// bars and a year's monthly ones, each the average day of its week or month. Either way the
  /// value is a total per day with data (`MetricChart.Summary.dailyAverage`), or a day's or an
  /// hour's total.
  static func periodCaption(_ range: ChartRange, bar: Bool) -> String {
    switch range {
    case .day: "TOTAL"
    case .week, .month: bar ? "TOTAL" : "AVERAGE"
    case .sixMonths, .year: "DAILY AVERAGE"
    }
  }

  private func valueText(_ chart: MetricChart?, point: ChartPoint?) -> some View {
    let values: [Double]? =
      if let point {
        style.isAverage || point.minimum == point.maximum
          ? [point.value] : [point.minimum, point.maximum]
      } else {
        switch chart?.summary {
        case .total(let value), .dailyAverage(let value), .average(let value): [value]
        case .range(let low, let high): [low, high]
        case .averageDuration(let seconds): [seconds]
        case nil: nil
        }
      }
    // In the unit the chart plots, so the two always agree.
    let shown = displayUnit
    let formatted = values?.map { value in
      if point == nil, case .averageDuration = chart?.summary {
        return MetricFormat.duration(value)
      }
      return (number: shown.format(shown.convert(value)), unit: shown.label)
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
      // Its space, under the spinner `delayedProgress` shows (851-3086).
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load \(type.name)", systemImage: "exclamationmark.triangle",
        description: Text(reason)
      )
      // A form's row would otherwise give it only its ideal width, off center.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let loaded, _):
      let chart = loaded.chart
      let shown = displayUnit
      Chart {
        ForEach(chart.points, id: \.start) { point in
          if style.isAverage {
            average(point, in: chart, unit: shown)
          } else {
            bar(point, in: chart, unit: shown)
          }
        }
        ForEach(shownOverlays, id: \.name) { overlay in
          ForEach(overlay.points, id: \.start) { point in
            LineMark(
              x: .value("Date", point.start, unit: range.barUnit),
              y: .value(overlay.name, shown.convert(point.value)),
              series: .value("Line", overlay.name)
            )
            .foregroundStyle(overlay.color)
            .lineStyle(StrokeStyle(lineWidth: 2))
            PointMark(
              x: .value("Date", point.start, unit: range.barUnit),
              y: .value(overlay.name, shown.convert(point.value))
            )
            .foregroundStyle(overlay.color)
            .symbolSize(24)
          }
        }
        // Sound above this over time can affect hearing.
        if HealthDatabase.soundLevelTypes.contains(type.id), !chart.points.isEmpty {
          RuleMark(y: .value("Loud", shown.convert(HealthDatabase.loudSoundLevel)))
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
      // Fitted in the unit plotted. An empty period keeps a scale of the type's, in it too
      // (851-3102).
      .chartYDomain(
        chart.points.isEmpty
          ? emptyDomain(for: type, unit: unit, hourly: isCumulative && range == .day)
            .converted(by: shown)
          : style.isAverage ? fittedDomain(chart.points.map { shown.convert($0.value) }) : nil
      )
      .chartPlotStyle { $0.clipped() }
      .chartXSelection(value: $hovered)
      .chartYAxis {
        if shown.label == "%" {
          // Plotted as percentages, 22 for 22%, as the header shows them.
          AxisMarks(
            format: FloatingPointFormatStyle<Double>.Percent().scale(1), position: .trailing)
        } else if shown.compound != nil {
          // Plotted in inches or pounds, and labeled as the header writes them: 5′ 10″.
          AxisMarks(position: .trailing) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
              if let number = value.as(Double.self) { Text(shown.format(number)) }
            }
          }
        } else {
          AxisMarks(position: .trailing)
        }
      }
      .emptyChartAccessibility(
        chart.points.isEmpty,
        label: ChartFormat.noData(
          ChartFormat.span(chart.interval, range: range, calendar: calendar)))
    }
  }

  /// A period's bar: its total for a cumulative type, otherwise its range.
  @ChartContentBuilder
  private func bar(
    _ point: ChartPoint, in chart: MetricChart, unit: MetricFormat.DisplayUnit
  ) -> some ChartContent {
    if isCumulative {
      BarMark(
        x: .value("Date", point.start, unit: range.barUnit),
        y: .value("Value", unit.convert(point.value))
      )
      .foregroundStyle(color.opacity(isHovered(point, in: chart) ? 1 : 0.8))
    } else {
      BarMark(
        x: .value("Date", point.start, unit: range.barUnit),
        yStart: .value("Minimum", unit.convert(point.minimum)),
        yEnd: .value("Maximum", unit.convert(point.maximum)),
        width: .ratio(0.35)
      )
      .clipShape(Capsule())
      .foregroundStyle(color.opacity(isHovered(point, in: chart) ? 1 : 0.8))
    }
  }

  /// A period's dot, its average (851-3097), on a line through them all for a line type, which
  /// goes on over periods without readings, as Health's does.
  @ChartContentBuilder
  private func average(
    _ point: ChartPoint, in chart: MetricChart, unit: MetricFormat.DisplayUnit
  ) -> some ChartContent {
    if style == .line {
      LineMark(
        x: .value("Date", point.start, unit: range.barUnit),
        y: .value("Value", unit.convert(point.value))
      )
      .foregroundStyle(color.opacity(0.8))
      .lineStyle(StrokeStyle(lineWidth: 2))
    }
    PointMark(
      x: .value("Date", point.start, unit: range.barUnit),
      y: .value("Value", unit.convert(point.value))
    )
    .foregroundStyle(color)
    .symbolSize(isHovered(point, in: chart) ? 100 : 36)
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
}

extension View {
  /// The chart's y-axis over `domain`, or Swift Charts' own (from zero) without one.
  @ViewBuilder fileprivate func chartYDomain(_ domain: ClosedRange<Double>?) -> some View {
    if let domain {
      chartYScale(domain: domain)
    } else {
      self
    }
  }
}
