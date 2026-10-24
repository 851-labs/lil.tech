public import Foundation
import HealthCards
public import SQLiteData

/// What Sleep's highlights show (851-3103), as iPad Health's do under its chart, each `nil`
/// without enough data to say something. About today, whichever period the page shows.
public struct SleepHighlights: Equatable, Sendable {
  /// Last night's bedtime against the last two weeks'.
  public var bedtime: BedtimeConsistency?
  /// This month's average time asleep against last month's.
  public var months: SleepMonthComparison?
  /// Heart rate while asleep last night.
  public var heartRate: SleepHeartRate?
  /// The last 7 nights' average time asleep.
  public var week: SleepWeekAverage?
  /// Last night, if its source recorded stages.
  public var stages: SleepNight?

  public init(
    bedtime: BedtimeConsistency? = nil, months: SleepMonthComparison? = nil,
    heartRate: SleepHeartRate? = nil, week: SleepWeekAverage? = nil, stages: SleepNight? = nil
  ) {
    self.bedtime = bedtime
    self.months = months
    self.heartRate = heartRate
    self.week = week
    self.stages = stages
  }

  /// Whether there's nothing to show.
  public var isEmpty: Bool {
    bedtime == nil && months == nil && heartRate == nil && week == nil && stages == nil
  }
}

extension HealthDatabase {
  /// Sleep's highlights as of `today`, from `sleepNights`' nights since the start of last month
  /// (which covers the last two weeks), so they read as the page's nights do. "Last night" is the
  /// night ending today; without one, the highlights about it aren't shown.
  public static func sleepHighlights(
    today: Date, calendar: Calendar, _ db: Database
  ) throws -> SleepHighlights {
    let today = calendar.startOfDay(for: today)
    let lastMonth = calendar.dateInterval(of: .month, for: today)
      .flatMap { calendar.date(byAdding: .month, value: -1, to: $0.start) }
    let first =
      lastMonth ?? calendar.date(byAdding: .day, value: 1 - BedtimeConsistency.days, to: today)
      ?? today
    let count = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
    // Nights' sleep only: a day's isn't a night in any highlight (`latestBedtime`).
    let nights = try sleepNights(endingOn: today, count: count, calendar: calendar, db)
      .filter { $0.nightBedtime(calendar: calendar) != nil }
    let lastNight = SleepNight.lastNight(in: nights, today: today, calendar: calendar)
    return SleepHighlights(
      bedtime: BedtimeConsistency(nights: nights, today: today, calendar: calendar),
      months: SleepMonthComparison(nights: nights, today: today, calendar: calendar),
      heartRate: try lastNight.flatMap { try sleepHeartRate(during: $0, db) },
      week: SleepWeekAverage(nights: nights, today: today, calendar: calendar),
      // A Watch's stages (Core, Deep, REM), not an iPhone's estimate.
      stages: lastNight.flatMap { $0.hasStages ? $0 : nil })
  }

  /// Where `date` goes in the night that started at `start`, in hours from the start of `day`,
  /// the night's, on the local clock as it read when the night started: 11 PM the evening before
  /// is -1, 7:30 AM is 7.5. Each night is placed at the clock time it started, so a daylight
  /// saving change doesn't move the nights after it, and runs its true length from there, so a
  /// night across the change stays one unbroken column, though it ends an hour off the clock (at
  /// 6 AM for 7 AM in spring, 8 AM in the fall): the clock's repeated hour, or skipped one, can't
  /// draw a night over itself or leave a hole in it. Sleep's charts place nights with it
  /// (`SleepClock`, 851-3098), and its highlights their bedtimes.
  public static func clockHours(
    _ date: Date, from day: Date, start: Date, calendar: Calendar
  ) -> Double {
    CardNights.clockHours(date, from: day, start: start, calendar: calendar)
  }
}

extension SleepNight {
  /// When sleep started: its first stretch asleep (not in bed, or awake before it).
  public var bedtime: Date? { segments.first { $0.stage.isAsleep }?.start }

  /// The latest a night's sleep can start, in hours from its day's midnight, to be a night's:
  /// noon. Later is a day's sleep, a nap on a day whose night wasn't recorded, which highlights
  /// leave out: its "bedtime" (2 PM) says nothing about when bedtime is, and its hour asleep
  /// would pull an average of nights down.
  public static let latestBedtime: Double = CardNights.latestBedtime

  /// Last night among `nights` (by day, oldest first): the one ending `today`, if it's a night's
  /// sleep, not a day's (`latestBedtime`). Every highlight about last night asks this.
  static func lastNight(in nights: [SleepNight], today: Date, calendar: Calendar) -> SleepNight? {
    nights.last.flatMap { $0.day == today && $0.nightBedtime(calendar: calendar) != nil ? $0 : nil }
  }

  /// Its bedtime by the clock, placed as Sleep's W and M charts place it (from its first segment,
  /// 851-3098), if it's a night's sleep rather than a day's (`latestBedtime`).
  func nightBedtime(calendar: Calendar) -> Double? {
    guard let bedtime, let start = segments.map(\.start).min() else { return nil }
    return CardNights.nightBedtime(
      fallingAsleep: bedtime, firstStart: start, day: day, calendar: calendar)
  }
}
