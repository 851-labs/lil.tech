public import Charts
import Dependencies
public import Foundation
public import HealthCards
import HealthCatalog
import LilUI
public import SwiftUI

// A card's chart over a period, as its full page draws it (851-3207), moved here so the iPhone's
// page draws exactly what the Mac's does (851-3212, docs/decisions/cards.md, UI).

/// A card's data over one period, with the range, period and spec it's for, so a page showing it
/// while the next loads draws it as it was loaded.
public struct CardPeriod: Equatable, Sendable {
  public let range: CardRange
  /// 0 is the current period, -1 the one before.
  public let offset: Int
  public let spec: CardSpec
  public let data: CardData

  public init(range: CardRange, offset: Int, spec: CardSpec, data: CardData) {
    self.range = range
    self.offset = offset
    self.spec = spec
    self.data = data
  }
}

/// A card over a period, as its page draws it at the top: the header (its symbol and name, the
/// caption, the value and the period's dates, or a hovered point's), the chart in the card's style,
/// and the legend when it draws more than one line. The page shows it, and the editor's live
/// preview (851-3208), on the Mac and the iPhone (851-3212).
public struct CardChart: View {
  public enum State: Sendable {
    /// Nothing to show yet: placeholders take the loaded page's space (851-3084).
    case loading
    /// A period's data. Updating while another period, or the same one again, loads: it stays on
    /// screen, with a spinner, rather than the page blanking.
    case loaded(CardPeriod, isUpdating: Bool = false)
    case failed(String)

    public var isLoading: Bool {
      if case .loading = self { true } else { false }
    }
  }

  let spec: CardSpec
  /// The period chosen, which can be ahead of the one shown. `nil` until a page knows which
  /// period it opens on (the iPhone's, while it looks for the latest data, 851-3212): its dates
  /// read "–" until then.
  let selectedRange: CardRange
  let selectedOffset: Int?
  let state: State
  /// The chart's own height, under the header: the page's is Metric Detail's.
  var chartHeight: CGFloat = 280
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.calendar) private var calendar
  @Dependency(\.date.now) private var now
  /// Whose units values are shown in (851-3116).
  @Dependency(\.locale) private var locale
  @SwiftUI.State private var hovered: Date?

  public init(
    spec: CardSpec, range: CardRange, offset: Int?, state: State, chartHeight: CGFloat = 280
  ) {
    self.spec = spec
    self.selectedRange = range
    self.selectedOffset = offset
    self.state = state
    self.chartHeight = chartHeight
  }

  /// The loaded period, which stays while another loads.
  private var loaded: CardPeriod? {
    if case .loaded(let loaded, _) = state { loaded } else { nil }
  }

  /// The spec drawn: the one its data was loaded for, which an edit replaces once it loads.
  private var shownSpec: CardSpec { loaded?.spec ?? spec }

  /// The period shown: the loaded one's, or the one chosen before any has loaded.
  private var range: CardRange { loaded?.range ?? selectedRange }
  private var offset: Int? { loaded?.offset ?? selectedOffset }

  private var isUpdating: Bool {
    if case .loaded(_, let isUpdating) = state { isUpdating } else { false }
  }

  private var color: Color { Color(paletteName: shownSpec.display.color.rawValue) }

  /// What values are shown and plotted in: the card's pinned unit, or the locale's for its lead.
  private var displayUnit: MetricFormat.DisplayUnit {
    MetricFormat.unit(of: shownSpec, locale: locale)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      chartArea
        .delayedProgress(isLoading: state.isLoading)
        .frame(height: chartHeight)
      // The spec's, not the loaded data's, so it's there while the chart loads.
      let legend = spec.legend
      if !legend.isEmpty {
        CardLegend(lines: legend, color: Color(paletteName: spec.display.color.rawValue))
      }
    }
  }

  // MARK: Header

  @ViewBuilder private var header: some View {
    let point = loaded.flatMap { hoveredPoint(in: $0.data) }
    HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        Label(spec.display.name, systemImage: spec.display.symbol)
          .font(.headline)
          .foregroundStyle(Color(paletteName: spec.display.color.rawValue))
          .padding(.bottom, 6)
        Text(
          Self.caption(
            for: shownSpec, range: range, summary: loaded?.data.summary, point: point)
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        valueText(point: point)
        Text(
          point.map {
            Self.bucket($0.start, grain: loaded?.data.grain, spec: shownSpec, calendar: calendar)
          }
            ?? periodInterval.map { PeriodFormat.span($0, range: range, calendar: calendar) } ?? "–"
        )
        .foregroundStyle(.secondary)
      }
      Spacer()
    }
    // While another period loads, over the one shown.
    .updatingIndicator(isUpdating)
  }

  /// The period shown: the loaded one's, or the chosen one's while it loads.
  private var periodInterval: DateInterval? {
    loaded?.data.interval
      ?? offset.map { range.interval(offset: $0, now: now, calendar: calendar) }
  }

  private func valueText(point: LeadPoint?) -> some View {
    let values: [Double]? =
      if let point {
        // A range only where the caption says RANGE: an average drawn as ranges.
        Self.caption(for: shownSpec, range: range, summary: nil, point: point) == "RANGE"
          ? [point.minimum, point.maximum] : [point.value]
      } else if let summary = loaded?.data.summary {
        if summary.kind == .range, let minimum = summary.minimum, let maximum = summary.maximum {
          [minimum, maximum]
        } else {
          summary.value.map { [$0] }
        }
      } else {
        nil
      }
    let shown = displayUnit
    let numbers = values?.map { shown.format(shown.convert($0)) }
    return HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text(numbers?.joined(separator: "–") ?? (loaded == nil ? "–" : "No Data"))
        .font(.system(.largeTitle, design: .rounded).bold())
        .foregroundStyle(numbers == nil ? .secondary : .primary)
      if numbers != nil, !shown.label.isEmpty {
        Text(shown.label)
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The header's caption: what its value is, for the period or the hovered point. Before the
  /// period loads, and without data, the one its summary would have, so it doesn't change as the
  /// chart arrives (851-3107).
  nonisolated public static func caption(
    for spec: CardSpec, range: CardRange, summary: CardSummary?, point: LeadPoint?
  ) -> String {
    guard let lead = spec.lead else { return "" }
    if let point {
      guard case .series(let series) = lead else { return "AVERAGE" }
      switch series.aggregation {
      case .sum:
        // An auto card's weeks and months are their average day, as Metric Detail's (851-3099).
        return spec.bucket == .auto && (range == .sixMonths || range == .year)
          ? "DAILY AVERAGE" : "TOTAL"
      case .avg:
        return spec.chart.style == .ranges && point.minimum != point.maximum ? "RANGE" : "AVERAGE"
      // A point is its bucket's reading, though the period's header may be their average.
      case .first: return "FIRST"
      case .latest: return "LATEST"
      default:
        return caption(of: spec.expectedSummaryKind(at: range))
      }
    }
    return caption(of: summary?.kind ?? spec.expectedSummaryKind(at: range))
  }

  nonisolated private static func caption(of kind: CardSummary.Kind) -> String {
    switch kind {
    case .total, .count: "TOTAL"
    case .average: "AVERAGE"
    case .dailyAverage: "DAILY AVERAGE"
    case .range: "RANGE"
    case .lowest: "LOWEST"
    case .highest: "HIGHEST"
    case .first: "FIRST"
    case .latest: "LATEST"
    }
  }

  /// A point's bucket, as the header dates it: "Aug 13, 3 PM", "Tue, Aug 13", "Night of Aug 13"
  /// (a night is named by the day it ends on), "Week of Aug 4", "August 2024".
  nonisolated public static func bucket(
    _ start: Date, grain: CardGrain?, spec: CardSpec, calendar: Calendar
  ) -> String {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    switch grain ?? .day {
    case .hour: return start.formatted(style.month(.abbreviated).day().hour())
    case .day where spec.bucket == .night:
      return "Night of \(start.formatted(style.weekday(.abbreviated).month(.abbreviated).day()))"
    case .day: return start.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
    case .week: return "Week of \(start.formatted(style.month(.abbreviated).day()))"
    case .month: return start.formatted(style.month(.wide).year())
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
        "Couldn't Load \(spec.display.name)", systemImage: "exclamationmark.triangle",
        description: Text(reason)
      )
      // A form's row would otherwise give it only its ideal width, off center.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let loaded, _):
      chart(loaded.data, spec: loaded.spec)
    }
  }

  private func chart(_ data: CardData, spec: CardSpec) -> some View {
    let shown = displayUnit
    let series = data.series.filter { !$0.hidden }
    let formulas = data.formulas.filter { !$0.hidden }
    let style = spec.chart.style
    let unit = data.grain.component
    let isEmpty = series.allSatisfy(\.points.isEmpty) && formulas.allSatisfy(\.points.isEmpty)
    let goal = data.goal.map { shown.convert($0) }
    let yDomain = yDomain(
      data, spec: spec, series: series, formulas: formulas, isEmpty: isEmpty, unit: shown)
    let hoveredStart = hoveredPoint(in: data)?.start
    // Bars and capsules of several series sit side by side in each bucket.
    let isPositioned = (style == .bars || style == .ranges) && series.count > 1
    return Chart {
      ForEach(Array(series.enumerated()), id: \.element.id) { index, series in
        let mark = CardSeriesMark(index: index)
        ForEach(series.points, id: \.start) { point in
          seriesMarks(
            point, of: series, mark: mark, isPositioned: isPositioned,
            style: style, unit: unit, shown: shown,
            isHovered: index == 0 && point.start == hoveredStart)
        }
      }
      ForEach(formulas) { formula in
        ForEach(formula.points, id: \.start) { point in
          LineMark(
            x: .value("Date", point.start, unit: unit),
            y: .value("Value", shown.convert(point.value)),
            series: .value("Line", "formula \(formula.id)")
          )
          .foregroundStyle(color)
          .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
      }
      if let goal {
        RuleMark(y: .value("Goal", goal))
          .foregroundStyle(Color.secondary)
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .annotation(position: .top, alignment: .leading) {
            Text("Goal")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
      }
    }
    .chartXScale(domain: domain(data))
    .chartYDomain(yDomain)
    .chartLegend(.hidden)
    .chartPlotStyle { $0.clipped() }
    .chartXSelection(value: $hovered)
    .valueAxis(shown, domain: yDomain)
    .emptyChartAccessibility(
      isEmpty,
      label: PeriodFormat.noData(PeriodFormat.span(data.interval, range: range, calendar: calendar))
    )
  }

  /// A series' point in the card's style, in the card's color at the series' opacity: a bar from
  /// 0, a capsule from the lowest to the highest reading, or a dot of its shape, joined by a line
  /// for `line`. Bars and capsules of several series sit side by side.
  @ChartContentBuilder
  private func seriesMarks(
    _ point: CardPoint, of series: CardData.Series, mark: CardSeriesMark, isPositioned: Bool,
    style: HealthDataType.ChartStyle, unit: Calendar.Component, shown: MetricFormat.DisplayUnit,
    isHovered: Bool
  ) -> some ChartContent {
    let fill = color.opacity(mark.opacity * (isHovered ? 1 : 0.8))
    switch style {
    case .bars:
      BarMark(
        x: .value("Date", point.start, unit: unit),
        y: .value("Value", shown.convert(point.value))
      )
      .foregroundStyle(fill)
      .position(by: .value("Series", isPositioned ? series.id : ""))
    case .ranges:
      BarMark(
        x: .value("Date", point.start, unit: unit),
        yStart: .value("Minimum", shown.convert(point.minimum)),
        yEnd: .value("Maximum", shown.convert(point.maximum)),
        width: .ratio(isPositioned ? 0.25 : 0.35)
      )
      .clipShape(Capsule())
      .foregroundStyle(fill)
      .position(by: .value("Series", isPositioned ? series.id : ""))
    case .dots, .line:
      if style == .line {
        LineMark(
          x: .value("Date", point.start, unit: unit),
          y: .value("Value", shown.convert(point.value)),
          series: .value("Line", "series \(series.id)")
        )
        .foregroundStyle(color.opacity(mark.opacity * 0.8))
        .lineStyle(StrokeStyle(lineWidth: 2))
      }
      PointMark(
        x: .value("Date", point.start, unit: unit),
        y: .value("Value", shown.convert(point.value))
      )
      .symbol(symbol(mark))
      .foregroundStyle(color.opacity(mark.opacity))
      .symbolSize(isHovered ? 100 : 36)
    }
  }

  private func symbol(_ mark: CardSeriesMark) -> BasicChartSymbolShape {
    switch mark {
    case .circle: .circle
    case .square: .square
    case .triangle: .triangle
    case .diamond: .diamond
    }
  }

  /// The value axis: fitted to dots and lines (and the goal), as Metric Detail's averages are
  /// (851-3097); from 0 for bars and ranges (Swift Charts' own, which takes in the goal and the
  /// formulas' lines). An empty period keeps a scale of the lead type's (851-3102).
  private func yDomain(
    _ data: CardData, spec: CardSpec, series: [CardData.Series], formulas: [CardData.Formula],
    isEmpty: Bool, unit shown: MetricFormat.DisplayUnit
  ) -> ClosedRange<Double>? {
    let goal = data.goal.map { shown.convert($0) }
    if isEmpty {
      let empty: ClosedRange<Double> =
        if spec.valueUnit == .readings {
          0...10
        } else if let type = spec.leadType.flatMap(HealthCatalog.type(id:)) {
          emptyDomain(
            for: type, unit: type.unit,
            hourly: type.aggregation?.isCumulative == true && data.grain == .hour
          )
          .converted(by: shown)
        } else {
          0...1
        }
      return goal.map { min(empty.lowerBound, $0)...max(empty.upperBound, $0 * 1.1) } ?? empty
    }
    guard spec.chart.style.isAverage else { return nil }
    let values =
      series.flatMap { $0.points.map { shown.convert($0.value) } }
      + formulas.flatMap { $0.points.map { shown.convert($0.value) } } + (goal.map { [$0] } ?? [])
    return fittedDomain(values)
  }

  /// The chart's span, widened to whole buckets: six months' first and last weeks run past them.
  private func domain(_ data: CardData) -> ClosedRange<Date> {
    let component = data.grain.component
    let start = calendar.dateInterval(of: component, for: data.interval.start)?.start
    let end = calendar.dateInterval(
      of: component, for: data.interval.end.addingTimeInterval(-1))?.end
    return (start ?? data.interval.start)...(end ?? data.interval.end)
  }

  // MARK: Hover

  /// The lead's point in the bucket under the pointer, if it has one.
  private func hoveredPoint(in data: CardData) -> LeadPoint? {
    guard let hovered, let bucket = calendar.dateInterval(of: data.grain.component, for: hovered)
    else { return nil }
    if let series = data.series.first(where: { !$0.hidden }) {
      return series.points.first { $0.start == bucket.start }.map {
        LeadPoint(start: $0.start, value: $0.value, minimum: $0.minimum, maximum: $0.maximum)
      }
    }
    return data.leadPoints.first { $0.start == bucket.start }.map {
      LeadPoint(start: $0.start, value: $0.value, minimum: $0.value, maximum: $0.value)
    }
  }
}

/// One of the lead's points, which the header shows on hover.
public struct LeadPoint: Equatable, Sendable {
  public var start: Date
  public var value: Double
  public var minimum: Double
  public var maximum: Double

  public init(start: Date, value: Double, minimum: Double, maximum: Double) {
    self.start = start
    self.value = value
    self.minimum = minimum
    self.maximum = maximum
  }
}
