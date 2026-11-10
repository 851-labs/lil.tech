public import Foundation
import HealthCards
import HealthCatalog
public import SQLiteData

extension HealthDatabase {
  /// When a period page's latest data is from, which it opens on when the current period has
  /// none (851-3188): Metric Detail's, a symptom's, Blood Pressure's readings, or Sleep's latest
  /// night (the start of its day). Only what had started by `now`, so a sample dated ahead (a
  /// meal planned for tomorrow) doesn't count. `nil` without any. One seek of an index per table,
  /// cheap enough for a page to ask before it first draws.
  public static func latestPeriodDate(
    of typeID: String, by now: Date, calendar: Calendar, _ db: Database
  ) throws -> Date? {
    switch typeID {
    case sleepType:
      return try latestSleepNight(by: now, calendar: calendar, db)
    case bloodPressureType:
      let upper = now.unixMilliseconds
      return
        try HealthCorrelation
        .where { $0.type.eq(bloodPressureType) && $0.startDate <= upper }
        .order { $0.startDate.desc() }
        .select(\.startDate)
        .limit(1)
        .fetchOne(db)
        .map(Date.init(unixMilliseconds:))
    default:
      // A type that adds up, as its Browse row dates it: its latest bucket or sample.
      if HealthCatalog.type(id: typeID)?.aggregation?.isCumulative == true {
        return try latestCumulativeStart(of: typeID, now: now, db)
      }
      let upper = now.unixMilliseconds
      return
        try HealthSample
        .where { $0.type.eq(typeID) && $0.startDate <= upper }
        .order { $0.startDate.desc() }
        .select(\.startDate)
        .limit(1)
        .fetchOne(db)
        .map(Date.init(unixMilliseconds:))
    }
  }

  /// The day of the latest night with sleep, as `sleepNights` names nights: from sleep that
  /// started by `now`. In bed and awake aren't a night, so it's the latest time asleep within
  /// two days of the latest sleep record (which usually ends the same night), a range of the
  /// index rather than every record back to one; the latest record's night without any.
  static func latestSleepNight(by now: Date, calendar: Calendar, _ db: Database) throws -> Date? {
    let upper = now.unixMilliseconds
    let latest =
      try HealthSample
      .where { $0.type.eq(sleepType) && $0.startDate <= upper }
      .order { $0.startDate.desc() }
      .select(\.startDate)
      .limit(1)
      .fetchOne(db)
    guard let latest else { return nil }
    let lower = latest - 2 * 86_400_000
    let asleep = SleepStage.allCases.filter(\.isAsleep).map { Optional($0.rawValue) }
    let asleepStart =
      try HealthSample
      .where {
        $0.type.eq(sleepType) && $0.startDate <= latest && $0.startDate >= lower
          && $0.categoryValue.in(asleep)
      }
      .order { $0.startDate.desc() }
      .select(\.startDate)
      .limit(1)
      .fetchOne(db)
    let start = asleepStart ?? latest
    // Time asleep's night as `sleepNights` names it (851-4174), on its zone's clock, which can be
    // two days from the calendar's: the latest of the nights around it, from sleep started by now.
    let day = calendar.startOfDay(for: Date(unixMilliseconds: start))
    if asleepStart != nil, let first = calendar.date(byAdding: .day, value: -3, to: day),
      let end = calendar.date(byAdding: .day, value: 4, to: day)
    {
      let range = CardNights.recordRange(days: first..<end)
      let records = try sleepRecords(
        in: range.lowerBound..<min(range.upperBound, upper + 1), startingFrom: range.lowerBound,
        db)
      if let night = CardNights.nights(records, days: first..<end, calendar: calendar).last {
        return night.day
      }
    }
    return calendar.startOfDay(
      for: Date(unixMilliseconds: start).addingTimeInterval(nightStartOffset))
  }
}
