import Charts
public import Foundation
public import HealthCards
public import HealthCatalog
public import SwiftUI

/// A week at a glance, in the type's chart style, as iPad Health's rows draw it (851-3101): the
/// days in gray and the latest in `color`. Bars are each day's total, from 0 (or below it, for
/// values that are); ranges its lowest to its highest reading, and dots and a line through them
/// its average, on an axis fitted to them, as Metric Detail's are (`fittedDomain`), the line's
/// latest a hollow circle. Always the whole week, its latest day at the right, however few days
/// have data.
///
/// A card's (851-3206) draws its buckets the same way, whatever they are (hours, days or nights,
/// weeks, months), over the 7 its headline covers: its first visible series as a metric's days,
/// any other visible series in gray at their opacities with dots of their shapes
/// (`CardSeriesMark`), and its formulas as lines in `color` over them.
public struct Sparkline: View {
  /// The lead's points: the days of a metric, the buckets of a card's first visible series.
  public let points: [SparklinePoint]
  /// A card's other visible series, in order.
  public var otherSeries: [SparklineSeries] = []
  /// A card's visible formulas, each a line, in order.
  public var formulas: [[SparklinePoint]] = []
  public let style: HealthDataType.ChartStyle
  public let color: Color
  /// What the chart spans: the week, or a card's 7 buckets.
  public let domain: ClosedRange<Date>
  /// What one point covers.
  public let unit: Calendar.Component

  /// A metric's days, or a card's headline buckets.
  public init(
    points: [SparklinePoint], otherSeries: [SparklineSeries] = [],
    formulas: [[SparklinePoint]] = [], style: HealthDataType.ChartStyle, color: Color,
    domain: ClosedRange<Date>, unit: Calendar.Component
  ) {
    self.points = points
    self.otherSeries = otherSeries
    self.formulas = formulas
    self.style = style
    self.color = color
    self.domain = domain
    self.unit = unit
  }

  /// The days before the latest.
  private static let gray = Color.gray.opacity(0.55)

  public var body: some View {
    Chart {
      // Under the lead's capsules, dots and line, so they never hide its latest; over its bars.
      if style != .bars { otherSeriesMarks }
      ForEach(points, id: \.start) { point in
        leadMarks(point, isLatest: point.start == points.last?.start)
      }
      if style == .bars { otherSeriesMarks }
      ForEach(formulas.indices, id: \.self) { index in
        ForEach(formulas[index], id: \.start) { point in
          LineMark(
            x: .value("Day", point.start, unit: unit), y: .value("Value", point.value),
            series: .value("Line", "formula \(index)")
          )
          .foregroundStyle(color)
          .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
      }
    }
    .chartXScale(domain: domain)
    .chartYScale(domain: yDomain)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
  }

  @ChartContentBuilder
  private func leadMarks(_ point: SparklinePoint, isLatest: Bool) -> some ChartContent {
    switch style {
    case .bars:
      BarMark(x: .value("Day", point.start, unit: unit), y: .value("Value", point.value))
        .foregroundStyle(isLatest ? color : Self.gray)
    case .ranges:
      // A capsule from the lowest to the highest reading: a dot for a day of one.
      RuleMark(
        x: .value("Day", point.start, unit: unit),
        yStart: .value("Lowest", point.minimum ?? point.value),
        yEnd: .value("Highest", point.maximum ?? point.value)
      )
      .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
      .foregroundStyle(isLatest ? color : Self.gray)
    case .dots:
      PointMark(x: .value("Day", point.start, unit: unit), y: .value("Value", point.value))
        .foregroundStyle(isLatest ? color : Self.gray)
        .symbolSize(30)
    case .line:
      LineMark(x: .value("Day", point.start, unit: unit), y: .value("Value", point.value))
        .foregroundStyle(Self.gray)
        .lineStyle(StrokeStyle(lineWidth: 2))
      PointMark(x: .value("Day", point.start, unit: unit), y: .value("Value", point.value))
        .symbol {
          if isLatest {
            // Hollow: the row's fill inside, over the line.
            Circle()
              .strokeBorder(color, lineWidth: 2)
              .background(Circle().fill(.background.secondary))
              .frame(width: 9, height: 9)
          } else {
            Circle()
              .fill(Self.gray)
              .frame(width: 4.5, height: 4.5)
          }
        }
    }
  }

  private var otherSeriesMarks: some ChartContent {
    ForEach(otherSeries) { series in
      ForEach(series.points, id: \.start) { point in
        otherMarks(point, of: series)
      }
    }
  }

  /// Another series' point, in gray at its opacity: a thinner capsule for ranges, else a dot of
  /// its shape. Bars get dots too, at each total, since bars at the same place would stack.
  @ChartContentBuilder
  private func otherMarks(_ point: SparklinePoint, of series: SparklineSeries) -> some ChartContent
  {
    let gray = Color.gray.opacity(0.55 * series.mark.opacity)
    switch style {
    case .ranges:
      RuleMark(
        x: .value("Day", point.start, unit: unit),
        yStart: .value("Lowest", point.minimum ?? point.value),
        yEnd: .value("Highest", point.maximum ?? point.value)
      )
      .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
      .foregroundStyle(gray)
    case .bars, .dots, .line:
      PointMark(x: .value("Day", point.start, unit: unit), y: .value("Value", point.value))
        .symbol { CardSeriesSymbol(mark: series.mark).fill(gray).frame(width: 5, height: 5) }
    }
  }

  private var yDomain: ClosedRange<Double> {
    let all = points + otherSeries.flatMap(\.points)
    let lines = formulas.flatMap { $0.map(\.value) }
    switch style {
    case .bars:
      // The highest at the top: a sparkline has no axis to round up to.
      let values = all.map(\.value) + lines
      let low = min(values.min() ?? 0, 0)
      let high = max(values.max() ?? 0, 0)
      return low...(high > low ? high : low + 1)
    case .ranges:
      // Fitted, unlike the page's from 0: a sound level's 60–75 dB would be a sliver at the top.
      return fittedDomain(
        all.flatMap { [$0.minimum ?? $0.value, $0.maximum ?? $0.value] } + lines) ?? 0...1
    case .dots, .line:
      return fittedDomain(all.map(\.value) + lines) ?? 0...1
    }
  }
}

/// One point of a sparkline: a day, or a card's bucket.
public struct SparklinePoint: Equatable, Sendable {
  public var start: Date
  public var value: Double
  /// The lowest and highest readings, for ranges; `nil` for totals.
  public var minimum: Double?
  public var maximum: Double?

  public init(start: Date, value: Double, minimum: Double? = nil, maximum: Double? = nil) {
    self.start = start
    self.value = value
    self.minimum = minimum
    self.maximum = maximum
  }
}

/// A card's series after its first visible one, in a sparkline.
public struct SparklineSeries: Identifiable, Sendable {
  public let id: String
  public let mark: CardSeriesMark
  public let points: [SparklinePoint]

  public init(id: String, mark: CardSeriesMark, points: [SparklinePoint]) {
    self.id = id
    self.mark = mark
    self.points = points
  }
}
