public import Foundation
public import SQLiteData

extension HealthDatabase {
  /// The Activity rings of each day in `month` (any day in it, in `calendar`), keyed by the day as
  /// summaries are: `yyyy-MM-dd` in the iPhone's calendar, not shifted to the Mac's time zone.
  public static func activityDays(
    inMonthOf month: Date, calendar: Calendar, _ db: Database
  ) throws -> [String: ActivityDay] {
    let components = calendar.dateComponents([.year, .month], from: month)
    guard let year = components.year, let number = components.month else { return [:] }
    let first = ActivityDay.key(year: year, month: number, day: 1)
    let next =
      number == 12
      ? ActivityDay.key(year: year + 1, month: 1, day: 1)
      : ActivityDay.key(year: year, month: number + 1, day: 1)
    let summaries =
      try HealthActivitySummary
      .where { $0.id >= first && $0.id < next }
      .fetchAll(db)
    return Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, ActivityDay($0)) })
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

  /// A day's key: `2026-10-05`.
  public static func key(year: Int, month: Int, day: Int) -> String {
    String(format: "%04d-%02d-%02d", year, month, day)
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
