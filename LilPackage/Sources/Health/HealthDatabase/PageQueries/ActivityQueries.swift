public import Foundation
public import SQLiteData

extension HealthDatabase {
  /// The Activity rings of each day in `interval` (days in `calendar`, which may not be
  /// Gregorian), keyed by the day as summaries are: its Gregorian `yyyy-MM-dd`, the iPhone's day,
  /// not shifted to the Mac's time zone.
  public static func activityDays(
    in interval: DateInterval, calendar: Calendar, _ db: Database
  ) throws -> [String: ActivityDay] {
    let first = ActivityDay.key(for: interval.start, calendar: calendar)
    let next = ActivityDay.key(for: interval.end, calendar: calendar)
    let summaries =
      try HealthActivitySummary
      .where { $0.id >= first && $0.id < next }
      .fetchAll(db)
    return Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, ActivityDay($0)) })
  }

  /// The latest day with Activity rings up to `now`, to open on its month.
  public static func latestActivityDay(by now: Date, calendar: Calendar, _ db: Database) throws
    -> Date?
  {
    let today = ActivityDay.key(for: now, calendar: calendar)
    let latest =
      try HealthActivitySummary
      .where { $0.id <= today }
      .select { $0.id.max() }
      .fetchOne(db)
      .flatMap { $0 }
    return latest.flatMap { gregorianDay($0, calendar: calendar) }
  }
}

/// A day's Activity rings: Move, and Exercise and Stand when an Apple Watch recorded them.
public struct ActivityDay: Equatable, Sendable {
  /// The day, `yyyy-MM-dd`.
  public var id: String
  public var move: ActivityRing
  /// Move in minutes rather than kilocalories (the Move mode of those without a set calorie goal,
  /// such as children).
  public var movesInMinutes: Bool
  /// Nil without a goal, as without an Apple Watch.
  public var exercise: ActivityRing?
  public var stand: ActivityRing?
  public var isPaused: Bool

  public init(
    id: String, move: ActivityRing, movesInMinutes: Bool = false, exercise: ActivityRing?,
    stand: ActivityRing?, isPaused: Bool = false
  ) {
    self.id = id
    self.move = move
    self.movesInMinutes = movesInMinutes
    self.exercise = exercise
    self.stand = stand
    self.isPaused = isPaused
  }

  init(_ summary: HealthActivitySummary) {
    let minutes = summary.activityMoveMode == "appleMoveTime"
    self.init(
      id: summary.id,
      move: minutes
        ? ActivityRing(value: summary.appleMoveTime, goal: summary.appleMoveTimeGoal)
        : ActivityRing(value: summary.activeEnergyBurned, goal: summary.activeEnergyBurnedGoal),
      movesInMinutes: minutes,
      exercise: ActivityRing(
        ifGoal: summary.appleExerciseTimeGoal, value: summary.appleExerciseTime),
      stand: ActivityRing(ifGoal: summary.appleStandHoursGoal, value: summary.appleStandHours),
      isPaused: summary.paused == true)
  }

  /// A day's key: its Gregorian date (`2026-10-05`) in `calendar`'s time zone, as the iPhone
  /// keys summaries whatever its calendar.
  public static func key(for date: Date, calendar: Calendar) -> String {
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    let parts = gregorian.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
}

/// One ring: how far it got, and its goal.
public struct ActivityRing: Equatable, Sendable {
  public var value: Double
  public var goal: Double

  public init(value: Double, goal: Double) {
    self.value = value
    self.goal = goal
  }

  init(value: Double?, goal: Double?) {
    self.init(value: value ?? 0, goal: goal ?? 0)
  }

  /// Nil without a goal.
  init?(ifGoal goal: Double?, value: Double?) {
    guard let goal, goal > 0 else { return nil }
    self.init(value: value ?? 0, goal: goal)
  }

  /// How much of the goal it reached: past 1 when it was passed.
  public var progress: Double { goal > 0 ? max(value, 0) / goal : 0 }
}
