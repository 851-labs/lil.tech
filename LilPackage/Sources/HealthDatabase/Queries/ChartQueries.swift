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

  /// The calendar unit of each bar.
  public var barUnit: Calendar.Component { bucket.component }

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

  public init(interval: DateInterval, points: [ChartPoint], summary: Summary?) {
    self.interval = interval
    self.points = points
    self.summary = summary
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
    /// Sessions' average length in seconds (handwashing, toothbrushing).
    case averageDuration(TimeInterval)
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
      return MetricChart(interval: interval, points: points, summary: summary)
    }
    let byDay = range == .sixMonths || range == .year
    let totals = try cumulativeTotals(
      of: type.id, in: span, by: byDay ? .day : range.bucket, now: now, calendar: calendar, db)
    let total = totals.reduce(0) { $0 + $1.sum }
    var points = totals.map { ChartPoint(start: $0.start, value: $0.sum) }
    if byDay {
      points = averageDays(totals.map { ($0.start, $0.sum) }, by: range, calendar: calendar)
    }
    // Longer periods' totals are one a day.
    let summary: MetricChart.Summary? =
      totals.isEmpty
      ? nil : range == .day ? .total(total) : .dailyAverage(total / Double(totals.count))
    return MetricChart(interval: interval, points: points, summary: summary)
  }

  /// The average day of each of `range`'s buckets (a week for six months, a month for a year),
  /// among `days` (in order) that have a value.
  static func averageDays(
    _ days: [(start: Date, value: Double)], by range: ChartRange, calendar: Calendar
  ) -> [ChartPoint] {
    var groups: [(start: Date, sum: Double, days: Int)] = []
    for day in days {
      let start =
        calendar.dateInterval(of: range.bucket.component, for: day.start)?.start ?? day.start
      if groups.last?.start == start {
        groups[groups.count - 1].sum += day.value
        groups[groups.count - 1].days += 1
      } else {
        groups.append((start, day.value, 1))
      }
    }
    return groups.map { ChartPoint(start: $0.start, value: $0.sum / Double($0.days)) }
  }

  /// A cumulative type's totals per period, from the statistics source's 30-minute buckets and,
  /// past the last of them (no statistics at all, or samples synced before their buckets), the
  /// samples' own totals, as Browse shows them.
  public static func cumulativeTotals(
    of type: String, in range: Range<Date>, by period: StatisticsPeriod, now: Date,
    calendar: Calendar, _ db: Database
  ) throws -> [CumulativeStatistic] {
    let statistics = try cumulativeStatistics(
      of: type, in: range, by: period, calendar: calendar, now: now, db)
    let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
    // Empty buckets don't count as covered: samples that arrived before their sums still show.
    let lastBucket = try statisticsSource(db, now: now).flatMap { source in
      try HealthStatistic
        .where {
          $0.device.eq(source) && $0.type.eq(type) && $0.bucketStart >= lower
            && $0.bucketStart < upper && $0.sum > 0
        }
        .order { $0.bucketStart.desc() }
        .select(\.bucketStart)
        .limit(1)
        .fetchOne(db)
    }
    let covered = lastBucket.map { $0 + 30 * 60_000 } ?? lower
    let samples =
      try HealthSample
      .where { $0.type.eq(type) && $0.startDate >= covered && $0.startDate < upper }
      .select { ($0.startDate, $0.value) }
      .fetchAll(db)
    guard !samples.isEmpty else { return statistics }
    var sums = Dictionary(uniqueKeysWithValues: statistics.map { ($0.start, $0.sum) })
    for (start, value) in samples {
      let date = Date(unixMilliseconds: start)
      let period = calendar.dateInterval(of: period.component, for: date)?.start ?? date
      sums[period, default: 0] += value ?? 0
    }
    return sums.sorted { $0.key < $1.key }.map { CumulativeStatistic(start: $0.key, sum: $0.value) }
  }
}
