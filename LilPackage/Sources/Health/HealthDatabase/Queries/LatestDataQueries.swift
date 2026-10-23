public import Foundation
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
      return try latestSample(of: typeID, startedBy: now, db)?.start
    }
  }

  /// The day of the latest night with sleep, as `sleepNights` names nights: from sleep that
  /// started by `now`, in bed and awake aside, since a night needs time asleep.
  static func latestSleepNight(by now: Date, calendar: Calendar, _ db: Database) throws -> Date? {
    let upper = now.unixMilliseconds
    let asleep = SleepStage.allCases.filter(\.isAsleep).map { Optional($0.rawValue) }
    let start =
      try HealthSample
      .where { $0.type.eq(sleepType) && $0.startDate <= upper && $0.categoryValue.in(asleep) }
      .order { $0.startDate.desc() }
      .select(\.startDate)
      .limit(1)
      .fetchOne(db)
    return start.map {
      calendar.startOfDay(for: Date(unixMilliseconds: $0).addingTimeInterval(nightStartOffset))
    }
  }
}
