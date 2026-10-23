public import Foundation

/// The last 7 nights' average time asleep (851-3111), with each night's: the nights ending today,
/// a day's sleep left out (`SleepNight.latestBedtime`).
public struct SleepWeekAverage: Equatable, Sendable {
  public struct Night: Equatable, Sendable {
    /// The start of the night's day.
    public var day: Date
    public var asleep: TimeInterval

    public init(day: Date, asleep: TimeInterval) {
      self.day = day
      self.asleep = asleep
    }
  }

  /// The first of the 7 days, the last being today.
  public let firstDay: Date
  /// The nights with sleep, oldest first.
  public let nights: [Night]
  /// Their average time asleep.
  public let average: TimeInterval

  /// `nights` can't be empty: there'd be no average.
  public init(firstDay: Date, nights: [Night]) {
    precondition(!nights.isEmpty, "A week's average needs a night.")
    self.firstDay = firstDay
    self.nights = nights
    average = nights.reduce(0) { $0 + $1.asleep } / Double(nights.count)
  }

  /// The days it looks back over, ending today.
  public static let days = 7
  /// Nights with sleep it needs of the 7: most of them, so it's a week's average.
  public static let minimumNights = 4

  /// From `nights`, nights' sleep only (`SleepNight.latestBedtime`), as `sleepHighlights` reads
  /// them.
  init?(nights: [SleepNight], today: Date, calendar: Calendar) {
    guard let first = calendar.date(byAdding: .day, value: 1 - Self.days, to: today) else {
      return nil
    }
    let week = nights.filter { $0.day >= first && $0.day <= today }
    guard week.count >= Self.minimumNights else { return nil }
    self.init(firstDay: first, nights: week.map { Night(day: $0.day, asleep: $0.asleep) })
  }
}
