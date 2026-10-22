public import Foundation
import HealthCatalog
public import SQLiteData

/// How statistics are grouped: by the calendar's hours, days, weeks, months or years.
public enum StatisticsPeriod: Sendable {
  case hour, day, week, month, year

  var component: Calendar.Component {
    switch self {
    case .hour: .hour
    case .day: .day
    case .week: .weekOfYear
    case .month: .month
    case .year: .year
    }
  }
}

/// A cumulative type's total over one period.
public struct CumulativeStatistic: Equatable, Sendable {
  public var start: Date
  public var sum: Double

  public init(start: Date, sum: Double) {
    self.start = start
    self.sum = sum
  }
}

/// A discrete type's samples over one period.
public struct DiscreteStatistic: Equatable, Sendable {
  public var start: Date
  public var average: Double
  public var minimum: Double
  public var maximum: Double
  public var count: Int

  public init(start: Date, average: Double, minimum: Double, maximum: Double, count: Int) {
    self.start = start
    self.average = average
    self.minimum = minimum
    self.maximum = maximum
    self.count = count
  }
}

extension HealthDatabase {
  /// An iPhone that hasn't reported statistics for this long only counts if none has.
  public static let statisticsSourceStaleness: TimeInterval = 14 * 86_400

  /// The longest a sample counts for in a time-weighted average.
  static let maxSampleWeight: TimeInterval = 3600

  /// The iPhone whose statistics the Mac uses (`docs/DECISIONS.md`): of those that reported in
  /// the last 14 days, the one paired with an Apple Watch, then the most recent. If none
  /// reported recently, the most recent of all. Ties go to the higher device ID, so the choice
  /// is stable.
  public static func statisticsSource(_ db: Database, now: Date) throws -> String? {
    let devices = try HealthStatisticsDevice.all.fetchAll(db)
    let recentSince = now.addingTimeInterval(-statisticsSourceStaleness).unixMilliseconds
    let recent = devices.filter { $0.reportedAt >= recentSince }
    guard !recent.isEmpty else {
      return devices.max { ($0.reportedAt, $0.device) < ($1.reportedAt, $1.device) }?.device
    }
    return recent.max { a, b in
      (a.pairedWithWatch ? 1 : 0, a.reportedAt, a.device)
        < (b.pairedWithWatch ? 1 : 0, b.reportedAt, b.device)
    }?.device
  }

  /// The most recent sample of a type, by when it started, of those started by `now` if given.
  public static func latestSample(
    of type: String, startedBy now: Date? = nil, _ db: Database
  ) throws -> HealthSample? {
    let upper = now?.unixMilliseconds ?? .max
    return
      try HealthSample
      .where { $0.type.eq(type) && $0.startDate <= upper }
      .order { $0.startDate.desc() }
      .limit(1)
      .fetchOne(db)
  }

  /// A type's samples that start in `range`, oldest first.
  public static func samples(
    of type: String, in range: Range<Date>, _ db: Database
  ) throws -> [HealthSample] {
    let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
    return
      try HealthSample
      .where { $0.type.eq(type) && $0.startDate >= lower && $0.startDate < upper }
      .order(by: \.startDate)
      .fetchAll(db)
  }

  /// A cumulative type's totals per period in `range`, from the statistics source's 30-minute
  /// buckets. Periods follow `calendar` (the Mac's time zone). Buckets are placed by their
  /// start, so days are exact in whole- and half-hour time zones; in :45 offsets they're off by
  /// up to 15 minutes. Periods without data are left out, and so are empty buckets: the iPhone
  /// sends zeros (up to a day ahead) to overwrite sums that are gone.
  public static func cumulativeStatistics(
    of type: String, in range: Range<Date>, by period: StatisticsPeriod, calendar: Calendar,
    now: Date, _ db: Database
  ) throws -> [CumulativeStatistic] {
    guard let source = try statisticsSource(db, now: now) else { return [] }
    let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
    let buckets =
      try HealthStatistic
      .where {
        $0.device.eq(source) && $0.type.eq(type) && $0.bucketStart >= lower
          && $0.bucketStart < upper && $0.sum > 0
      }
      .order(by: \.bucketStart)
      .select { ($0.bucketStart, $0.sum) }
      .fetchAll(db)
    var periods = Periods(period, calendar)
    var totals: [CumulativeStatistic] = []
    for (bucketStart, sum) in buckets {
      let start = periods.start(of: Date(unixMilliseconds: bucketStart))
      if totals.last?.start == start {
        totals[totals.count - 1].sum += sum
      } else {
        totals.append(CumulativeStatistic(start: start, sum: sum))
      }
    }
    return totals
  }

  /// A discrete type's average, minimum and maximum per period in `range`, from raw samples.
  /// Averages follow the type's aggregation style:
  /// - Arithmetic: a plain average.
  /// - Time-weighted: each sample counts until its source's next sample, up to an hour, and a
  ///   source's last sample for its own duration. Samples up to an hour past the range are
  ///   looked at, so a period's average doesn't depend on the range it's queried with.
  /// - Sound levels: an equivalent continuous level, weighted by duration.
  public static func discreteStatistics(
    of type: String, in range: Range<Date>, by period: StatisticsPeriod, calendar: Calendar,
    _ db: Database
  ) throws -> [DiscreteStatistic] {
    try discreteStatistics(of: type, in: range, periods: Periods(period, calendar), db)
  }

  /// A discrete type's average, minimum and maximum over all of `range`, weighted as
  /// `discreteStatistics(of:in:by:calendar:_:)` weighs each period's. `nil` without samples.
  public static func discreteStatistic(
    of type: String, in range: Range<Date>, _ db: Database
  ) throws -> DiscreteStatistic? {
    try discreteStatistics(of: type, in: range, periods: Periods(whole: range), db).first
  }

  private static func discreteStatistics(
    of type: String, in range: Range<Date>, periods: Periods, _ db: Database
  ) throws -> [DiscreteStatistic] {
    var periods = periods
    let aggregation = HealthCatalog.type(id: type)?.aggregation ?? .discreteArithmetic
    let lower = range.lowerBound.unixMilliseconds
    let upper = range.upperBound.unixMilliseconds
    let reach =
      aggregation == .discreteTemporallyWeighted
      ? range.upperBound.addingTimeInterval(maxSampleWeight).unixMilliseconds : upper
    let rows =
      try HealthSample
      .where { $0.type.eq(type) && $0.startDate >= lower && $0.startDate < reach }
      .order(by: \.startDate)
      .select { ($0.startDate, $0.endDate, $0.value, $0.sourceBundleID) }
      .fetchAll(db)
      .compactMap { start, end, value, source in
        value.map { Reading(start: start, end: end, value: $0, source: source) }
      }
    let weights = Self.weights(of: rows, aggregation)

    var groups: [(start: Date, values: [Double], weights: [Double])] = []
    for (reading, weight) in zip(rows, weights) where reading.start < upper {
      let start = periods.start(of: Date(unixMilliseconds: reading.start))
      if groups.last?.start == start {
        groups[groups.count - 1].values.append(reading.value)
        groups[groups.count - 1].weights.append(weight)
      } else {
        groups.append((start, [reading.value], [weight]))
      }
    }
    return groups.map { group in
      DiscreteStatistic(
        start: group.start,
        average: average(group.values, weights: group.weights, aggregation),
        minimum: group.values.min() ?? 0,
        maximum: group.values.max() ?? 0,
        count: group.values.count)
    }
  }

  private struct Reading {
    let start: Int
    let end: Int
    let value: Double
    let source: String
  }

  /// Each reading's weight in an average, in seconds.
  private static func weights(
    of readings: [Reading], _ aggregation: HealthDataType.Aggregation
  ) -> [Double] {
    switch aggregation {
    case .discreteTemporallyWeighted:
      // Each source is its own series, so a second device's samples don't cut a sample short.
      var weights = [Double](repeating: 1, count: readings.count)
      var nextStart: [String: Int] = [:]
      for index in readings.indices.reversed() {
        let reading = readings[index]
        let until = nextStart[reading.source] ?? reading.end
        weights[index] = min(max(Double(until - reading.start) / 1000, 1), maxSampleWeight)
        nextStart[reading.source] = reading.start
      }
      return weights
    case .discreteEquivalentContinuousLevel:
      return readings.map { max(Double($0.end - $0.start) / 1000, 1) }
    case .cumulative, .discreteArithmetic:
      return readings.map { _ in 1 }
    }
  }

  private static func average(
    _ values: [Double], weights: [Double], _ aggregation: HealthDataType.Aggregation
  ) -> Double {
    let total = weights.reduce(0, +)
    guard total > 0 else { return 0 }
    if aggregation == .discreteEquivalentContinuousLevel {
      let energy = zip(values, weights).reduce(0) { $0 + $1.1 * pow(10, $1.0 / 10) }
      return 10 * log10(energy / total)
    }
    return zip(values, weights).reduce(0) { $0 + $1.0 * $1.1 } / total
  }
}

/// Finds the period a date falls in, asking the calendar only when a date leaves the last one.
private struct Periods {
  let component: Calendar.Component
  let calendar: Calendar
  var current: DateInterval?

  init(_ period: StatisticsPeriod, _ calendar: Calendar) {
    self.component = period.component
    self.calendar = calendar
  }

  /// One period: all of `range`.
  init(whole range: Range<Date>) {
    self.component = .era
    self.calendar = Calendar(identifier: .gregorian)
    current = DateInterval(start: range.lowerBound, end: range.upperBound)
  }

  mutating func start(of date: Date) -> Date {
    if let current, current.start <= date, date < current.end { return current.start }
    current = calendar.dateInterval(of: component, for: date)
    return current?.start ?? date
  }
}
