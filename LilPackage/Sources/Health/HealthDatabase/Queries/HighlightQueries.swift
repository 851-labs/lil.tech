public import Foundation
import HealthCatalog
public import SQLiteData

/// Something worth pointing out about a metric, as Summary's highlights do in Health.
public struct Highlight: Equatable, Identifiable, Sendable {
  public var id: String { "\(typeID)/\(kind)" }
  public var typeID: String
  public var kind: Kind
  /// The recent period's average day (cumulative types) or average (discrete types).
  public var current: Double
  /// The earlier period's, to compare with.
  public var previous: Double
  /// When the recent period starts: 7 days ago for a week, 28 for a trend.
  public var recentStart: Date
  /// A trend's weekly averages, oldest first, each dated at its week's start (weeks of 7 days
  /// ending yesterday, not calendar weeks). Weeks without data are left out. Empty for a week.
  public var points: [DailyValue]

  public init(
    typeID: String, kind: Kind, current: Double, previous: Double, recentStart: Date,
    points: [DailyValue] = []
  ) {
    self.typeID = typeID
    self.kind = kind
    self.current = current
    self.previous = previous
    self.recentStart = recentStart
    self.points = points
  }

  public enum Kind: String, Equatable, Sendable {
    /// The last 7 days against the 7 before.
    case week
    /// The last 4 weeks against the 12 before.
    case trend
  }

  /// Whether `current` is meaningfully above or below `previous`.
  public var direction: Direction {
    Direction(
      from: previous, to: current,
      threshold: kind == .week ? HealthDatabase.weekChange : HealthDatabase.trendChange)
  }

  public enum Direction: Equatable, Sendable {
    case up, down, same

    /// Up or down from `previous` to `current` by `threshold` (a share of `previous`) or more,
    /// otherwise about the same. Summary's highlights and Sleep's month comparison (851-3109).
    init(from previous: Double, to current: Double, threshold: Double) {
      // From nothing, anything is a change.
      guard previous != 0 else {
        self = current > 0 ? .up : current < 0 ? .down : .same
        return
      }
      let change = (current - previous) / abs(previous)
      self = change >= threshold ? .up : change <= -threshold ? .down : .same
    }
  }
}

extension HealthDatabase {
  /// The metrics Summary highlights, in order: the everyday ones most iPhones and Watches
  /// record, where a change over weeks means something.
  public static let highlightedTypes = [
    "HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierActiveEnergyBurned",
    "HKQuantityTypeIdentifierDistanceWalkingRunning", "HKQuantityTypeIdentifierAppleExerciseTime",
    "HKQuantityTypeIdentifierRestingHeartRate", "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    "HKQuantityTypeIdentifierBodyMass",
  ]

  /// The rules, per highlighted metric:
  /// - **Week:** the 7 full days before today against the 7 before them, if each week has data
  ///   on at least `minimumDaysPerWeek` days. Today is left out: it isn't over, which would make
  ///   cumulative types look low. A change under 5% reads as about the same.
  /// - **Trend:** the last 4 weeks' average day against the 12 weeks before, if at least 3 of
  ///   the 4 and 6 of the 12 have data. Only a change of 10% or more is a trend; otherwise
  ///   there's no trend highlight.
  /// - Averages are per day with data: totals for cumulative types, daily averages for discrete
  ///   ones (`metricChart`'s statistics).
  public static func highlights(now: Date, calendar: Calendar, _ db: Database) throws
    -> [Highlight]
  {
    let today = calendar.startOfDay(for: now)
    guard let start = calendar.date(byAdding: .day, value: -16 * 7, to: today) else { return [] }
    var weekly: [Highlight] = []
    var trends: [Highlight] = []
    for id in highlightedTypes {
      guard let type = HealthCatalog.type(id: id) else { continue }
      let days = try dailyValues(of: type, in: start..<today, now: now, calendar: calendar, db)
      // Weeks ending yesterday: 0 is the last 7 days, 1 the 7 before, and so on.
      let byWeek = Dictionary(grouping: days) { day in
        ((calendar.dateComponents([.day], from: day.day, to: today).day ?? 1) - 1) / 7
      }
      func average(_ weeks: ClosedRange<Int>) -> (value: Double, weeks: Int)? {
        let values = weeks.flatMap { byWeek[$0] ?? [] }.map(\.value)
        let covered = weeks.filter { !(byWeek[$0] ?? []).isEmpty }.count
        guard !values.isEmpty else { return nil }
        return (values.reduce(0, +) / Double(values.count), covered)
      }
      /// The start of the week `week` weeks back.
      func weekStart(_ week: Int) -> Date {
        calendar.date(byAdding: .day, value: -7 * (week + 1), to: today) ?? today
      }
      if let this = byWeek[0], let last = byWeek[1], this.count >= minimumDaysPerWeek,
        last.count >= minimumDaysPerWeek
      {
        let mean = { (days: [DailyValue]) in days.map(\.value).reduce(0, +) / Double(days.count) }
        weekly.append(
          Highlight(
            typeID: id, kind: .week, current: mean(this), previous: mean(last),
            recentStart: weekStart(0)))
      }
      if let recent = average(0...3), recent.weeks >= 3, let earlier = average(4...15),
        earlier.weeks >= 6
      {
        let points = (0...15).reversed().compactMap { week -> DailyValue? in
          guard let values = byWeek[week], !values.isEmpty else { return nil }
          return DailyValue(
            day: weekStart(week), value: values.map(\.value).reduce(0, +) / Double(values.count))
        }
        let trend = Highlight(
          typeID: id, kind: .trend, current: recent.value, previous: earlier.value,
          recentStart: weekStart(3), points: points)
        if trend.direction != .same { trends.append(trend) }
      }
    }
    return trends + weekly
  }

  /// Days of data a week needs to be compared.
  static let minimumDaysPerWeek = 3
  /// The smallest change between weeks that isn't "about the same".
  static let weekChange = 0.05
  /// The smallest change that makes a trend.
  static let trendChange = 0.1

  /// One value a day: the day's total for cumulative types, its average for discrete ones.
  private static func dailyValues(
    of type: HealthDataType, in range: Range<Date>, now: Date, calendar: Calendar, _ db: Database
  ) throws -> [DailyValue] {
    if type.aggregation?.isCumulative == true {
      return try cumulativeTotals(
        of: type.id, in: range, by: .day, now: now, calendar: calendar, db
      )
      .map { DailyValue(day: $0.start, value: $0.sum) }
    }
    return try discreteStatistics(of: type.id, in: range, by: .day, calendar: calendar, db)
      .map { DailyValue(day: $0.start, value: $0.average) }
  }
}
