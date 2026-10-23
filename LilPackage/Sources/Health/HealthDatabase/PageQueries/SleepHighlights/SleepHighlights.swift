public import Foundation
public import SQLiteData

/// What Sleep's highlights show (851-3103), as iPad Health's do under its chart, each `nil`
/// without enough data to say something. About today, whichever period the page shows.
public struct SleepHighlights: Equatable, Sendable {
  /// Last night's bedtime against the last two weeks'.
  public var bedtime: BedtimeConsistency?
  /// This month's average time asleep against last month's.
  public var months: SleepMonthComparison?

  public init(bedtime: BedtimeConsistency? = nil, months: SleepMonthComparison? = nil) {
    self.bedtime = bedtime
    self.months = months
  }

  /// Whether there's nothing to show.
  public var isEmpty: Bool { bedtime == nil && months == nil }
}

extension HealthDatabase {
  /// Sleep's highlights as of `today`, from `sleepNights`' nights since the start of last month
  /// or the last two weeks, whichever starts first, so they read as the page's nights do. "Last
  /// night" is the night ending today; without one, the highlights about it aren't shown.
  public static func sleepHighlights(
    today: Date, calendar: Calendar, _ db: Database
  ) throws -> SleepHighlights {
    let today = calendar.startOfDay(for: today)
    guard
      let lastMonth = calendar.dateInterval(of: .month, for: today)
        .flatMap({ calendar.date(byAdding: .month, value: -1, to: $0.start) }),
      let twoWeeks = calendar.date(byAdding: .day, value: 1 - BedtimeConsistency.days, to: today)
    else { return SleepHighlights() }
    let first = min(lastMonth, twoWeeks)
    let count = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
    let nights = try sleepNights(endingOn: today, count: count, calendar: calendar, db)
    return SleepHighlights(
      bedtime: BedtimeConsistency(nights: nights, today: today, calendar: calendar),
      months: SleepMonthComparison(nights: nights, today: today, calendar: calendar))
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
    let zone = calendar.timeZone
    let shift = zone.secondsFromGMT(for: start) - zone.secondsFromGMT(for: day)
    return (date.timeIntervalSince(day) + Double(shift)) / 3600
  }
}

extension SleepNight {
  /// When sleep started: its first stretch asleep (not in bed, or awake before it).
  public var bedtime: Date? { segments.first { $0.stage.isAsleep }?.start }
}
