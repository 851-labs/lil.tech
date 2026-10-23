import Foundation
import SQLiteData
import Testing

@testable import HealthDatabase

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

  @Test
  func monthsChangeFrom5Percent() throws {
    // 5% under September's 8 hours exactly: less.
    try insert(
      (-4...0).flatMap { night($0, hours: 7.6) } + (-30 ... -21).flatMap { night($0, hours: 8) })
    #expect(try highlights().months?.direction == .down)
  }

  @Test
  func monthsLeaveOutNapsAndTheMonthBefore() throws {
    // Five nights of 8 hours, and a 1-hour nap on a day without a night; ten nights of 8 hours in
    // September, and August's of 2, before last month.
    try insert(
      (-4...0).flatMap { night($0, hours: 8) } + night(-6, bedtime: 14, hours: 1)
        + (-30 ... -21).flatMap { night($0, hours: 8) }
        + (-50 ... -46).flatMap { night($0, hours: 2) })
    let months = try #require(try highlights().months)
    #expect(months.thisMonthAverage == 8 * 3600)
    #expect(months.lastMonthAverage == 8 * 3600)
    #expect(months.direction == .same)
  }

  // MARK: Heart rate

  @Test
  func heartRateWhileAsleepEvery15Minutes() throws {
    let asleep = today.addingTimeInterval(-3600)
    try insert(
      night(0, bedtime: -1, hours: 7)
        // Every 5 minutes for the first hour: 4 ranges of 3 readings.
        + (0..<12).map {
          heartRate(Double(50 + $0), at: asleep.addingTimeInterval(Double($0) * 300))
        }
        // Before falling asleep, and after waking: not while asleep.
        + [
          heartRate(90, at: asleep.addingTimeInterval(-60)),
          heartRate(95, at: asleep.addingTimeInterval(7 * 3600)),
        ])
    let heartRate = try #require(try highlights().heartRate)
    #expect(heartRate.start == asleep)
    #expect(heartRate.end == asleep.addingTimeInterval(7 * 3600))
    #expect(
      heartRate.ranges.map(\.start) == (0..<4).map { asleep.addingTimeInterval(Double($0) * 900) })
    #expect(heartRate.ranges.first == SleepHeartRate.Range(start: asleep, minimum: 50, maximum: 52))
    #expect(heartRate.minimum == 50)
    #expect(heartRate.maximum == 61)
  }

  @Test
  func heartRateNeedsTenReadingsLastNight() throws {
    let asleep = today.addingTimeInterval(-3600)
    try insert(
      night(0) + (0..<9).map { heartRate(55, at: asleep.addingTimeInterval(Double($0) * 300)) })
    #expect(try highlights().heartRate == nil)
    // Ten more, but in the night before last night's.
    let before = day(-1).addingTimeInterval(-3600)
    try insert(
      night(-1) + (0..<10).map { heartRate(55, at: before.addingTimeInterval(Double($0) * 300)) })
    #expect(try highlights().heartRate == nil)
  }

  @Test
  func heartRateNeedsANightNotADaysSleep() throws {
    // No night, but a 2-hour nap at 2 PM with readings every 5 minutes.
    let nap = today.addingTimeInterval(14 * 3600)
    try insert(
      night(0, bedtime: 14, hours: 2)
        + (0..<24).map { heartRate(60, at: nap.addingTimeInterval(Double($0) * 300)) })
    #expect(try highlights().heartRate == nil)
  }

  @Test
  func heartRateLeavesOutTimeAwakeInTheNight() throws {
    // Asleep from 11 PM to 1 AM, up for an hour, then asleep until 6.
    let asleep = today.addingTimeInterval(-3600)
    try insert([
      sample(.core, asleep, 2), sample(.awake, asleep.addingTimeInterval(2 * 3600), 1),
      sample(.core, asleep.addingTimeInterval(3 * 3600), 4),
    ])
    // Every 10 minutes from 11 PM to 6 AM, 100 while up, 55 asleep.
    try insert(
      (0..<42).map { index in
        let time = asleep.addingTimeInterval(Double(index) * 600)
        let up = (12..<18).contains(index)
        return heartRate(up ? 100 : 55, at: time)
      })
    let heartRate = try #require(try highlights().heartRate)
    #expect(heartRate.maximum == 55)
    #expect(heartRate.ranges.count == 24)
  }

  // MARK: Week

  @Test
  func weekAveragesTheLast7Nights() throws {
    // Four of the last 7 nights, and one before them.
    try insert(
      night(0, hours: 8) + night(-2, hours: 7) + night(-4, hours: 6) + night(-6, hours: 7)
        + night(-7, hours: 2))
    let week = try #require(try highlights().week)
    #expect(week.firstDay == day(-6))
    #expect(week.nights.map(\.day) == [day(-6), day(-4), day(-2), today])
    #expect(week.average == 7 * 3600)
  }

  @Test
  func weekNeedsFourNights() throws {
    try insert(night(0) + night(-2) + night(-4) + night(-7))
    #expect(try highlights().week == nil)
  }

  @Test
  func weekLeavesOutADaysSleep() throws {
    // Four nights, and a nap on a day without one: still four, averaging 7 hours.
    try insert(
      night(0) + night(-2) + night(-4) + night(-6) + night(-1, bedtime: 14, hours: 1))
    let week = try #require(try highlights().week)
    #expect(week.nights.count == 4)
    #expect(week.average == 7 * 3600)
  }

  @Test
  func weeksFirstNightCountsTowardTheFour() throws {
    // Four nights, the first of them 6 days back: shown. Without it: not.
    try insert(night(-6) + night(-4) + night(-2) + night(0))
    #expect(try highlights().week?.nights.count == 4)
    try database.write { db in try HealthSample.delete().execute(db) }
    try insert(night(-4) + night(-2) + night(0))
    #expect(try highlights().week == nil)
  }

  // MARK: Stages

  @Test
  func stagesAreLastNightsIfItHasThem() throws {
    try insert(night(0, stage: .core) + night(-1, stage: .deep))
    #expect(try highlights().stages?.day == today)
    // An iPhone's estimate: asleep, without stages.
    try database.write { db in try HealthSample.delete().execute(db) }
    try insert(night(0, stage: .asleep))
    #expect(try highlights().stages == nil)
  }

  @Test
  func stagesNeedANightNotADaysSleep() throws {
    // No night, but a nap with stages at 2 PM.
    try insert(night(0, bedtime: 14, hours: 1, stage: .core))
    #expect(try highlights().stages == nil)
  }
}
