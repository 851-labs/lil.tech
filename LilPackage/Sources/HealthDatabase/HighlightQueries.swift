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
  /// The values the chart shows, oldest first: the two weeks' averages for a comparison, each
  /// week's for a trend.
  public var points: [DailyValue]

  public init(
    typeID: String, kind: Kind, current: Double, previous: Double, points: [DailyValue]
  ) {
    self.typeID = typeID
    self.kind = kind
    self.current = current
    self.previous = previous
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
    guard previous != 0 else { return .same }
    let change = (current - previous) / abs(previous)
    let threshold = kind == .week ? HealthDatabase.weekChange : HealthDatabase.trendChange
    if change >= threshold { return .up }
    if change <= -threshold { return .down }
    return .same
  }

  public enum Direction: Equatable, Sendable {
    case up, down, same
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
      if let this = byWeek[0], let last = byWeek[1], this.count >= minimumDaysPerWeek,
        last.count >= minimumDaysPerWeek, let current = average(0...0),
        let previous = average(1...1)
      {
        weekly.append(
          Highlight(
            typeID: id, kind: .week, current: current.value, previous: previous.value,
            points: [
              DailyValue(day: last.map(\.day).min() ?? today, value: previous.value),
              DailyValue(day: this.map(\.day).min() ?? today, value: current.value),
            ]))
      }
      if let recent = average(0...3), recent.weeks >= 3, let earlier = average(4...15),
        earlier.weeks >= 6
      {
        let points = (0...15).reversed().compactMap { week -> DailyValue? in
          guard let values = byWeek[week], !values.isEmpty else { return nil }
          return DailyValue(
            day: values.map(\.day).min() ?? today,
            value: values.map(\.value).reduce(0, +) / Double(values.count))
        }
        let trend = Highlight(
          typeID: id, kind: .trend, current: recent.value, previous: earlier.value, points: points)
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
