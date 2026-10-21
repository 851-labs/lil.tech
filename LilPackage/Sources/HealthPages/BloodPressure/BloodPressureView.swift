import Charts
import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// Blood Pressure, as in Health (851-2832): systolic and diastolic together over D, W, M, 6M or Y,
/// each reading a bar from diastolic to systolic (a day or a week) or each period's range of each,
/// the period's average and range, and its readings. Follows the local database as sync changes
/// it. Systolic and Diastolic keep their own pages.
public struct BloodPressureView: View {
  @State private var range = ChartRange.week
  @State private var offset = 0
  /// Moves at midnight, so the periods do.
  @State private var today = Date.now
  @Fetch private var chart: BloodPressureChart? = nil

  public init() {}

  public var body: some View {
    let interval = range.interval(offset: offset, now: today, calendar: .current)
    BloodPressureContent(
      range: $range, offset: $offset,
      state: $chart.loadError.map { .failed($0.localizedDescription) }
        ?? {
          // The period being loaded, not the one before it, drawn as the new range.
          guard let chart, chart.interval == interval else { return .loading }
          return .loaded(chart)
        }()
    )
    .task(id: [range.rawValue, String(offset), today.formatted(.iso8601)]) {
      _ = try? await $chart.load(
        BloodPressureRequest(range: range, offset: offset, now: today),
        scheduler: MainQueueScheduler())
    }
    .onReceive(calendarDayChanges()) {
      today = .now
    }
  }
}

struct BloodPressureRequest: FetchKeyRequest {
  let range: ChartRange
  let offset: Int
  /// The day it's for, so a new day is a new request.
  let now: Date

  func fetch(_ db: Database) throws -> BloodPressureChart? {
    try HealthDatabase.bloodPressureChart(
      range: range, offset: offset, now: now, calendar: .current, db)
  }
}

/// What Blood Pressure shows, however it got it.
struct BloodPressureContent: View {
  enum State {
    case loading
    case loaded(BloodPressureChart)
    case failed(String)
  }

  @Binding var range: ChartRange
  @Binding var offset: Int
  let state: State
  var calendar = Calendar.current
  @SwiftUI.State private var hovered: Date?

  static let systolicColor = Color.red
  static let diastolicColor = Color.red.opacity(0.45)
  /// How many of the period's readings the list shows.
  static let readingLimit = 100

  private var chart: BloodPressureChart? {
    if case .loaded(let chart) = state { chart } else { nil }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 12) {
          header
          chartArea
            .frame(height: 280)
          HStack(spacing: 16) {
            legend("Systolic", Self.systolicColor)
            legend("Diastolic", Self.diastolicColor)
          }
        }
        .padding(16)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        if let chart, !chart.readings.isEmpty {
          readings(chart.readings)
        }
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .background(Color.pageBackground)
    .navigationTitle("Blood Pressure")
    .periodControls(PagePeriod(range: $range, offset: $offset))
  }

  // MARK: Header

  private var header: some View {
    let point = chart.flatMap { hoveredPoint(in: $0) }
    let readings = point?.readings ?? chart?.readings ?? []
    let shown = BloodPressureChart(
      interval: chart?.interval ?? DateInterval(), points: [], readings: readings)
    return VStack(alignment: .leading, spacing: 2) {
      Text("AVERAGE")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        Text(
          shown.average.map { BloodPressureFormat.pair($0.systolic, $0.diastolic) }
            ?? (chart == nil ? "–" : "No Data")
        )
        .monospacedDigit()
        .font(.system(.largeTitle, design: .rounded).bold())
        .foregroundStyle(shown.average == nil ? .secondary : .primary)
        if shown.average != nil {
          Text("mmHg")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
        }
      }
      if let span = BloodPressureFormat.span(shown.span) {
        Text("Range \(span)")
          .foregroundStyle(.secondary)
      }
      Text(
        point.map { point in
          // A reading (a day or a week) by its time, a bucket by its period.
          range == .day || range == .week
            ? point.start.formatted(Self.time(calendar))
            : ChartFormat.bucket(point.start, range: range, calendar: calendar)
        }
          ?? ChartFormat.span(
            chart?.interval ?? range.interval(offset: offset, now: .now, calendar: calendar),
            range: range, calendar: calendar)
      )
      .foregroundStyle(.secondary)
    }
  }

  private func legend(_ name: String, _ color: Color) -> some View {
    Label {
      Text(name)
    } icon: {
      Circle().fill(color).frame(width: 8, height: 8)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  // MARK: Chart

  @ViewBuilder private var chartArea: some View {
    switch state {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load Blood Pressure", systemImage: "exclamationmark.triangle",
        description: Text(reason))
    case .loaded(let chart):
      let perReading = range == .day || range == .week
      Chart {
        ForEach(Array(chart.points.enumerated()), id: \.offset) { _, point in
          if perReading {
            reading(point)
          } else {
            bucket(point)
          }
        }
      }
      .chartXScale(domain: domain(chart))
      .chartYScale(domain: .automatic(includesZero: false))
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
      .overlay {
        if chart.points.isEmpty {
          Text("No Data")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// A reading: a bar from diastolic to systolic, or a point for the one it has.
  @ChartContentBuilder
  private func reading(_ point: BloodPressurePoint) -> some ChartContent {
    let x = PlottableValue.value("Time", point.start)
    if let systolic = point.systolic?.upperBound, let diastolic = point.diastolic?.lowerBound {
      BarMark(
        x: x, yStart: .value("Diastolic", diastolic), yEnd: .value("Systolic", systolic),
        width: .fixed(6)
      )
      .clipShape(Capsule())
      .foregroundStyle(
        .linearGradient(
          colors: [Self.diastolicColor, Self.systolicColor], startPoint: .bottom,
          endPoint: .top))
    } else if let systolic = point.systolic?.upperBound {
      PointMark(x: x, y: .value("Systolic", systolic))
        .foregroundStyle(Self.systolicColor)
    } else if let diastolic = point.diastolic?.lowerBound {
      PointMark(x: x, y: .value("Diastolic", diastolic))
        .foregroundStyle(Self.diastolicColor)
    }
  }

  /// A day's, week's or month's range of each, side by side.
  @ChartContentBuilder
  private func bucket(_ point: BloodPressurePoint) -> some ChartContent {
    let x = PlottableValue.value("Date", point.start, unit: range.barUnit)
    if let systolic = point.systolic {
      BarMark(
        x: x, yStart: .value("Lowest", systolic.lowerBound - Self.pad(systolic)),
        yEnd: .value("Highest", systolic.upperBound + Self.pad(systolic)), width: .fixed(5)
      )
      .clipShape(Capsule())
      .foregroundStyle(Self.systolicColor)
      .position(by: .value("Value", "Systolic"))
    }
    if let diastolic = point.diastolic {
      BarMark(
        x: x, yStart: .value("Lowest", diastolic.lowerBound - Self.pad(diastolic)),
        yEnd: .value("Highest", diastolic.upperBound + Self.pad(diastolic)), width: .fixed(5)
      )
      .clipShape(Capsule())
      .foregroundStyle(Self.diastolicColor)
      .position(by: .value("Value", "Diastolic"))
    }
  }

  /// A reading's day and time, in the view's calendar.
  static func time(_ calendar: Calendar) -> Date.FormatStyle {
    Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
      .month(.abbreviated).day().year().hour().minute()
  }

  /// How far past its ends to draw a range, so one reading is a short bar, not a dot.
  static func pad(_ range: ClosedRange<Double>) -> Double {
    range.upperBound - range.lowerBound < 3 ? 1.5 : 0
  }

  private var axisFormat: Date.FormatStyle {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    switch range {
    case .day: return style.hour()
    case .week, .month: return style.month(.abbreviated).day()
    case .sixMonths, .year: return style.month(.abbreviated)
    }
  }

  /// The chart's span, widened to whole buckets for longer periods.
  private func domain(_ chart: BloodPressureChart) -> ClosedRange<Date> {
    guard range != .day, range != .week else { return chart.interval.start...chart.interval.end }
    let start = calendar.dateInterval(of: range.barUnit, for: chart.interval.start)?.start
    let end = calendar.dateInterval(
      of: range.barUnit, for: chart.interval.end.addingTimeInterval(-1))?.end
    return (start ?? chart.interval.start)...(end ?? chart.interval.end)
  }

  /// The point under the pointer: its bucket, or the reading nearest it within its bucket.
  private func hoveredPoint(in chart: BloodPressureChart) -> BloodPressurePoint? {
    guard let hovered, let bar = calendar.dateInterval(of: range.barUnit, for: hovered)
    else { return nil }
    if range == .day || range == .week {
      return chart.points.filter { bar.contains($0.start) }
        .min { abs($0.start.timeIntervalSince(hovered)) < abs($1.start.timeIntervalSince(hovered)) }
    }
    return chart.points.first { $0.start == bar.start }
  }

  // MARK: Readings

  private func readings(_ readings: [BloodPressureReading]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Readings")
        .font(.title3.bold())
      VStack(spacing: 0) {
        ForEach(Array(readings.prefix(Self.readingLimit).enumerated()), id: \.element.id) {
          index, reading in
          if index > 0 { Divider().padding(.leading, 14) }
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(BloodPressureFormat.pair(reading.systolic, reading.diastolic))
                  .font(.body.weight(.semibold))
                  .monospacedDigit()
                Text("mmHg")
                  .font(.callout)
                  .foregroundStyle(.secondary)
              }
              Text(reading.sourceName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(reading.date.formatted(Self.time(calendar)))
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
        }
      }
      .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
      if readings.count > Self.readingLimit {
        Text("Showing the \(Self.readingLimit) most recent readings in this period.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
      }
    }
  }
}

/// How blood pressure reads: "121/79", with "–" for a missing value.
enum BloodPressureFormat {
  static func pair(_ systolic: Double?, _ diastolic: Double?) -> String {
    "\(number(systolic))/\(number(diastolic))"
  }

  /// "110–135/70–88", for the header's range.
  static func span(
    _ span: (systolic: ClosedRange<Double>?, diastolic: ClosedRange<Double>?)
  ) -> String? {
    guard span.systolic != nil || span.diastolic != nil else { return nil }
    func text(_ range: ClosedRange<Double>?) -> String {
      guard let range else { return "–" }
      // As written: 119.8 and 120.3 are both 120.
      let (low, high) = (number(range.lowerBound), number(range.upperBound))
      return low == high ? low : "\(low)–\(high)"
    }
    return "\(text(span.systolic))/\(text(span.diastolic))"
  }

  private static func number(_ value: Double?) -> String {
    value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "–"
  }
}
