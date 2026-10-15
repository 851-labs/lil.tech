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

  /// The iPhone whose statistics the Mac uses (`docs/DECISIONS.md`): of those that reported in
  /// the last 14 days, the one paired with an Apple Watch, then the most recent. If none
  /// reported recently, the most recent of all.
  public static func statisticsSource(_ db: Database, now: Date) throws -> String? {
    let devices = try HealthStatisticsDevice.all.fetchAll(db)
    let recentSince = now.addingTimeInterval(-statisticsSourceStaleness).unixMilliseconds
    let recent = devices.filter { $0.reportedAt >= recentSince }
    guard !recent.isEmpty else { return devices.max { $0.reportedAt < $1.reportedAt }?.device }
    return recent.max { a, b in
      (a.pairedWithWatch ? 1 : 0, a.reportedAt) < (b.pairedWithWatch ? 1 : 0, b.reportedAt)
    }?.device
  }

  /// The most recent sample of a type, by when it ended.
  public static func latestSample(of type: String, _ db: Database) throws -> HealthSample? {
    try HealthSample
      .where { $0.type.eq(type) }
      .order { $0.endDate.desc() }
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
  /// up to 15 minutes. Periods without data are left out.
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
          && $0.bucketStart < upper
      }
      .order(by: \.bucketStart)
      .fetchAll(db)
    var totals: [CumulativeStatistic] = []
    for bucket in buckets {
      let start = periodStart(of: Date(unixMilliseconds: bucket.bucketStart), period, calendar)
      if totals.last?.start == start {
        totals[totals.count - 1].sum += bucket.sum
      } else {
        totals.append(CumulativeStatistic(start: start, sum: bucket.sum))
      }
    }
    return totals
  }

  /// A discrete type's average, minimum and maximum per period in `range`, from raw samples.
  /// Averages follow the type's aggregation style: arithmetic, weighted by time (each sample
  /// counts until the next one, up to an hour, and the last for its own duration), or as an
  /// equivalent continuous sound level.
  public static func discreteStatistics(
    of type: String, in range: Range<Date>, by period: StatisticsPeriod, calendar: Calendar,
    _ db: Database
  ) throws -> [DiscreteStatistic] {
    let samples = try Self.samples(of: type, in: range, db).filter { $0.value != nil }
    let aggregation = HealthCatalog.type(id: type)?.aggregation ?? .discreteArithmetic
    let weights = Self.weights(of: samples, aggregation)

    var groups: [(start: Date, values: [Double], weights: [Double])] = []
    for (sample, weight) in zip(samples, weights) {
      let start = periodStart(of: sample.start, period, calendar)
      let value = sample.value ?? 0
      if groups.last?.start == start {
        groups[groups.count - 1].values.append(value)
        groups[groups.count - 1].weights.append(weight)
      } else {
        groups.append((start, [value], [weight]))
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

  private static func periodStart(
    of date: Date, _ period: StatisticsPeriod, _ calendar: Calendar
  ) -> Date {
    calendar.dateInterval(of: period.component, for: date)?.start ?? date
  }

  /// Each sample's weight in a time-weighted or sound-level average, in seconds.
  private static func weights(
    of samples: [HealthSample], _ aggregation: HealthDataType.Aggregation
  ) -> [Double] {
    switch aggregation {
    case .discreteTemporallyWeighted:
      return samples.indices.map { index in
        let sample = samples[index]
        // The last sample counts for its own duration.
        let until = index + 1 < samples.count ? samples[index + 1].start : sample.end
        return min(max(until.timeIntervalSince(sample.start), 1), 3600)
      }
    case .discreteEquivalentContinuousLevel:
      return samples.map { max($0.end.timeIntervalSince($0.start), 1) }
    case .cumulative, .discreteArithmetic:
      return samples.map { _ in 1 }
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
