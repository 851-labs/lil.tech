import Charts
import ComposableArchitecture
import HealthCards
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import LilUI
import SQLiteData
import SwiftUI

// The full-page card (851-3207, docs/decisions/cards.md, UI › Mac): Metric Detail's page for a
// card. Every card on Summary opens it, the welcome seed's included.

/// A card's page, by its ID, from the account's cards: it follows the card as it's edited or
/// synced, and says so when it's deleted.
struct CardPage: View {
  let store: StoreOf<CardsFeature>
  let id: Card.ID
  /// Whether the local data holds the cards, as Summary asks (`SummaryView`): until it does, no
  /// cards is loading, not a deleted card.
  @Fetch private var holdsCards = false

  init(store: StoreOf<CardsFeature>, id: Card.ID) {
    self.store = store
    self.id = id
    _holdsCards = Fetch(wrappedValue: false, HoldsCardsRequest(), scheduler: MainQueueScheduler())
  }

  /// Whether the cards are still loading, as Summary's section decides it.
  private var isLoading: Bool {
    store.isLoading || store.cards.isEmpty && !holdsCards && $holdsCards.loadError == nil
  }

  var body: some View {
    if let card = store.cards[id: id] {
      CardDetailView(card: card)
    } else if let failure = store.loadFailure {
      ContentUnavailableView(
        "Couldn't Load This Card", systemImage: "exclamationmark.triangle",
        description: Text(failure))
    } else if isLoading {
      // Summary's rows link to the welcome seed's cards while they load.
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .delayedProgress(isLoading: true)
    } else {
      ContentUnavailableView(
        "No Card", systemImage: "rectangle.stack", description: Text("This card was deleted."))
    }
  }
}

/// A card's page: its chart over a period it loads, or, for a card of a later version, that this
/// version can't show it.
struct CardDetailView: View {
  let card: Card

  var body: some View {
    if let spec = card.spec {
      CardChartPage(spec: spec)
        // A new bucket offers other ranges: the page opens again, on the card's own.
        .id(spec.bucket)
    } else {
      CardUnreadableContent(card: card)
    }
  }
}

/// A card of a later version's page: its name, symbol and color, as far as this version can read
/// them, and that it can't show the card.
struct CardUnreadableContent: View {
  let card: Card

  var body: some View {
    let display = card.storedDisplay
    ContentUnavailableView {
      Label(display.name, systemImage: display.symbol)
        .foregroundStyle(display.color ?? .secondary)
    } description: {
      Text("Update lil health to show this card.")
    }
    .navigationTitle(display.name)
  }
}

/// A card over a chosen period, as Metric Detail charts a type: the bucket's ranges and earlier
/// periods in the toolbar, opening on the latest period with data (851-3188), and keeping the
/// period shown while the next loads (851-3084). Follows the local database as sync changes it.
struct CardChartPage: View {
  let spec: CardSpec
  @State private var range: ChartRange
  /// The period shown, or the latest with data before it.
  @State private var offset: Int
  /// Loaded by the view's task, with the period and spec it's for.
  @Fetch private var chart: CardPeriod? = nil

  init(spec: CardSpec) {
    self.spec = spec
    let range = ChartRange(spec.range)
    _range = State(initialValue: range)
    // The lead's type's latest data, read before the page first draws, as Metric Detail's.
    _offset = State(initialValue: spec.leadType.map { range.openingOffset(of: $0) } ?? 0)
  }

  private var request: CardDataRequest {
    CardDataRequest(spec: spec, range: range, offset: offset)
  }

  var body: some View {
    CardDetailContent(spec: spec, range: $range, offset: $offset, state: state)
      .task(id: request) {
        _ = try? await $chart.load(request, scheduler: MainQueueScheduler())
      }
  }

  /// The chart loaded last, updating while it's another period's, or the spec before an edit, or
  /// a load is running.
  private var state: CardDetailContent.State {
    if let error = $chart.loadError { return .failed(error.localizedDescription) }
    guard let chart else { return .loading }
    return .loaded(
      chart,
      isUpdating: $chart.isLoading || chart.range != range || chart.offset != offset
        || chart.spec != spec)
  }
}

/// A card's data over one period, with the range, period and spec it's for, so a page showing it
/// while the next loads draws it as it was loaded.
struct CardPeriod: Equatable, Sendable {
  let range: ChartRange
  /// 0 is the current period, -1 the one before.
  let offset: Int
  let spec: CardSpec
  let data: CardData
}

/// A card over the period `offset` periods from the current one of `range`, from the local
/// database (`HealthDatabase.cardData`).
struct CardDataRequest: FetchKeyRequest {
  let spec: CardSpec
  let range: ChartRange
  let offset: Int

  func fetch(_ db: Database) throws -> CardPeriod? {
    // The dependencies where the fetch started (SQLiteData passes them on), so snapshot
    // catalogs fix them.
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    let period = range.interval(offset: offset, now: now, calendar: calendar)
    let data = try HealthDatabase.cardData(
      spec, range: range.card, date: period.start, now: now, calendar: calendar, db)
    return CardPeriod(range: range, offset: offset, spec: spec, data: data)
  }
}

/// What a card's page shows, however it got it: a grouped form with the header and chart, the
/// legend when it draws more than one line, About This Card, and for a card of one series, its
/// type's Show All Data and Data Sources.
struct CardDetailContent: View {
  enum State {
    /// Nothing to show yet: placeholders take the loaded page's space (851-3084).
    case loading
    /// A period's data. Updating while another period, or the same one again, loads: it stays on
    /// screen, with a spinner, rather than the page blanking.
    case loaded(CardPeriod, isUpdating: Bool = false)
    case failed(String)

    var isLoading: Bool {
      if case .loading = self { true } else { false }
    }
  }

  let spec: CardSpec
  /// The period chosen in the toolbar, which can be ahead of the one shown.
  @Binding private var selectedRange: ChartRange
  @Binding private var selectedOffset: Int
  let state: State
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.calendar) private var calendar
  @Dependency(\.date.now) private var now
  /// Whose units values are shown in (851-3116).
  @Dependency(\.locale) private var locale
  @SwiftUI.State private var hovered: Date?

  init(spec: CardSpec, range: Binding<ChartRange>, offset: Binding<Int>, state: State) {
    self.spec = spec
    _selectedRange = range
    _selectedOffset = offset
    self.state = state
  }

  /// The loaded period, which stays while another loads.
  private var loaded: CardPeriod? {
    if case .loaded(let loaded, _) = state { loaded } else { nil }
  }

  /// The spec drawn: the one its data was loaded for, which an edit replaces once it loads.
  private var shownSpec: CardSpec { loaded?.spec ?? spec }

  /// The period shown: the loaded one's, or the one chosen before any has loaded.
  private var range: ChartRange { loaded?.range ?? selectedRange }
  private var offset: Int { loaded?.offset ?? selectedOffset }

  private var isUpdating: Bool {
    if case .loaded(_, let isUpdating) = state { isUpdating } else { false }
  }

  private var color: Color { Color(paletteName: shownSpec.display.color.rawValue) }

  /// What values are shown and plotted in: the card's pinned unit, or the locale's for its lead.
  private var displayUnit: MetricFormat.DisplayUnit {
    MetricFormat.unit(of: shownSpec, locale: locale)
  }

  /// The one type a card of one series charts, whose data it can show.
  private var singleType: HealthDataType? {
    spec.series.count == 1 ? spec.series.first?.dataType : nil
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          header
          chartArea
            .delayedProgress(isLoading: state.isLoading)
            .frame(height: 280)
          // The spec's, not the loaded data's, so it's there while the chart loads.
          let legend = spec.legend
          if !legend.isEmpty {
            CardLegend(lines: legend, color: Color(paletteName: spec.display.color.rawValue))
          }
        }
        .padding(.vertical, 6)
      }
      Section("About This Card") {
        Text(spec.about)
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutAnchor("About This Card")
      }
      if let type = singleType {
        Section {
          NavigationLink("Show All Data") {
            AllDataView(type: type)
          }
          NavigationLink("Data Sources") {
            DataSourcesView(type: type)
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(spec.display.name)
    // Only the bucket's ranges, in the toolbar, with ‹ Today › and the View menu's commands.
    .periodControls(
      PagePeriod(
        range: $selectedRange, offset: $selectedOffset,
        ranges: spec.bucket.ranges.map(ChartRange.init), now: now, calendar: calendar))
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
            ?? ChartFormat.span(
              loaded?.data.interval ?? range.interval(offset: offset, now: now, calendar: calendar),
              range: range, calendar: calendar)
        )
        .foregroundStyle(.secondary)
      }
      Spacer()
    }
    // While another period loads, over the one shown.
    .updatingIndicator(isUpdating)
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
  nonisolated static func caption(
    for spec: CardSpec, range: ChartRange, summary: CardSummary?, point: LeadPoint?
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
      default:
        return caption(of: expectedKind(of: spec, range: range))
      }
    }
    return caption(of: summary?.kind ?? expectedKind(of: spec, range: range))
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

  /// The summary a period of `range` has when it has data (docs/decisions/cards.md, Summary and
  /// headline): a range of readings for an average drawn as ranges, which may turn out to be an
  /// average.
  nonisolated static func expectedKind(of spec: CardSpec, range: ChartRange) -> CardSummary.Kind {
    guard case .series(let series) = spec.lead else { return .average }
    switch series.aggregation {
    case .sum:
      switch (spec.bucket, range) {
      case (.auto, .day): return .total
      case (.auto, .sixMonths), (.auto, .year): return .dailyAverage
      case (.auto, _): return .average
      // A night is the only fixed bucket a period can hold one of.
      case (.night, .day): return .total
      default: return .average
      }
    case .avg: return spec.chart.style == .ranges ? .range : .average
    case .min: return .lowest
    case .max: return .highest
    case .first: return .first
    case .latest: return .latest
    case .count: return .count
    }
  }

  /// A point's bucket, as the header dates it: "Aug 13, 3 PM", "Tue, Aug 13", "Night of Aug 13"
  /// (a night is named by the day it ends on), "Week of Aug 4", "August 2024".
  nonisolated static func bucket(
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
      label: ChartFormat.noData(ChartFormat.span(data.interval, range: range, calendar: calendar)))
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
struct LeadPoint: Equatable {
  var start: Date
  var value: Double
  var minimum: Double
  var maximum: Double
}
