public import Foundation

/// Last night's bedtime against the last two weeks' (851-3103): when each night's sleep started,
/// on the clock, and their average.
public struct BedtimeConsistency: Equatable, Sendable {
  public struct Night: Equatable, Sendable {
    /// The start of the night's day.
    public var day: Date
    /// When its sleep started, in hours from `day`'s midnight by the clock
    /// (`HealthDatabase.clockHours`): 10:30 PM the evening before is -1.5.
    public var bedtime: Double

    public init(day: Date, bedtime: Double) {
      self.day = day
      self.bedtime = bedtime
    }
  }

  /// The first of the two weeks' days.
  public let firstDay: Date
  /// The nights with sleep in the two weeks, oldest first. The last is last night's.
  public let nights: [Night]

  /// `nights` can't be empty: the last is last night's.
  public init(firstDay: Date, nights: [Night]) {
    precondition(!nights.isEmpty, "Bedtime consistency needs last night.")
    self.firstDay = firstDay
    self.nights = nights
  }

  /// The days it looks back over, ending today.
  public static let days = 14
  /// Nights with sleep it needs in them, last night's included: half, so "usual" means something.
  public static let minimumNights = 7
  /// From the nights ending `today`, if last night is one and there are `minimumNights`.
  init?(nights: [SleepNight], today: Date, calendar: Calendar) {
    guard let first = calendar.date(byAdding: .day, value: 1 - Self.days, to: today) else {
      return nil
    }
    // Where each night's column starts sleeping in W and M; a day's sleep isn't a bedtime.
    let recent = nights.filter { $0.day >= first && $0.day <= today }.compactMap { night in
      night.nightBedtime(calendar: calendar).map { Night(day: night.day, bedtime: $0) }
    }
    guard recent.count >= Self.minimumNights,
      SleepNight.lastNight(in: nights, today: today, calendar: calendar) != nil
    else { return nil }
    self.init(firstDay: first, nights: recent)
  }

  /// Last night's.
  public var lastNight: Night { nights[nights.count - 1] }

  /// The average bedtime, in hours from midnight, last night's included.
  public var average: Double {
    nights.reduce(0) { $0 + $1.bedtime } / Double(nights.count)
  }

  /// How many minutes after the average last night's bedtime was (before, if negative), each
  /// rounded to the minute first, so it's the difference between the times shown.
  public var minutesFromAverage: Int {
    Int((lastNight.bedtime * 60).rounded()) - Int((average * 60).rounded())
  }
}
