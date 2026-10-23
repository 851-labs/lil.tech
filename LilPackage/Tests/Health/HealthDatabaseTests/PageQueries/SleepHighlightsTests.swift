import Foundation
import SQLiteData
import Testing

@testable import HealthDatabase

// Sleep's highlights (851-3103). Synthetic data only (AGENTS.md): made-up nights.

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
        // The day before the two weeks: not part of them.
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
  func bedtimeIsWhereItsNightsColumnStartsSleeping() {
    var losAngeles = Calendar(identifier: .gregorian)
    losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
      losAngeles.date(
        from: DateComponents(year: 2024, month: 3, day: day, hour: hour, minute: minute))!
    }
    // Six nights at 11 PM, then, on March 10, when clocks went forward at 2 AM: awake from 1:30
    // AM, asleep an hour later, at 3:30 by the clock. Sleep's W chart places the night from its
    // first segment, so its sleep starts at 2.5 hours, and so does its bedtime.
    let nights = (4...9).map { day in
      SleepNight(
        day: date(day, 0),
        segments: [SleepSegment(stage: .core, start: date(day - 1, 23), end: date(day, 7))],
        inBed: 8 * 3600)
    }
    let lastNight = SleepNight(
      day: date(10, 0),
      segments: [
        SleepSegment(stage: .awake, start: date(10, 1, 30), end: date(10, 3, 30)),
        SleepSegment(stage: .core, start: date(10, 3, 30), end: date(10, 9)),
      ],
      inBed: 7 * 3600)
    let bedtime = BedtimeConsistency(
      nights: nights + [lastNight], today: date(10, 0), calendar: losAngeles)
    #expect(bedtime?.lastNight.bedtime == 2.5)
    #expect(bedtime?.nights.first?.bedtime == -1)
  }

  @Test
  func aDaysSleepIsntABedtime() throws {
    // Six nights, then no night but a nap at 2 PM today: no last night to compare.
    try insert((-6 ... -1).flatMap { night($0) } + night(0, bedtime: 14, hours: 1))
    #expect(try highlights().bedtime == nil)
  }

  // MARK: Months

  @Test
  func monthsCompareAverageTimeAsleep() throws {
    // Five nights of 8 hours this month, ten of 7 in September.
    try insert(
      (-4...0).flatMap { night($0, hours: 8) } + (-30 ... -21).flatMap { night($0, hours: 7) })
    let months = try #require(try highlights().months)
    #expect(months.thisMonth == day(-14))
    #expect(months.lastMonth == calendar.date(byAdding: .month, value: -1, to: day(-14)))
    #expect(months.thisMonthAverage == 8 * 3600)
    #expect(months.lastMonthAverage == 7 * 3600)
    #expect(months.direction == .up)
  }

  @Test
  func monthsWithin5PercentAreAboutTheSame() throws {
    try insert(
      (-4...0).flatMap { night($0, hours: 7.2) } + (-30 ... -21).flatMap { night($0, hours: 7) })
    #expect(try highlights().months?.direction == .same)
  }

  @Test
  func monthsNeedEnoughNightsInEach() throws {
    // Four nights this month.
    try insert((-3...0).flatMap { night($0) } + (-30 ... -21).flatMap { night($0) })
    #expect(try highlights().months == nil)
    // Five this month, nine last month.
    try insert(night(-4))
    try database.write { db in
      // September 15's night, the first.
      let cutoff = day(-30).addingTimeInterval(3600).unixMilliseconds
      try HealthSample.where { $0.startDate < cutoff }.delete().execute(db)
    }
    #expect(try highlights().months == nil)
  }
}
