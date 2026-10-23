import Foundation
import HealthDatabase
import SQLiteData
import Testing

// Sleep's highlights (851-3103). Synthetic data only (AGENTS.md): made-up nights and heart rates.

@Suite
struct SleepHighlightsTests {
  let database: any DatabaseWriter
  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  /// Wednesday, October 15, 2025, midnight UTC.
  let today = Date(timeIntervalSince1970: 1_760_486_400)

  init() throws {
    database = try HealthDatabase.make()
  }

  /// The start of the day `offset` days from today.
  private func day(_ offset: Int) -> Date {
    calendar.date(byAdding: .day, value: offset, to: today)!
  }

  /// A Watch's night ending on day `offset`: in bed 10 minutes before falling asleep at
  /// `bedtime` (hours from the day's midnight), then `stage` for `hours`.
  private func night(
    _ offset: Int, bedtime: Double = -1, hours: Double = 7, stage: SleepStage = .core
  ) -> [HealthSample] {
    let start = day(offset).addingTimeInterval(bedtime * 3600)
    return [
      sample(.inBed, start.addingTimeInterval(-600), hours + 0.25),
      sample(stage, start, hours),
    ]
  }

  private func sample(_ stage: SleepStage, _ start: Date, _ hours: Double) -> HealthSample {
    HealthSample(
      id: UUID().uuidString, type: HealthDatabase.sleepType, startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(hours * 3600).unixMilliseconds,
      categoryValue: stage.rawValue, sourceName: "Apple Watch",
      sourceBundleID: "com.apple.health.watch")
  }

  private func heartRate(_ value: Double, at date: Date) -> HealthSample {
    HealthSample(
      id: UUID().uuidString, type: HealthDatabase.heartRateType, startDate: date.unixMilliseconds,
      endDate: date.unixMilliseconds, value: value, unit: "count/min", sourceName: "Apple Watch",
      sourceBundleID: "com.apple.health.watch")
  }

  private func insert(_ samples: [HealthSample]) throws {
    try database.write { db in try HealthSample.insert { samples }.execute(db) }
  }

  private func highlights() throws -> SleepHighlights {
    try database.read { db in
      try HealthDatabase.sleepHighlights(
        today: today.addingTimeInterval(15 * 3600), calendar: calendar, db)
    }
  }

  @Test
  func nothingWithoutSleep() throws {
    #expect(try highlights().isEmpty)
  }

  // MARK: Bedtime

  @Test
  func bedtimeComparesLastNightWithTheTwoWeeksAverage() throws {
    // Bed at 11 PM most nights, at 10:30 last night, and nothing three nights ago.
    try insert(
      (-13...0).filter { $0 != -3 }.flatMap { night($0, bedtime: $0 == 0 ? -1.5 : -1) }
        // Earlier than the two weeks: not part of them.
        + night(-14, bedtime: -4))
    let bedtime = try #require(try highlights().bedtime)
    #expect(bedtime.firstDay == day(-13))
    #expect(bedtime.nights.count == 13)
    #expect(bedtime.lastNight == BedtimeConsistency.Night(day: today, bedtime: -1.5))
    // (12 × 11 PM + 10:30 PM) / 13 is about 10:58 PM.
    #expect(abs(bedtime.average - (12 * -1 - 1.5) / 13) < 1e-9)
    #expect(bedtime.minutesFromAverage == -28)
  }

  @Test
  func bedtimeNeedsLastNightAndHalfTheNights() throws {
    // Six nights, last night's included: one short.
    try insert((-5...0).flatMap { night($0) })
    #expect(try highlights().bedtime == nil)
    // A seventh, but none last night.
    try database.write { db in try HealthSample.delete().execute(db) }
    try insert((-7 ... -1).flatMap { night($0) })
    #expect(try highlights().bedtime == nil)
  }

  @Test
  func bedtimeAfterMidnightIsLaterThanBefore() throws {
    // Asleep at 12:30 AM, after six nights at 11:30 PM.
    try insert((-6 ... -1).flatMap { night($0, bedtime: -0.5) } + night(0, bedtime: 0.5))
    let bedtime = try #require(try highlights().bedtime)
    #expect(bedtime.lastNight.bedtime == 0.5)
    // Average (6 × -0.5 + 0.5) / 7 is about 11:39 PM: 51 minutes later.
    #expect(bedtime.minutesFromAverage == 51)
  }

  @Test
  func bedtimesAreClockTimesAcrossDaylightSaving() {
    var losAngeles = Calendar(identifier: .gregorian)
    losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    func date(_ day: Int, _ hour: Int) -> Date {
      losAngeles.date(from: DateComponents(year: 2024, month: 11, day: day, hour: hour))!
    }
    // Clocks went back at 2 AM on November 3, 2024: bed at 11 PM either side of it is -1, though
    // the 4th's midnight is 25 hours after the 3rd's.
    for night in [3, 4] {
      let bedtime = date(night - 1, 23)
      #expect(
        HealthDatabase.clockHours(
          bedtime, from: date(night, 0), start: bedtime, calendar: losAngeles)
          == -1)
    }
  }
}
