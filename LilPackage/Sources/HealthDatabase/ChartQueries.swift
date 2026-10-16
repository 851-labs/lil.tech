public import Foundation
public import HealthCatalog
public import SQLiteData

/// The periods a metric's chart can show, as in Health: a day by the hour, a week or a month by
/// the day, six months by the week, a year by the month. Each follows the calendar (a week
/// starts on its first weekday, a year in January).
public enum ChartRange: String, CaseIterable, Hashable, Sendable {
  case day = "D"
  case week = "W"
  case month = "M"
  case sixMonths = "6M"
  case year = "Y"

  /// What each bar or range covers.
  var bucket: StatisticsPeriod {
    switch self {
    case .day: .hour
    case .week, .month: .day
    case .sixMonths: .week
    case .year: .month
    }
  }

  /// The period `offset` periods from the one containing `now` (0 is the current one, -1 the
  /// one before).
  public func interval(offset: Int, now: Date, calendar: Calendar) -> DateInterval {
    func shifted(_ component: Calendar.Component, _ value: Int) -> DateInterval {
      let base =
        calendar.dateInterval(of: component, for: now) ?? DateInterval(start: now, duration: 0)
      let start = calendar.date(byAdding: component, value: value, to: base.start) ?? base.start
      return calendar.dateInterval(of: component, for: start) ?? base
    }
    switch self {
    case .day: return shifted(.day, offset)
    case .week: return shifted(.weekOfYear, offset)
    case .month: return shifted(.month, offset)
    case .year: return shifted(.year, offset)
    case .sixMonths:
      // The six months ending with the current month, then the six before them.
      let month = shifted(.month, offset * 6)
      let start = calendar.date(byAdding: .month, value: -5, to: month.start) ?? month.start
      return DateInterval(start: start, end: month.end)
    }
  }
}

/// A metric over one period: one point per bucket, and the period's summary.
public struct MetricChart: Equatable, Sendable {
  public var interval: DateInterval
  public var points: [ChartPoint]
  public var summary: Summary?
  public var unit: String?

  public init(
    interval: DateInterval, points: [ChartPoint], summary: Summary?, unit: String?
  ) {
    self.interval = interval
    self.points = points
    self.summary = summary
    self.unit = unit
  }

  /// What the header shows, as Health does.
  public enum Summary: Equatable, Sendable {
    /// A cumulative type's total, for a day.
    case total(Double)
    /// A cumulative type's average per day with data, for longer periods.
    case dailyAverage(Double)
    /// A discrete type's lowest and highest values.
    case range(minimum: Double, maximum: Double)
    /// A discrete type whose values were all the same.
    case average(Double)
  }
}

/// One bucket: its total (cumulative; `minimum` and `maximum` are the same), or its average and
/// range (discrete).
public struct ChartPoint: Equatable, Sendable {
  public var start: Date
  public var value: Double
  public var minimum: Double
  public var maximum: Double

  public init(start: Date, value: Double, minimum: Double? = nil, maximum: Double? = nil) {
    self.start = start
    self.value = value
    self.minimum = minimum ?? value
    self.maximum = maximum ?? value
  }
}

extension HealthDatabase {
  /// A quantity type over the period `offset` periods back. Cumulative types chart totals by
  /// hour or day, and for six months or a year the average day of each week or month; discrete
  /// types chart each bucket's average and range.
  public static func metricChart(
    of type: HealthDataType, range: ChartRange, offset: Int, now: Date, calendar: Calendar,
    _ db: Database
  ) throws -> MetricChart {
    let interval = range.interval(offset: offset, now: now, calendar: calendar)
    let span = interval.start..<interval.end
    guard type.aggregation?.isCumulative == true else {
      let statistics = try discreteStatistics(
        of: type.id, in: span, by: range.bucket, calendar: calendar, db)
      let points = statistics.map {
        ChartPoint(start: $0.start, value: $0.average, minimum: $0.minimum, maximum: $0.maximum)
      }
      var summary: MetricChart.Summary?
      if let low = statistics.map(\.minimum).min(), let high = statistics.map(\.maximum).max() {
        if low == high {
          summary = .average(low)
        } else {
          summary = .range(minimum: low, maximum: high)
        }
      }
      return MetricChart(interval: interval, points: points, summary: summary, unit: type.unit)
    }
    let byDay = range == .sixMonths || range == .year
    let totals = try cumulativeStatistics(
      of: type.id, in: span, by: byDay ? .day : range.bucket, calendar: calendar, now: now, db)
    let total = totals.reduce(0) { $0 + $1.sum }
    var points = totals.map { ChartPoint(start: $0.start, value: $0.sum) }
    if byDay {
      // The average day of each week or month.
      var groups: [(start: Date, sum: Double, days: Int)] = []
      for day in totals {
        let start =
          calendar.dateInterval(of: range.bucket.component, for: day.start)?.start
          ?? day.start
        if groups.last?.start == start {
          groups[groups.count - 1].sum += day.sum
          groups[groups.count - 1].days += 1
        } else {
          groups.append((start, day.sum, 1))
        }
      }
      points = groups.map { ChartPoint(start: $0.start, value: $0.sum / Double($0.days)) }
    }
    let summary: MetricChart.Summary? =
      totals.isEmpty
      ? nil
      : range == .day
        ? .total(total) : .dailyAverage(total / Double(Set(dayStarts(totals, calendar)).count))
    return MetricChart(interval: interval, points: points, summary: summary, unit: type.unit)
  }

  private static func dayStarts(_ totals: [CumulativeStatistic], _ calendar: Calendar) -> [Date] {
    totals.map { calendar.startOfDay(for: $0.start) }
  }
}
