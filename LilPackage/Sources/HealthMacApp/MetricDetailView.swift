import Charts
import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

/// One metric over a chosen period, as in Health: D, W, M, 6M or Y, earlier periods with the
/// arrows, the period's summary, and a chart whose bars show their value on hover. Follows the
/// local database as sync changes it.
struct MetricDetailView: View {
  let type: HealthDataType
  @State private var range = ChartRange.week
  @State private var offset = 0
  /// Loaded by the view's task, for quantity types only.
  @Fetch private var chart: MetricChart? = nil

  init(type: HealthDataType) {
    self.type = type
  }

  var body: some View {
    Group {
      if type.id == HealthDatabase.sleepType {
        SleepDetailView(type: type)
      } else if type.kind == .workout {
        WorkoutsView()
      } else if type.kind == .electrocardiogram {
        ElectrocardiogramsView()
      } else if type.kind == .audiogram {
        AudiogramsView()
      } else if type.kind == .quantity {
        MetricDetailContent(
          type: type, range: $range, offset: $offset,
          state: $chart.loadError.map { .failed($0.localizedDescription) }
            ?? ($chart.isLoading ? .loading : chart.map { .loaded($0) } ?? .loading))
      } else {
        // Their own views come with their tickets (cycle tracking…).
        ContentUnavailableView(
          type.name, systemImage: type.category?.symbolName ?? "questionmark",
          description: Text("A chart for \(type.name) is coming."))
      }
    }
    .task(id: [range.rawValue, String(offset)]) {
      guard type.kind == .quantity else { return }
      _ = try? await $chart.load(
        MetricChartRequest(typeID: type.id, range: range, offset: offset),
        scheduler: MainQueueScheduler())
    }
  }
}

struct MetricChartRequest: FetchKeyRequest {
  let typeID: String
  let range: ChartRange
  let offset: Int

  func fetch(_ db: Database) throws -> MetricChart? {
    guard let type = HealthCatalog.type(id: typeID) else { return nil }
    return try HealthDatabase.metricChart(
      of: type, range: range, offset: offset, now: .now, calendar: .current, db)
  }
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
  var calendar = Calendar.current
  @SwiftUI.State private var hovered: Date?

  private var color: Color { type.category?.color ?? .accentColor }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // A new range starts at its current period, in the same change, so it loads once.
        Picker("Range", selection: Binding(get: { range }, set: { (range, offset) = ($0, 0) })) {
          ForEach(ChartRange.allCases, id: \.self) { range in
            Text(range.rawValue).tag(range)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        VStack(alignment: .leading, spacing: 12) {
          header
          chartArea
            .frame(height: 280)
        }
        .padding(16)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))

        section("Highlights") {
          Text("Highlights and trends for \(type.name) will appear here.")
            .foregroundStyle(.secondary)
        }
        section("About \(type.name)") {
          Text(
            "\(type.name) comes from your iPhone, Apple Watch and the apps that write it to Health, synced from your iPhone."
          )
          .foregroundStyle(.secondary)
        }
        VStack(spacing: 0) {
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
    .background(Color.groupedBackground)
    .navigationTitle(type.name)
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
      HStack(spacing: 4) {
        Button("Earlier", systemImage: "chevron.left") { offset -= 1 }
        Button("Later", systemImage: "chevron.right") { offset += 1 }
          .disabled(offset >= 0)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
    }
  }

  private func label(_ chart: MetricChart?, point: ChartPoint?) -> String {
    let cumulative = type.aggregation?.isCumulative == true
    if let point {
      if cumulative { return range == .sixMonths || range == .year ? "DAILY AVERAGE" : "TOTAL" }
      return point.minimum == point.maximum ? "AVERAGE" : "RANGE"
    }
    switch chart?.summary {
    case .total: return "TOTAL"
    case .dailyAverage: return "DAILY AVERAGE"
    case .range: return "RANGE"
    case .average: return "AVERAGE"
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
        case nil: nil
        }
      }
    let formatted = values?.map { MetricFormat.value($0, unit: type.unit, typeID: type.id) }
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
    if type.aggregation?.isCumulative == true {
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

  // MARK: Sections

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.title3.bold())
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
  }

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
