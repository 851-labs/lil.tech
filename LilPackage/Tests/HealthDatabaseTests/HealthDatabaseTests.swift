import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import HealthCatalog
import LilAPI
import LilSync
import LilTestSupport
import OpenAPIRuntime
import SQLiteData
import Testing

import class GRDB.Row

@testable import HealthDatabase

// Synthetic data only (AGENTS.md).
private let device = "dev_000000000000000000000000ph"
private let otherDevice = "dev_000000000000000000000000ot"
private let now = Date(timeIntervalSince1970: 1_760_486_400)  // 2025-10-15 00:00 UTC

private func utc(_ hours: Double, day: Int = 14) -> Date {
  Date(timeIntervalSince1970: 1_760_400_000 + Double(day - 14) * 86_400 + hours * 3600)
}

private func calendar(_ timeZone: String) -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: timeZone)!
  return calendar
}

private func sample(
  _ type: String, at start: Date, minutes: Double = 1, value: Double,
  source: String = "com.example"
) -> HealthSample {
  HealthSample(
    id: UUID().uuidString.lowercased(), type: type, startDate: start.unixMilliseconds,
    endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, value: value, unit: "x",
    sourceName: "Test", sourceBundleID: source)
}

private func statistic(_ type: String, at start: Date, sum: Double, device: String = device)
  -> HealthStatistic
{
  HealthStatistic(
    id: "\(device)/\(type)@\(start.unixMilliseconds)", device: device, type: type,
    bucketStart: start.unixMilliseconds, sum: sum, unit: "count")
}

private func reported(
  _ id: String, paired: Bool, daysAgo: Double
) -> HealthStatisticsDevice {
  HealthStatisticsDevice(
    id: id, device: id, pairedWithWatch: paired,
    reportedAt: now.addingTimeInterval(-daysAgo * 86_400).unixMilliseconds)
}

@Suite
struct HealthQueriesTests {
  let database: any DatabaseWriter

  init() throws {
    database = try HealthDatabase.make()
  }

  @Test
  func theSourceIsTheRecentWatchPairedIPhone() throws {
    try database.write { db in
      try HealthStatisticsDevice.insert {
        reported("dev_a", paired: false, daysAgo: 0)
        reported("dev_b", paired: true, daysAgo: 2)
        // Paired, but it hasn't reported in weeks.
        reported("dev_c", paired: true, daysAgo: 30)
      }
      .execute(db)
    }
    #expect(try database.read { try HealthDatabase.statisticsSource($0, now: now) } == "dev_b")
  }

  @Test
  func withoutRecentReportsTheMostRecentIPhoneIsTheSource() throws {
    try database.write { db in
      try HealthStatisticsDevice.insert {
        reported("dev_a", paired: true, daysAgo: 40)
        reported("dev_b", paired: false, daysAgo: 20)
      }
      .execute(db)
    }
    #expect(try database.read { try HealthDatabase.statisticsSource($0, now: now) } == "dev_b")
    #expect(
      try HealthDatabase.make().read { try HealthDatabase.statisticsSource($0, now: now) } == nil)
  }

  @Test
  func cumulativeTotalsComeFromTheSourcesBuckets() throws {
    let steps = "HKQuantityTypeIdentifierStepCount"
    let statistics = [
      // 2025-10-14 in UTC.
      statistic(steps, at: utc(9), sum: 100),
      statistic(steps, at: utc(9.5), sum: 50),
      statistic(steps, at: utc(23.5), sum: 7),
      // The next day.
      statistic(steps, at: utc(0, day: 15), sum: 30),
      // Another iPhone's numbers are ignored.
      statistic(steps, at: utc(10), sum: 9999, device: otherDevice),
    ]
    try database.write { db in
      try HealthStatisticsDevice.insert {
        reported(device, paired: true, daysAgo: 0)
        reported(otherDevice, paired: false, daysAgo: 0)
      }
      .execute(db)
      try HealthStatistic.insert { statistics }.execute(db)
    }
    let range = utc(0)..<utc(24, day: 15)
    let daily = try database.read {
      try HealthDatabase.cumulativeStatistics(
        of: steps, in: range, by: .day, calendar: calendar("UTC"), now: now, $0)
    }
    #expect(
      daily == [
        CumulativeStatistic(start: utc(0), sum: 157),
        CumulativeStatistic(start: utc(0, day: 15), sum: 30),
      ])

    // In India (UTC+5:30) the 23:30 and 00:00 UTC buckets fall on the 15th.
    let india = try database.read {
      try HealthDatabase.cumulativeStatistics(
        of: steps, in: range, by: .day, calendar: calendar("Asia/Kolkata"), now: now, $0)
    }
    #expect(
      india == [
        CumulativeStatistic(start: utc(-5.5), sum: 150),
        CumulativeStatistic(start: utc(18.5), sum: 37),
      ])

    let hourly = try database.read {
      try HealthDatabase.cumulativeStatistics(
        of: steps, in: utc(9)..<utc(10), by: .hour, calendar: calendar("UTC"), now: now, $0)
    }
    #expect(hourly == [CumulativeStatistic(start: utc(9), sum: 150)])
  }

  @Test
  func discreteAveragesFollowTheTypesAggregation() throws {
    let weight = "HKQuantityTypeIdentifierBodyMass"
    let heartRate = "HKQuantityTypeIdentifierHeartRate"
    let noise = "HKQuantityTypeIdentifierEnvironmentalAudioExposure"
    let samples = [
      sample(weight, at: utc(8), value: 70),
      sample(weight, at: utc(20), value: 72),
      sample(weight, at: utc(8, day: 15), value: 71),
      // 60 bpm for 30 minutes, then 120 bpm for 10.
      sample(heartRate, at: utc(10), value: 60),
      sample(heartRate, at: utc(10.5), value: 120),
      sample(heartRate, at: utc(10 + 40.0 / 60), value: 60),
      // Two equal-length exposures: the level is dominated by the louder one.
      sample(noise, at: utc(12), minutes: 10, value: 60),
      sample(noise, at: utc(13), minutes: 10, value: 80),
    ]
    try database.write { db in try HealthSample.insert { samples }.execute(db) }
    let utcCalendar = calendar("UTC")
    let weights = try database.read {
      try HealthDatabase.discreteStatistics(
        of: weight, in: utc(0)..<utc(24, day: 15), by: .day, calendar: utcCalendar, $0)
    }
    #expect(
      weights == [
        DiscreteStatistic(start: utc(0), average: 71, minimum: 70, maximum: 72, count: 2),
        DiscreteStatistic(start: utc(0, day: 15), average: 71, minimum: 71, maximum: 71, count: 1),
      ])

    let heart = try database.read {
      try HealthDatabase.discreteStatistics(
        of: heartRate, in: utc(10)..<utc(11), by: .hour, calendar: utcCalendar, $0)
    }
    // Weighted by 30 minutes, 10 minutes, and the last sample's own minute.
    let weighted: Double = 60 * 1800 + 120 * 600 + 60 * 60
    let expected = weighted / 2460
    #expect(abs((heart.first?.average ?? 0) - expected) < 0.0001)
    #expect(heart.first?.count == 3)

    let level = try database.read {
      try HealthDatabase.discreteStatistics(
        of: noise, in: utc(0)..<utc(24), by: .day, calendar: utcCalendar, $0)
    }
    let energy: Double = pow(10, 6) + pow(10, 8)
    let expectedLevel = 10 * log10(energy / 2)
    #expect(abs((level.first?.average ?? 0) - expectedLevel) < 0.0001)
  }

  @Test
  func timeWeightedAveragesDontDependOnTheRange() throws {
    let heartRate = "HKQuantityTypeIdentifierHeartRate"
    let samples = [
      // The day's last sample counts until the next day's first, 30 minutes later.
      sample(heartRate, at: utc(23), value: 60),
      sample(heartRate, at: utc(23.5), value: 90),
      sample(heartRate, at: utc(0, day: 15), value: 120),
    ]
    try database.write { db in try HealthSample.insert { samples }.execute(db) }
    let utcCalendar = calendar("UTC")
    let (oneDay, twoDays) = try database.read { db in
      (
        try HealthDatabase.discreteStatistics(
          of: heartRate, in: utc(0)..<utc(24), by: .day, calendar: utcCalendar, db),
        try HealthDatabase.discreteStatistics(
          of: heartRate, in: utc(0)..<utc(24, day: 15), by: .day, calendar: utcCalendar, db)
      )
    }
    #expect(oneDay.first == twoDays.first)
    #expect(oneDay.first?.average == 75)
  }

  @Test
  func eachSourceIsItsOwnSeries() throws {
    let heartRate = "HKQuantityTypeIdentifierHeartRate"
    // A strap's reading a second after the Watch's doesn't cut the Watch's short.
    let samples = [
      sample(heartRate, at: utc(10), value: 60, source: "com.apple.health.watch"),
      sample(heartRate, at: utc(10) + 1, value: 80, source: "com.example.strap"),
      sample(heartRate, at: utc(10.5), value: 60, source: "com.apple.health.watch"),
      sample(heartRate, at: utc(10.5) + 1, value: 80, source: "com.example.strap"),
    ]
    try database.write { db in try HealthSample.insert { samples }.execute(db) }
    let hour = try database.read {
      try HealthDatabase.discreteStatistics(
        of: heartRate, in: utc(10)..<utc(10.5), by: .hour, calendar: calendar("UTC"), $0)
    }
    #expect(hour.first?.average == 70)
  }

  @Test
  func sourceTiesGoToTheHigherDeviceID() throws {
    try database.write { db in
      try HealthStatisticsDevice.insert {
        reported("dev_b", paired: true, daysAgo: 1)
        reported("dev_a", paired: true, daysAgo: 1)
      }
      .execute(db)
    }
    #expect(try database.read { try HealthDatabase.statisticsSource($0, now: now) } == "dev_b")
  }

  @Test
  func latestSampleAndSamplesInARange() throws {
    let weight = "HKQuantityTypeIdentifierBodyMass"
    let (a, b, c) = (
      sample(weight, at: utc(8), value: 70), sample(weight, at: utc(20), value: 72),
      sample(weight, at: utc(8, day: 15), value: 71)
    )
    try database.write { db in
      try HealthSample.insert {
        a
        b
        c
      }.execute(db)
    }
    let (latest, inRange, none) = try database.read { db in
      (
        try HealthDatabase.latestSample(of: weight, db),
        try HealthDatabase.samples(of: weight, in: utc(0)..<utc(24), db),
        try HealthDatabase.latestSample(of: "HKQuantityTypeIdentifierHeight", db)
      )
    }
    #expect(latest == c)
    #expect(inRange == [a, b])
    #expect(none == nil)
  }
}

@Suite
struct BrowseQueriesTests {
  let database: any DatabaseWriter
  let utcCalendar = calendar("UTC")

  init() throws {
    database = try HealthDatabase.make()
  }

  private func summary(_ id: String) throws -> MetricSummary {
    let type = try #require(HealthCatalog.type(id: id))
    return try database.read { db in
      try HealthDatabase.metricSummary(of: type, now: now, calendar: utcCalendar, db)
    }
  }

  @Test
  func aCumulativeTypeShowsItsLatestDaysTotalAndTheWeekBefore() throws {
    let steps = "HKQuantityTypeIdentifierStepCount"
    try database.write { db in
      try HealthStatisticsDevice.insert { reported(device, paired: true, daysAgo: 0) }.execute(db)
      try HealthStatistic.insert {
        // Too old for the week ending on the 14th.
        statistic(steps, at: utc(9, day: 6), sum: 999)
        statistic(steps, at: utc(9, day: 12), sum: 1_000)
        statistic(steps, at: utc(9, day: 14), sum: 300)
        statistic(steps, at: utc(9.5, day: 14), sum: 200)
      }.execute(db)
    }
    let summary = try summary(steps)
    #expect(summary.latestDate == utc(0, day: 14))
    #expect(summary.latestValue == 500)
    #expect(summary.isDailyTotal)
    #expect(summary.unit == "count")
    #expect(
      summary.days == [
        DailyValue(day: utc(0, day: 12), value: 1_000),
        DailyValue(day: utc(0, day: 14), value: 500),
      ])
  }

  @Test
  func emptyBucketsCountAsNoData() throws {
    let steps = "HKQuantityTypeIdentifierStepCount"
    try database.write { db in
      try HealthStatisticsDevice.insert { reported(device, paired: true, daysAgo: 0) }.execute(db)
      try HealthStatistic.insert {
        statistic(steps, at: utc(9, day: 12), sum: 4_000)
        // Zero-filled from the 13th to tomorrow, as the iPhone sends them.
        statistic(steps, at: utc(9, day: 13), sum: 0)
        statistic(steps, at: utc(9), sum: 0)
        statistic(steps, at: utc(9, day: 15), sum: 0)
      }.execute(db)
    }
    var summary = try summary(steps)
    #expect(summary.latestDate == utc(0, day: 12))
    #expect(summary.latestValue == 4_000)
    // Empty days aren't days with data.
    #expect(summary.days.map(\.value) == [4_000])

    // Steps that arrived before their sums show, despite the empty buckets.
    try database.write { db in
      try HealthSample.insert { sample(steps, at: utc(10), value: 2_000) }.execute(db)
    }
    summary = try self.summary(steps)
    #expect(summary.latestDate == utc(0))
    #expect(summary.latestValue == 2_000)
  }

  @Test
  func aSampleLoggedAheadIsntTheLatestDay() throws {
    let water = "HKQuantityTypeIdentifierDietaryWater"
    try database.write { db in
      try HealthSample.insert {
        sample(water, at: utc(8), value: 0.5)
        // Tomorrow's, planned.
        sample(water, at: utc(8, day: 16), value: 0.25)
      }.execute(db)
    }
    #expect(try summary(water).latestDate == utc(0))
  }

  @Test
  func aLatestDayTheBucketsDontCoverYetUsesItsSamples() throws {
    let steps = "HKQuantityTypeIdentifierStepCount"
    try database.write { db in
      try HealthStatisticsDevice.insert { reported(device, paired: true, daysAgo: 0) }.execute(db)
      try HealthStatistic.insert { statistic(steps, at: utc(9, day: 13), sum: 4_000) }.execute(db)
      // Synced before today's buckets.
      try HealthSample.insert { sample(steps, at: utc(0.1), value: 120) }.execute(db)
    }
    let summary = try summary(steps)
    #expect(summary.latestDate == utc(0))
    #expect(summary.latestValue == 120)
    #expect(summary.days.map(\.value) == [4_000, 120])
  }

  @Test
  func aCumulativeTypeWithoutStatisticsAddsUpItsSamples() throws {
    let water = "HKQuantityTypeIdentifierDietaryWater"
    try database.write { db in
      try HealthSample.insert {
        sample(water, at: utc(8), value: 0.25)
        sample(water, at: utc(12), value: 0.5)
      }.execute(db)
    }
    let summary = try summary(water)
    #expect(summary.latestDate == utc(0))
    #expect(summary.latestValue == 0.75)
  }

  @Test
  func aDiscreteTypeShowsItsLatestSampleAndDailyAverages() throws {
    let weight = "HKQuantityTypeIdentifierBodyMass"
    try database.write { db in
      try HealthSample.insert {
        sample(weight, at: utc(8, day: 13), value: 70)
        sample(weight, at: utc(20, day: 13), value: 72)
        sample(weight, at: utc(8), value: 71.5)
      }.execute(db)
    }
    let summary = try summary(weight)
    #expect(summary.latestDate == utc(8))
    #expect(summary.latestValue == 71.5)
    #expect(!summary.isDailyTotal)
    #expect(summary.days.map(\.value) == [71, 71.5])
  }

  @Test
  func typesWithoutAValueShowWhenTheyWereLastRecorded() throws {
    let headache = "HKCategoryTypeIdentifierHeadache"
    try database.write { db in
      try HealthSample.insert {
        HealthSample(
          id: "h1", type: headache, startDate: utc(10).unixMilliseconds,
          endDate: utc(11).unixMilliseconds, categoryValue: 1, sourceName: "Test",
          sourceBundleID: "com.example")
      }.execute(db)
      try HealthActivitySummary.insert { HealthActivitySummary(id: "2025-10-13") }.execute(db)
      try HealthMedicationDose.insert {
        HealthMedicationDose(
          id: "d1", startDate: utc(9).unixMilliseconds, endDate: utc(9).unixMilliseconds,
          medication: "m1", logStatus: 4, scheduleType: 1, unit: "count", sourceName: "Test",
          sourceBundleID: "com.example")
      }.execute(db)
    }
    #expect(try summary(headache).latestDate == utc(10))
    // Medications have no dates of their own: theirs is the latest dose's.
    #expect(try summary("HKDataTypeUserAnnotatedMedicationConcept").latestDate == utc(9))
    #expect(
      try summary("HKMedicationDoseEventTypeIdentifierMedicationDoseEvent").latestDate == utc(9))
    #expect(try summary(headache).latestValue == nil)
    #expect(try summary("HKActivitySummaryTypeIdentifier").latestDate == utc(0, day: 13))
    // A day's, not a moment's.
    #expect(try summary("HKActivitySummaryTypeIdentifier").isDailyTotal)
  }

  @Test
  func medicationsWithoutDosesHaveData() throws {
    let medications = "HKDataTypeUserAnnotatedMedicationConcept"
    let doses = "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"
    #expect(try !summary(medications).hasData)
    try database.write { db in
      try HealthMedication.insert {
        HealthMedication(id: "m1", name: "Synthetic Spray A", generalForm: "spray")
      }
      .execute(db)
    }
    // Shared, as needed and never logged: there, but undated.
    #expect(try summary(medications).hasData)
    #expect(try summary(medications).latestDate == nil)
    // Doses aren't, until one is logged.
    #expect(try !summary(doses).hasData)
  }

  @Test
  func typesWithoutDataHaveNone() throws {
    let summaries = try database.read { db in
      try HealthDatabase.metricSummaries(in: .heart, now: now, calendar: utcCalendar, db)
    }
    #expect(summaries.map(\.id) == HealthCatalog.types(in: .heart).map(\.id))
    #expect(summaries.allSatisfy { !$0.hasData })
  }
}

@Suite
struct ChartQueriesTests {
  let database: any DatabaseWriter
  let utcCalendar = calendar("UTC")
  let steps = try! #require(HealthCatalog.type(id: "HKQuantityTypeIdentifierStepCount"))
  let heartRate = try! #require(HealthCatalog.type(id: "HKQuantityTypeIdentifierHeartRate"))

  init() throws {
    database = try HealthDatabase.make()
    try database.write { db in
      try HealthStatisticsDevice.insert { reported(device, paired: true, daysAgo: 0) }.execute(db)
    }
  }

  private func chart(_ type: HealthDataType, _ range: ChartRange, offset: Int = 0) throws
    -> MetricChart
  {
    // Midday on Wednesday, October 15, 2025.
    let noon = now.addingTimeInterval(12 * 3600)
    return try database.read { db in
      try HealthDatabase.metricChart(
        of: type, range: range, offset: offset, now: noon, calendar: utcCalendar, db)
    }
  }

  @Test
  func periodsFollowTheCalendar() {
    let noon = now.addingTimeInterval(12 * 3600)
    let interval = { (range: ChartRange, offset: Int) in
      range.interval(offset: offset, now: noon, calendar: utcCalendar)
    }
    #expect(interval(.day, 0) == DateInterval(start: utc(0, day: 15), end: utc(0, day: 16)))
    // Weeks start on Sunday in this calendar.
    #expect(interval(.week, 0) == DateInterval(start: utc(0, day: 12), end: utc(0, day: 19)))
    #expect(interval(.week, -1) == DateInterval(start: utc(0, day: 5), end: utc(0, day: 12)))
    #expect(interval(.month, 0).start == utc(0, day: 1))
    // May through October, then November through April before it.
    let sixMonths = interval(.sixMonths, 0)
    #expect(utcCalendar.component(.month, from: sixMonths.start) == 5)
    #expect(sixMonths.end == utc(0, day: 32))
    #expect(interval(.sixMonths, -1).end == sixMonths.start)
    #expect(utcCalendar.component(.month, from: interval(.year, 0).start) == 1)
  }

  @Test
  func aCumulativeDayIsHourlyTotalsAndItsTotal() throws {
    try database.write { db in
      try HealthStatistic.insert {
        statistic(steps.id, at: utc(9, day: 15), sum: 100)
        statistic(steps.id, at: utc(9.5, day: 15), sum: 50)
        statistic(steps.id, at: utc(14, day: 15), sum: 200)
        statistic(steps.id, at: utc(9, day: 14), sum: 999)
      }.execute(db)
    }
    let chart = try chart(steps, .day)
    #expect(chart.points.map(\.value) == [150, 200])
    #expect(chart.points.map(\.start) == [utc(9, day: 15), utc(14, day: 15)])
    #expect(chart.summary == .total(350))
  }

  @Test
  func aCumulativeWeekIsDailyTotalsAndItsAverageDay() throws {
    try database.write { db in
      try HealthStatistic.insert {
        statistic(steps.id, at: utc(9, day: 13), sum: 1_000)
        statistic(steps.id, at: utc(9, day: 15), sum: 3_000)
        // The week before.
        statistic(steps.id, at: utc(9, day: 11), sum: 500)
      }.execute(db)
    }
    let chart = try chart(steps, .week)
    #expect(chart.points.map(\.value) == [1_000, 3_000])
    // Per day with data.
    #expect(chart.summary == .dailyAverage(2_000))
    #expect(try self.chart(steps, .week, offset: -1).summary == .dailyAverage(500))
  }

  @Test
  func aCumulativeChartAddsSamplesPastItsLastBucket() throws {
    try database.write { db in
      try HealthStatistic.insert { statistic(steps.id, at: utc(9, day: 15), sum: 100) }.execute(db)
      try HealthSample.insert {
        // Inside the bucket: already counted.
        sample(steps.id, at: utc(9.2, day: 15), value: 100)
        // Synced before its bucket.
        sample(steps.id, at: utc(11, day: 15), value: 40)
      }.execute(db)
    }
    #expect(try chart(steps, .day).points.map(\.value) == [100, 40])
    #expect(try chart(steps, .day).summary == .total(140))
  }

  @Test
  func aCumulativeChartWithoutStatisticsUsesTheSamples() throws {
    try database.write { db in
      try HealthSample.insert {
        sample(steps.id, at: utc(9, day: 13), value: 300)
        sample(steps.id, at: utc(10, day: 13), value: 200)
      }.execute(db)
    }
    let chart = try chart(steps, .week)
    #expect(chart.points == [ChartPoint(start: utc(0, day: 13), value: 500)])
  }

  @Test
  func aCumulativeYearIsEachMonthsAverageDay() throws {
    try database.write { db in
      try HealthStatistic.insert {
        statistic(steps.id, at: utc(9, day: 13), sum: 1_000)
        statistic(steps.id, at: utc(9, day: 15), sum: 3_000)
        statistic(steps.id, at: utc(9, day: -20), sum: 6_000)
      }.execute(db)
    }
    let chart = try chart(steps, .year)
    #expect(chart.points.map(\.value) == [6_000, 2_000])
    #expect(chart.summary == .dailyAverage(10_000 / 3))
  }

  @Test
  func aDiscreteTypeChartsEachBucketsAverageAndRange() throws {
    try database.write { db in
      try HealthSample.insert {
        sample(heartRate.id, at: utc(9, day: 15), value: 60)
        sample(heartRate.id, at: utc(9.5, day: 15), value: 100)
        sample(heartRate.id, at: utc(20, day: 13), value: 55)
      }.execute(db)
    }
    let week = try chart(heartRate, .week)
    #expect(week.points.map(\.minimum) == [55, 60])
    #expect(week.points.map(\.maximum) == [55, 100])
    #expect(week.summary == .range(minimum: 55, maximum: 100))
    #expect(try chart(heartRate, .week, offset: -1).summary == nil)
  }
}

@Suite
struct SampleQueriesTests {
  let database: any DatabaseWriter
  let weight = "HKQuantityTypeIdentifierBodyMass"

  init() throws {
    database = try HealthDatabase.make()
  }

  @Test
  func pagesGoNewestFirstWithoutSkippingTies() throws {
    var samples = (0..<5).map { sample(weight, at: utc(Double($0)), value: 70) }
    // Two at the same moment.
    samples.append(sample(weight, at: utc(4), value: 71))
    try database.write { db in try HealthSample.insert { samples }.execute(db) }
    var seen: [HealthSample] = []
    var cursor: SampleCursor?
    while true {
      let page = try database.read { db in
        try HealthDatabase.samplePage(of: weight, after: cursor, limit: 2, db)
      }
      guard let last = page.last else { break }
      seen += page
      cursor = SampleCursor(after: last)
    }
    #expect(seen.count == 6)
    #expect(Set(seen.map(\.id)) == Set(samples.map(\.id)))
    #expect(seen.map(\.startDate) == seen.map(\.startDate).sorted(by: >))
  }

  @Test
  func sourcesAreTheAppsAndDevicesThatWroteTheType() throws {
    let watch = #"{"name":"Apple Watch","model":"Watch","softwareVersion":"26.0"}"#
    // The same watch after an update.
    let updatedWatch = #"{"name":"Apple Watch","model":"Watch","softwareVersion":"26.1"}"#
    var a = sample(weight, at: utc(1), value: 70, source: "com.example.scale")
    a.sourceName = "Scale"
    var b = sample(weight, at: utc(2), value: 70, source: "com.example.scale")
    b.sourceName = "Scale"
    b.device = watch
    var c = sample(weight, at: utc(3), value: 70)
    c.device = updatedWatch
    try database.write { db in
      try HealthSample.insert {
        a
        b
        c
      }.execute(db)
    }
    let sources = try database.read { db in try HealthDatabase.sampleSources(of: weight, db) }
    let (apps, devices) = (sources.apps, sources.devices)
    #expect(apps.map(\.id) == ["com.example.scale", "com.example"])
    #expect(apps.map(\.count) == [2, 1])
    #expect(devices.map(\.device.name) == ["Apple Watch"])
    #expect(devices.map(\.count) == [2])
  }

  @Test
  func samplesFromNewerIPhonesGetTheirDeviceFromTheirProvenance() throws {
    // Synthetic data only (AGENTS.md).
    let watch = HealthProvenance(
      id: "0123456789abcdef0123456789abcdef", sourceRevision: #"{"version":"11.0"}"#,
      device: #"{"name":"Apple Watch","model":"Watch"}"#)
    var a = sample(weight, at: utc(1), value: 70)
    a.provenance = watch.id
    var b = sample(weight, at: utc(2), value: 71)
    b.provenance = watch.id
    // One uploaded with its device inline, by an older iPhone.
    var c = sample(weight, at: utc(3), value: 72)
    c.device = #"{"name":"Apple Watch","model":"Watch","softwareVersion":"26.1"}"#
    // One whose provenance hasn't synced yet.
    var d = sample(weight, at: utc(4), value: 73)
    d.provenance = "fedcba9876543210fedcba9876543210"
    try database.write { db in
      try HealthProvenance.insert { watch }.execute(db)
      try HealthSample.insert {
        a
        b
        c
        d
      }.execute(db)
    }
    let page = try database.read { db in
      try HealthDatabase.samplePage(of: weight, after: nil, limit: 10, db)
    }
    #expect(page.map(\.decodedDevice?.name) == [nil, "Apple Watch", "Apple Watch", "Apple Watch"])
    #expect(page.map(\.decodedSourceRevision?.version) == [nil, nil, "11.0", "11.0"])
    let sources = try database.read { db in try HealthDatabase.sampleSources(of: weight, db) }
    #expect(sources.devices.map(\.device.name) == ["Apple Watch"])
    #expect(sources.devices.map(\.count) == [3])
  }

  @Test
  func aSamplesDeviceRevisionAndMetadataDecode() {
    var heartRate = sample("HKQuantityTypeIdentifierHeartRate", at: utc(1), value: 60)
    heartRate.device = #"{"name":"Apple Watch","manufacturer":"Apple Inc."}"#
    heartRate.sourceRevision = #"{"version":"26.0","productType":"Watch7,1"}"#
    heartRate.metadata =
      #"{"HKMetadataKeyHeartRateMotionContext":1,"Custom":{"a":true},"HKMetadataKeyWasUserEntered":true,"Infinite":null}"#
    #expect(heartRate.decodedDevice?.manufacturer == "Apple Inc.")
    #expect(heartRate.decodedSourceRevision?.productType == "Watch7,1")
    #expect(
      heartRate.metadataEntries.map(\.key) == [
        "Custom", "HKMetadataKeyHeartRateMotionContext", "HKMetadataKeyWasUserEntered", "Infinite",
      ])
    // Booleans read as words, and nulls (values JSON can't hold) as a dash.
    #expect(heartRate.metadataEntries.map(\.value) == [#"{"a":true}"#, "1", "Yes", "–"])
  }
}

@Suite
struct HighlightQueriesTests {
  let database: any DatabaseWriter
  let utcCalendar = calendar("UTC")
  let steps = "HKQuantityTypeIdentifierStepCount"
  let resting = "HKQuantityTypeIdentifierRestingHeartRate"

  init() throws {
    database = try HealthDatabase.make()
    try database.write { db in
      try HealthStatisticsDevice.insert { reported(device, paired: true, daysAgo: 0) }.execute(db)
    }
  }

  private func highlights() throws -> [Highlight] {
    // Midday on October 15: today is the 15th.
    try database.read { db in
      try HealthDatabase.highlights(
        now: now.addingTimeInterval(12 * 3600), calendar: utcCalendar, db)
    }
  }

  @Test
  func theLastSevenFullDaysAgainstTheSevenBefore() throws {
    try database.write { db in
      // 1,000 a day from the 8th to the 14th, 800 a day from the 1st to the 7th.
      for day in 1...14 {
        try HealthStatistic.insert {
          statistic(steps, at: utc(9, day: day), sum: day >= 8 ? 1_000 : 800)
        }.execute(db)
      }
      // Today isn't over, so it doesn't count.
      try HealthStatistic.insert { statistic(steps, at: utc(9, day: 15), sum: 10) }.execute(db)
    }
    let week = try #require(try highlights().first { $0.typeID == steps && $0.kind == .week })
    #expect(week.current == 1_000)
    #expect(week.previous == 800)
    #expect(week.direction == .up)
    #expect(week.recentStart == utc(0, day: 8))
  }

  @Test
  func aWeekNeedsAFewDaysOfData() throws {
    try database.write { db in
      try HealthStatistic.insert {
        statistic(steps, at: utc(9, day: 13), sum: 1_000)
        statistic(steps, at: utc(9, day: 14), sum: 1_000)
        for day in 1...7 { statistic(steps, at: utc(9, day: day), sum: 800) }
      }.execute(db)
    }
    #expect(try highlights().isEmpty)
  }

  @Test
  func aTrendIsTheLastFourWeeksAgainstTheTwelveBefore() throws {
    try database.write { db in
      for week in 0..<16 {
        // A reading a few days into each week back from yesterday: 70 lately, 60 before.
        let day = 14 - week * 7 - 2
        try HealthSample.insert {
          sample(resting, at: utc(8, day: day), value: week < 4 ? 70 : 60)
        }.execute(db)
      }
    }
    let trend = try #require(try highlights().first { $0.kind == .trend })
    #expect(trend.typeID == resting)
    #expect(trend.current == 70)
    #expect(trend.previous == 60)
    #expect(trend.direction == .up)
    #expect(trend.points.count == 16)
    // Dated at their rolling weeks' starts, 7 days apart, the last 4 from 28 days ago.
    #expect(trend.points.last?.day == utc(0, day: 8))
    #expect(trend.recentStart == utc(0, day: -13))
  }

  @Test
  func aSmallChangeIsntATrend() throws {
    try database.write { db in
      for week in 0..<16 {
        let day = 14 - week * 7 - 2
        try HealthSample.insert {
          sample(resting, at: utc(8, day: day), value: week < 4 ? 62 : 60)
        }.execute(db)
      }
    }
    #expect(try highlights().filter { $0.kind == .trend }.isEmpty)
  }
}

@Suite
struct SleepQueriesTests {
  let database: any DatabaseWriter
  let utcCalendar = calendar("UTC")
  let sleep = "HKCategoryTypeIdentifierSleepAnalysis"

  init() throws {
    database = try HealthDatabase.make()
  }

  private func stage(
    _ value: Int, from start: Date, hours: Double, source: String = "com.apple.health.watch"
  ) -> HealthSample {
    HealthSample(
      id: UUID().uuidString, type: sleep, startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(hours * 3600).unixMilliseconds, categoryValue: value,
      sourceName: "Test", sourceBundleID: source)
  }

  private func nights(endingOn day: Int, count: Int) throws -> [SleepNight] {
    try database.read { db in
      try HealthDatabase.sleepNights(
        endingOn: utc(0, day: day), count: count, calendar: utcCalendar, db)
    }
  }

  @Test
  func aNightBelongsToTheDayItEndsOn() throws {
    try database.write { db in
      try HealthSample.insert {
        // From 23:00 on the 13th: the 14th's night.
        stage(3, from: utc(23, day: 13), hours: 2)
        stage(4, from: utc(1, day: 14), hours: 1)
        stage(2, from: utc(2, day: 14), hours: 0.25)
        stage(5, from: utc(2.25, day: 14), hours: 1)
        // An afternoon nap on the 14th: the 14th's too, but not part of its night.
        stage(1, from: utc(15, day: 14), hours: 0.5)
      }.execute(db)
    }
    let nights = try nights(endingOn: 14, count: 2)
    #expect(nights.map(\.day) == [utc(0, day: 14)])
    let night = try #require(nights.first)
    #expect(night.asleep == 4 * 3600)
    // From 23:00 to 03:15, not stretched to the nap.
    #expect(night.inBed == 4.25 * 3600)
    #expect(night.durations[.awake] == 0.25 * 3600)
    #expect(night.hasStages)
  }

  @Test
  func oneSourceANightAndInBedFromAll() throws {
    try database.write { db in
      try HealthSample.insert {
        // The Watch's stages, and the iPhone's rougher estimate of the same night.
        stage(3, from: utc(23, day: 13), hours: 6)
        stage(1, from: utc(23.5, day: 13), hours: 5, source: "com.apple.health.iphone")
        // In bed, recorded twice, overlapping.
        stage(0, from: utc(22.5, day: 13), hours: 7, source: "com.apple.health.iphone")
        stage(0, from: utc(23, day: 13), hours: 7.5)
      }.execute(db)
    }
    let night = try #require(try nights(endingOn: 14, count: 1).first)
    #expect(night.asleep == 6 * 3600)
    #expect(night.segments.map(\.stage) == [.core])
    // From 22:30 to 06:30, once.
    #expect(night.inBed == 8 * 3600)
  }

  @Test
  func inBedCountsWhereverItStarts() throws {
    try database.write { db in
      try HealthSample.insert {
        // In bed from 17:45, before the 6 PM boundary, on the iPhone.
        stage(0, from: utc(17.75, day: 13), hours: 13.25, source: "com.apple.health.iphone")
        stage(3, from: utc(22, day: 13), hours: 8)
      }.execute(db)
    }
    let night = try #require(try nights(endingOn: 14, count: 1).first)
    #expect(night.inBed == 13.25 * 3600)
  }

  @Test
  func withoutInBedTheNightSpansItsStages() throws {
    try database.write { db in
      try HealthSample.insert {
        stage(1, from: utc(23, day: 13), hours: 3)
        stage(1, from: utc(3, day: 14), hours: 3)
      }.execute(db)
    }
    let night = try #require(try nights(endingOn: 14, count: 1).first)
    #expect(night.asleep == 6 * 3600)
    #expect(night.inBed == 7 * 3600)
    #expect(!night.hasStages)
  }
}

@Suite
struct WorkoutQueriesTests {
  let database: any DatabaseWriter

  init() throws {
    database = try HealthDatabase.make()
  }

  private func workout(_ id: String, at start: Date, minutes: Double = 30) -> HealthWorkout {
    HealthWorkout(
      id: id, activityType: 37, startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, duration: minutes * 60,
      activities: "[]",
      events: #"[{"type":7,"startDate":0,"endDate":60000,"metadata":null}]"#,
      statistics:
        #"{"HKQuantityTypeIdentifierDistanceWalkingRunning":{"unit":"m","sum":5000,"average":null,"minimum":null,"maximum":null,"mostRecent":null}}"#,
      sourceName: "Test", sourceBundleID: "com.example")
  }

  @Test
  func workoutsGoNewestFirstAndDecodeTheirJSON() throws {
    try database.write { db in
      try HealthWorkout.insert {
        workout("a", at: utc(8, day: 12))
        workout("b", at: utc(8, day: 14))
        workout("c", at: utc(8, day: 13))
      }.execute(db)
    }
    let workouts = try database.read { db in try HealthDatabase.workouts(limit: 2, db) }
    #expect(workouts.map(\.id) == ["b", "c"])
    let older = try database.read { db in
      try HealthDatabase.workouts(before: utc(8, day: 13), limit: 10, db)
    }
    #expect(older.map(\.id) == ["a"])
    let first = try #require(workouts.first)
    #expect(first.decodedStatistics["HKQuantityTypeIdentifierDistanceWalkingRunning"]?.sum == 5000)
    #expect(first.decodedEvents.map(\.type) == [WorkoutEvent.segment])
    #expect(first.elapsed == 30 * 60)
  }

  @Test
  func aRouteIsLinkedOrRecordedDuringTheWorkout() throws {
    let running = workout("run", at: utc(8))
    try database.write { db in
      try HealthWorkout.insert { running }.execute(db)
      try HealthWorkoutRoute.insert {
        HealthWorkoutRoute(
          id: "unlinked", startDate: utc(8.1).unixMilliseconds, endDate: utc(8.4).unixMilliseconds,
          workout: nil, locationCount: 2, locations: "abc", sourceName: "Test",
          sourceBundleID: "com.example")
      }.execute(db)
    }
    #expect(try database.read { try HealthDatabase.route(of: running, $0) }?.id == "unlinked")
    try database.write { db in
      try HealthWorkoutRoute.insert {
        HealthWorkoutRoute(
          id: "linked", startDate: utc(8).unixMilliseconds, endDate: utc(8.5).unixMilliseconds,
          workout: "run", locationCount: 2, locations: "def", sourceName: "Test",
          sourceBundleID: "com.example")
      }.execute(db)
    }
    #expect(try database.read { try HealthDatabase.route(of: running, $0) }?.id == "linked")
  }

  @Test
  func aRouteOverlappingTheWorkoutCounts() throws {
    let running = workout("run", at: utc(8))
    try database.write { db in
      try HealthWorkout.insert { running }.execute(db)
      try HealthWorkoutRoute.insert {
        // Ends a little after the workout.
        HealthWorkoutRoute(
          id: "overlapping", startDate: utc(8.1).unixMilliseconds,
          endDate: utc(8.6).unixMilliseconds, workout: nil, locationCount: 2, locations: "abc",
          sourceName: "Test", sourceBundleID: "com.example")
      }.execute(db)
    }
    #expect(try database.read { try HealthDatabase.route(of: running, $0) }?.id == "overlapping")
  }

  @Test
  func pausesRunFromPauseToResume() {
    var paused = workout("run", at: utc(8))
    let start = paused.startDate
    paused.events =
      #"[{"type":1,"startDate":\#(start + 60_000),"endDate":\#(start + 60_000)},{"type":2,"startDate":\#(start + 120_000),"endDate":\#(start + 120_000)},{"type":5,"startDate":\#(start + 600_000),"endDate":\#(start + 600_000)}]"#
    #expect(
      paused.pauses.map(\.duration) == [60, Double(paused.endDate - start - 600_000) / 1000])
  }

  @Test
  func routeBlobsDecodeAndSplitByKilometer() {
    // Synthetic: north from (0, 0), 0.0045° (about 500 m) every 150 seconds.
    var blob = Data()
    for index in 0..<5 {
      func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { blob.append(contentsOf: $0) }
      }
      append((1_760_400_000 + Double(index) * 150).bitPattern)
      append((Double(index) * 0.0045).bitPattern)
      append(Double(0).bitPattern)
      append(Float(10).bitPattern)
      append(Float(5).bitPattern)
      append(Float(5).bitPattern)
      append(Float(3.3).bitPattern)
      append(Float(0).bitPattern)
    }
    // A partial record at the end is left out.
    blob.append(contentsOf: [1, 2, 3])
    let locations = HealthDatabase.routeLocations(blob)
    #expect(locations.count == 5)
    #expect(abs(locations[2].latitude - 0.009) < 1e-12)
    #expect(abs(locations[0].speed - 3.3) < 1e-6)
    let splits = HealthDatabase.splits(locations)
    // About 2 km: one full kilometer at about 300 seconds, the rest carried into the next.
    #expect(splits.first?.distance == 1000)
    #expect(splits.allSatisfy { abs($0.pace - 300) < 3 })
    // Every meter counts once: the splits add up to the route.
    let total = zip(locations, locations.dropFirst()).reduce(0) {
      $0 + HealthDatabase.distance($1.0, $1.1)
    }
    #expect(abs(splits.map(\.distance).reduce(0, +) - total) < 0.01)
  }

  @Test
  func pausedTimeIsntPartOfASplit() {
    // Synthetic: 2 km due north at 5 m/s, with a 4-minute pause during the first kilometer.
    let start = Date(timeIntervalSince1970: 1_760_400_000)
    let step = 0.0009  // about 100 m
    var locations: [RouteLocation] = []
    var time = start
    for index in 0...20 {
      locations.append(
        RouteLocation(
          time: time, latitude: Double(index) * step, longitude: 0, altitude: 0, speed: 5))
      time = time.addingTimeInterval(index == 4 ? 240 + 20 : 20)
    }
    let pause = DateInterval(start: start.addingTimeInterval(100), duration: 240)
    let splits = HealthDatabase.splits(locations, pauses: [pause])
    #expect(abs(splits[0].duration - 200) < 2)
    #expect(abs(splits[1].duration - 200) < 2)
  }
}

@Suite
struct HealthSyncTests {
  @Test
  func appliesEveryHealthEntity() async throws {
    let database = try HealthDatabase.make()
    try await database.write { db in
      try #sql(
        """
        INSERT INTO lilSyncState (id, cursor, epoch, syncSchema)
        VALUES (1, 0, 1, \(HealthDatabase.syncSchema))
        """
      )
      .execute(db)
    }
    let sampleID = "6f1c2a40-0000-4000-8000-000000000001"
    let changes: [Components.Schemas.Change] = try [
      upsert(
        1, "health_sample", sampleID,
        """
        "type": "HKQuantityTypeIdentifierStepCount", "startDate": 1760400000000,
        "endDate": 1760400600000, "value": 412, "unit": "count",
        "sourceName": "Test Watch", "sourceBundleId": "com.example.watch",
        "metadata": {"HKWasUserEntered": false, "HKTimeZone": "Europe/Bucharest"},
        "device": null, "provenance": "0123456789abcdef0123456789abcdef",
        "fieldFromTheFuture": "ignored"
        """),
      upsert(
        2, "health_statistic", "\(device)/HKQuantityTypeIdentifierStepCount@1760400000000",
        """
        "device": "\(device)", "type": "HKQuantityTypeIdentifierStepCount",
        "bucketStart": 1760400000000, "sum": 1234, "unit": "count"
        """),
      upsert(
        3, "health_statistics_device", device,
        #""device": "\#(device)", "pairedWithWatch": true, "reportedAt": 1760400000000"#),
      upsert(
        4, "health_characteristic", "HKCharacteristicTypeIdentifierDateOfBirth",
        #""value": {"year": 1990, "month": 4, "day": 2}"#),
      upsert(
        5, "health_activity_summary", "2025-10-14", #""activeEnergyBurned": 512.5, "paused": false"#
      ),
      upsert(
        6, "health_correlation", "6f1c2a40-0000-4000-8000-000000000002",
        """
        "type": "HKCorrelationTypeIdentifierBloodPressure", "startDate": 1760400000000,
        "endDate": 1760400000000, "sourceName": "Monitor", "sourceBundleId": "com.example"
        """),
      Components.Schemas.Change(
        seq: 7, entity: "health_correlation", id: "6f1c2a40-0000-4000-8000-000000000002",
        op: "delete", at: 1_760_400_000_000),
      upsert(
        8, "health_workout", "6f1c2a40-0000-4000-8000-000000000003",
        """
        "activityType": 37, "startDate": 1760400000000, "endDate": 1760401800000,
        "duration": 1740, "activities": [], "events": [{"type": 1}],
        "statistics": {"HKQuantityTypeIdentifierActiveEnergyBurned": {"unit": "kcal", "sum": 312.5}},
        "sourceName": "Test Watch", "sourceBundleId": "com.example.watch"
        """),
      upsert(
        9, "health_state_of_mind", "6f1c2a40-0000-4000-8000-000000000004",
        """
        "startDate": 1760400000000, "endDate": 1760400000000, "kind": 2, "valence": 0.4,
        "valenceClassification": 5, "labels": [10], "associations": [6],
        "sourceName": "Test iPhone", "sourceBundleId": "com.example"
        """),
      upsert(
        10, "health_scored_assessment", "6f1c2a40-0000-4000-8000-000000000005",
        """
        "type": "HKScoredAssessmentTypeIdentifierGAD7", "startDate": 1760400000000,
        "endDate": 1760400000000, "score": 6, "risk": 2, "answers": [1, 1, 0, 1, 2, 0, 1],
        "sourceName": "Test iPhone", "sourceBundleId": "com.example"
        """),
      upsert(
        11, "health_audiogram", "6f1c2a40-0000-4000-8000-000000000006",
        """
        "startDate": 1760400000000, "endDate": 1760400000000,
        "points": [{"frequency": 1000, "tests": [{"side": 0, "sensitivity": 20}]}],
        "sourceName": "Test iPhone", "sourceBundleId": "com.example"
        """),
      upsert(
        12, "health_electrocardiogram", "6f1c2a40-0000-4000-8000-000000000007",
        """
        "startDate": 1760400000000, "endDate": 1760400030000, "classification": 1,
        "symptomsStatus": 1, "averageHeartRate": 62, "samplingFrequency": 512,
        "voltageCount": 15360, "voltages": "\(String(repeating: "a", count: 64))",
        "sourceName": "Test Watch", "sourceBundleId": "com.example"
        """),
      upsert(
        13, "health_heartbeat_series", "6f1c2a40-0000-4000-8000-000000000008",
        """
        "startDate": 1760400000000, "endDate": 1760400060000, "beats": [0, 0.82, 1.65],
        "gaps": [2], "sourceName": "Test Watch", "sourceBundleId": "com.example"
        """),
      upsert(
        14, "health_workout_route", "6f1c2a40-0000-4000-8000-000000000009",
        """
        "startDate": 1760400000000, "endDate": 1760403600000,
        "workout": "6f1c2a40-0000-4000-8000-000000000004", "locationCount": 3600,
        "locations": "\(String(repeating: "b", count: 64))",
        "sourceName": "Test Watch", "sourceBundleId": "com.example"
        """),
      upsert(
        15, "health_provenance", "0123456789abcdef0123456789abcdef",
        """
        "sourceRevision": {"version": "11.0"}, "device": {"name": "Apple Watch"}
        """),
      upsert(
        16, "health_vision_prescription", "6f1c2a40-0000-4000-8000-00000000000a",
        """
        "startDate": 1760400000000, "endDate": 1760400000000, "prescriptionType": 2,
        "expirationDate": null, "brand": "Synthetic", "rightEye": {"sphere": -2.25},
        "leftEye": null, "sourceName": "Test iPhone", "sourceBundleId": "com.example"
        """),
      upsert(
        17, "health_medication", String(repeating: "c", count: 64),
        """
        "name": "Synthetic 10 mg Tablet", "nickname": null, "generalForm": "tablet",
        "isArchived": false, "hasSchedule": true,
        "codings": [{"system": "http://example.com/codes", "version": null, "code": "12345"}]
        """),
      upsert(
        18, "health_medication_dose", "6f1c2a40-0000-4000-8000-00000000000b",
        """
        "startDate": 1760400000000, "endDate": 1760400000000,
        "medication": "\(String(repeating: "c", count: 64))", "logStatus": 4,
        "scheduleType": 2, "scheduledDate": 1760399100000, "scheduledDoseQuantity": 1,
        "doseQuantity": 1, "unit": "count", "sourceName": "Test iPhone",
        "sourceBundleId": "com.example"
        """),
      upsert(
        19, "health_document", "6f1c2a40-0000-4000-8000-00000000000c",
        """
        "startDate": 1760400000000, "endDate": 1760403600000,
        "title": "Synthetic Visit Summary", "patientName": "Test Patient",
        "authorName": "", "custodianName": "Example Clinic",
        "xml": "\(String(repeating: "d", count: 64))",
        "sourceName": "Test iPhone", "sourceBundleId": "com.example"
        """),
      upsert(
        20, "health_document", "6f1c2a40-0000-4000-8000-00000000000d",
        """
        "startDate": 1760400000000, "endDate": 1760403600000, "title": "Deleted",
        "patientName": "", "authorName": "", "custodianName": "",
        "xml": "\(String(repeating: "e", count: 64))",
        "sourceName": "Test iPhone", "sourceBundleId": "com.example"
        """),
      Components.Schemas.Change(
        seq: 21, entity: "health_document", id: "6f1c2a40-0000-4000-8000-00000000000d",
        op: "delete", at: 1_760_400_000_000),
    ]
    let api = Client.mock { request, _ in
      #expect(request.path?.hasPrefix("/v1/sync/changes") == true)
      return (
        HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
        HTTPBody(
          try JSONEncoder().encode(
            Components.Schemas.ChangesPage(
              epoch: 1, changes: changes, next: 21, head: 21, hasMore: false)))
      )
    }
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = api
      $0.continuousClock = RecordingClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SplitMix64(seed: "test"))
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      LilSyncEngine(
        entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema)
    }
    try await engine.pull()

    let (stored, statistics, devices, characteristics, summaries, correlations) =
      try await database.read { db in
        (
          try HealthSample.find(sampleID).fetchOne(db), try HealthStatistic.fetchCount(db),
          try HealthStatisticsDevice.fetchAll(db), try HealthCharacteristic.fetchAll(db),
          try HealthActivitySummary.fetchAll(db), try HealthCorrelation.fetchCount(db)
        )
      }
    let sample = try #require(stored)
    #expect(sample.value == 412)
    #expect(sample.provenance == "0123456789abcdef0123456789abcdef")
    let provenances = try await database.read { db in try HealthProvenance.fetchAll(db) }
    #expect(
      provenances == [
        HealthProvenance(
          id: "0123456789abcdef0123456789abcdef", sourceRevision: #"{"version":"11.0"}"#,
          device: #"{"name":"Apple Watch"}"#)
      ])
    #expect(sample.metadata == #"{"HKTimeZone":"Europe/Bucharest","HKWasUserEntered":false}"#)
    #expect(sample.device == nil)
    #expect(statistics == 1)
    #expect(devices.map(\.pairedWithWatch) == [true])
    #expect(characteristics.map(\.value) == [#"{"day":2,"month":4,"year":1990}"#])
    #expect(summaries.map(\.activeEnergyBurned) == [512.5])
    #expect(correlations == 0)
    let workouts = try await database.read { db in try HealthWorkout.fetchAll(db) }
    #expect(workouts.map(\.activityType) == [37])
    let (moods, assessments) = try await database.read { db in
      (try HealthStateOfMind.fetchAll(db), try HealthScoredAssessment.fetchAll(db))
    }
    #expect(moods.map(\.labels) == ["[10]"])
    #expect(assessments.map(\.score) == [6])
    #expect(assessments.first?.answers == "[1,1,0,1,2,0,1]")
    let audiograms = try await database.read { db in try HealthAudiogram.fetchAll(db) }
    #expect(
      audiograms.first?.points == #"[{"frequency":1000,"tests":[{"sensitivity":20,"side":0}]}]"#)
    let ecgs = try await database.read { db in try HealthElectrocardiogram.fetchAll(db) }
    #expect(ecgs.map(\.voltages) == [String(repeating: "a", count: 64)])
    #expect(ecgs.map(\.averageHeartRate) == [62])
    let series = try await database.read { db in try HealthHeartbeatSeries.fetchAll(db) }
    #expect(series.map(\.beats) == ["[0,0.82,1.65]"])
    #expect(series.map(\.gaps) == ["[2]"])
    let prescriptions = try await database.read { db in
      try HealthVisionPrescription.fetchAll(db)
    }
    #expect(prescriptions.map(\.brand) == ["Synthetic"])
    #expect(prescriptions.map(\.rightEye) == [#"{"sphere":-2.25}"#])
    #expect(prescriptions.map(\.leftEye) == [nil])
    let medications = try await database.read { db in try HealthMedication.fetchAll(db) }
    #expect(medications.map(\.name) == ["Synthetic 10 mg Tablet"])
    #expect(medications.map(\.hasSchedule) == [true])
    #expect(
      medications.map(\.codings)
        == [#"[{"code":"12345","system":"http://example.com/codes","version":null}]"#])
    let doses = try await database.read { db in try HealthMedicationDose.fetchAll(db) }
    #expect(doses.map(\.medication) == [String(repeating: "c", count: 64)])
    #expect(doses.map(\.logStatus) == [4])
    #expect(doses.map(\.scheduledDate) == [1_760_399_100_000])
    let documents = try await database.read { db in try HealthDocument.fetchAll(db) }
    #expect(documents.map(\.title) == ["Synthetic Visit Summary"])
    #expect(documents.map(\.custodianName) == ["Example Clinic"])
    #expect(documents.map(\.authorName) == [""])
    #expect(documents.map(\.xml) == [String(repeating: "d", count: 64)])
    let routes = try await database.read { db in try HealthWorkoutRoute.fetchAll(db) }
    #expect(routes.map(\.locationCount) == [3600])
    #expect(routes.map(\.workout) == ["6f1c2a40-0000-4000-8000-000000000004"])
    #expect(routes.map(\.locations) == [String(repeating: "b", count: 64)])
    #expect(workouts.first?.events == #"[{"type":1}]"#)
    #expect(
      workouts.first?.statistics
        == #"{"HKQuantityTypeIdentifierActiveEnergyBurned":{"sum":312.5,"unit":"kcal"}}"#)
  }

  @Test
  func preparedUpsertsCoverEveryColumnAndUpdateRows() async throws {
    let database = try HealthDatabase.make()
    let columns = { (table: String) in
      try database.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('\(table)') ORDER BY cid")
      }
    }
    // Every synced table's upsert writes all of its columns.
    func writable<Record: Table>(_: Record.Type) -> (String, [String]) {
      (Record.tableName, Record.TableColumns.writableColumns.map(\.name))
    }
    let tables = [
      writable(HealthPin.self), writable(HealthProvenance.self), writable(HealthSample.self),
      writable(HealthCorrelation.self),
      writable(HealthCharacteristic.self), writable(HealthActivitySummary.self),
      writable(HealthStatistic.self), writable(HealthWorkout.self),
      writable(HealthStateOfMind.self), writable(HealthScoredAssessment.self),
      writable(HealthAudiogram.self), writable(HealthElectrocardiogram.self),
      writable(HealthWorkoutRoute.self), writable(HealthHeartbeatSeries.self),
      writable(HealthStatisticsDevice.self), writable(HealthVisionPrescription.self),
      writable(HealthMedication.self), writable(HealthMedicationDose.self),
      writable(HealthDocument.self),
    ]
    #expect(Set(tables.map(\.0)).count == HealthDatabase.syncEntities.count)
    for (table, written) in tables {
      #expect(try Set(columns(table)) == Set(written), "\(table)")
    }
    #expect(
      PreparedUpsert<HealthStatistic>().sql == """
        INSERT INTO "healthStatistics" ("id", "device", "type", "bucketStart", "sum", "unit")
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT ("id") DO UPDATE SET "device" = excluded."device", \
        "type" = excluded."type", "bucketStart" = excluded."bucketStart", \
        "sum" = excluded."sum", "unit" = excluded."unit"
        """)

    let id = "6f1c2a40-0000-4000-8000-0000000000aa"
    // A distinct value in every column, so values bound in the wrong order show.
    let members = { (value: Int) in
      """
      "type": "HKQuantityTypeIdentifierStepCount", "startDate": 1760400000000,
      "endDate": 1760400600000, "value": \(value), "unit": "count", "categoryValue": 3,
      "correlationId": "6f1c2a40-0000-4000-8000-0000000000bb", "sourceName": "Test iPhone",
      "sourceBundleId": "com.apple.health", "sourceRevision": {"version": "26.0"},
      "device": {"name": "iPhone"}, "metadata": {"HKWasUserEntered": true}
      """
    }
    let statisticID =
      "dev_000000000000000000000000ph/HKQuantityTypeIdentifierStepCount@1760400000000"
    let changes = [
      try upsert(1, "health_sample", id, members(1)),
      try upsert(2, "health_sample", id, members(2)),
      try upsert(
        3, "health_statistic", statisticID,
        """
        "device": "dev_000000000000000000000000ph", "type": "HKQuantityTypeIdentifierStepCount",
        "bucketStart": 1760400000000, "sum": 41.5, "unit": "count"
        """),
    ]
    let api = Client.mock { _, _ in
      (
        HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
        HTTPBody(
          try JSONEncoder().encode(
            Components.Schemas.ChangesPage(
              epoch: 1, changes: changes, next: 3, head: 3, hasMore: false)))
      )
    }
    try await database.write { db in
      try #sql(
        """
        INSERT INTO lilSyncState (id, cursor, epoch, syncSchema)
        VALUES (1, 0, 1, \(HealthDatabase.syncSchema))
        """
      )
      .execute(db)
    }
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = api
      $0.continuousClock = RecordingClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SplitMix64(seed: "test"))
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      LilSyncEngine(entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema)
    }
    try await engine.pull()
    // The second upsert updated every column of the first.
    let (samples, statistics) = try await database.read { db in
      (try HealthSample.fetchAll(db), try HealthStatistic.fetchAll(db))
    }
    #expect(
      samples == [
        HealthSample(
          id: id, type: "HKQuantityTypeIdentifierStepCount", startDate: 1_760_400_000_000,
          endDate: 1_760_400_600_000, value: 2, unit: "count", categoryValue: 3,
          correlationID: "6f1c2a40-0000-4000-8000-0000000000bb", sourceName: "Test iPhone",
          sourceBundleID: "com.apple.health", sourceRevision: #"{"version":"26.0"}"#,
          device: #"{"name":"iPhone"}"#, metadata: #"{"HKWasUserEntered":true}"#)
      ])
    #expect(
      statistics == [
        HealthStatistic(
          id: statisticID, device: "dev_000000000000000000000000ph",
          type: "HKQuantityTypeIdentifierStepCount", bucketStart: 1_760_400_000_000, sum: 41.5,
          unit: "count")
      ])
  }

  @Test
  func preparedUpsertsStoreWhatTheyAreGivenInEveryTable() throws {
    let database = try HealthDatabase.make()
    let source = (name: "Watch", bundle: "com.apple.health", revision: #"{"v":1}"#)
    let device = #"{"name":"Watch"}"#
    let metadata = #"{"k":true}"#
    // Distinct values in every column, upserted, then upserted again changed, so values bound
    // to the wrong column or not updated show.
    func roundTrip<Record: PrimaryKeyedTable & Equatable>(_ make: (Int) -> Record) throws
    where Record.QueryOutput == Record, Record.PrimaryKey == String {
      let upsert = PreparedUpsert<Record>()
      for version in [1, 2] {
        let record = make(version)
        try database.write { db in try upsert.execute(record, db) }
        let stored = try database.read { db in try Record.all.fetchAll(db) }
        #expect(stored == [record])
      }
    }
    try roundTrip { v in HealthPin(id: "pin", position: Double(v)) }
    try roundTrip { v in HealthProvenance(id: "p", sourceRevision: "r\(v)", device: "d\(v)") }
    try roundTrip { v in
      HealthSample(
        id: "s", type: "t\(v)", startDate: 10 + v, endDate: 20 + v, value: Double(30 + v),
        unit: "u\(v)", categoryValue: 40 + v, correlationID: "c\(v)", sourceName: "n\(v)",
        sourceBundleID: "b\(v)", sourceRevision: "r\(v)", device: "d\(v)", metadata: "m\(v)",
        provenance: "p\(v)")
    }
    try roundTrip { v in
      HealthCorrelation(
        id: "c", type: "t\(v)", startDate: 10 + v, endDate: 20 + v, sourceName: "n\(v)",
        sourceBundleID: "b\(v)", sourceRevision: "r\(v)", device: "d\(v)", metadata: "m\(v)")
    }
    try roundTrip { v in HealthCharacteristic(id: "h", value: "\(v)") }
    try roundTrip { v in
      HealthActivitySummary(
        id: "a", activeEnergyBurned: Double(v), activeEnergyBurnedGoal: Double(10 + v),
        appleMoveTime: Double(20 + v), appleMoveTimeGoal: Double(30 + v),
        appleExerciseTime: Double(40 + v), appleExerciseTimeGoal: Double(50 + v),
        appleStandHours: Double(60 + v), appleStandHoursGoal: Double(70 + v),
        activityMoveMode: "m\(v)", paused: v == 1)
    }
    try roundTrip { v in
      HealthStatistic(
        id: "st", device: "d\(v)", type: "t\(v)", bucketStart: 10 + v, sum: Double(20 + v),
        unit: "u\(v)")
    }
    try roundTrip { v in
      HealthWorkout(
        id: "w", activityType: v, startDate: 10 + v, endDate: 20 + v, duration: Double(30 + v),
        activities: "a\(v)", events: "e\(v)", statistics: "s\(v)", sourceName: "n\(v)",
        sourceBundleID: "b\(v)", sourceRevision: "r\(v)", device: "d\(v)", metadata: "m\(v)")
    }
    try roundTrip { v in
      HealthStateOfMind(
        id: "som", startDate: 10 + v, endDate: 20 + v, kind: v, valence: Double(30 + v),
        valenceClassification: 40 + v, labels: "l\(v)", associations: "a\(v)",
        sourceName: source.name, sourceBundleID: source.bundle, sourceRevision: source.revision,
        device: device, metadata: "m\(v)")
    }
    try roundTrip { v in
      HealthScoredAssessment(
        id: "sa", type: "t\(v)", startDate: 10 + v, endDate: 20 + v, score: 30 + v, risk: 40 + v,
        answers: "a\(v)", sourceName: source.name, sourceBundleID: source.bundle,
        sourceRevision: source.revision, device: device, metadata: "m\(v)")
    }
    try roundTrip { v in
      HealthAudiogram(
        id: "au", startDate: 10 + v, endDate: 20 + v, points: "p\(v)", sourceName: source.name,
        sourceBundleID: source.bundle, sourceRevision: source.revision, device: device,
        metadata: "m\(v)")
    }
    try roundTrip { v in
      HealthElectrocardiogram(
        id: "e", startDate: 10 + v, endDate: 20 + v, classification: v, symptomsStatus: 30 + v,
        averageHeartRate: Double(40 + v), samplingFrequency: Double(50 + v),
        voltageCount: 60 + v, voltages: "v\(v)", sourceName: source.name,
        sourceBundleID: source.bundle, sourceRevision: source.revision, device: device,
        metadata: metadata)
    }
    try roundTrip { v in
      HealthWorkoutRoute(
        id: "wr", startDate: 10 + v, endDate: 20 + v, workout: "w\(v)", locationCount: 30 + v,
        locations: "l\(v)", sourceName: source.name, sourceBundleID: source.bundle,
        sourceRevision: source.revision, device: device, metadata: metadata)
    }
    try roundTrip { v in
      HealthHeartbeatSeries(
        id: "hb", startDate: 10 + v, endDate: 20 + v, beats: "b\(v)", gaps: "g\(v)",
        sourceName: source.name, sourceBundleID: source.bundle, sourceRevision: source.revision,
        device: device, metadata: metadata)
    }
    try roundTrip { v in
      HealthStatisticsDevice(id: "sd", device: "d\(v)", pairedWithWatch: v == 1, reportedAt: v)
    }
    try roundTrip { v in
      HealthMedication(
        id: "med", name: "n\(v)", nickname: "k\(v)", generalForm: "f\(v)", isArchived: v == 1,
        hasSchedule: v == 2, codings: "c\(v)")
    }
    try roundTrip { v in
      HealthMedicationDose(
        id: "dose", startDate: 10 + v, endDate: 20 + v, medication: "m\(v)", logStatus: 30 + v,
        scheduleType: 40 + v, scheduledDate: 50 + v, scheduledDoseQuantity: Double(60 + v),
        doseQuantity: Double(70 + v), unit: "u\(v)", sourceName: source.name,
        sourceBundleID: source.bundle, sourceRevision: source.revision, device: device,
        metadata: metadata, provenance: "p\(v)")
    }
    try roundTrip { v in
      HealthDocument(
        id: "doc", startDate: 10 + v, endDate: 20 + v, title: "t\(v)", patientName: "pa\(v)",
        authorName: "a\(v)", custodianName: "c\(v)", xml: "x\(v)", sourceName: source.name,
        sourceBundleID: source.bundle, sourceRevision: source.revision, device: device,
        metadata: metadata, provenance: "p\(v)")
    }
  }

  @Test
  func preparedUpsertsBindDatesAndEmptyBlobsAsStructuredQueriesDoes() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try #sql(
        #"CREATE TABLE "datedThings" ("id" TEXT PRIMARY KEY NOT NULL, "at" TEXT NOT NULL, "bytes" BLOB NOT NULL)"#
      )
      .execute(db)
    }
    let thing = DatedThing(id: "a", at: Date(timeIntervalSince1970: 1_760_400_000.5), bytes: [])
    try database.write { db in try PreparedUpsert<DatedThing>().execute(thing, db) }
    let viaPrepared = try database.read { db in
      try Row.fetchOne(db, sql: #"SELECT "at", "bytes" FROM "datedThings""#)
    }
    try database.write { db in
      try DatedThing.delete().execute(db)
      try DatedThing.upsert { thing }.execute(db)
    }
    let viaStructuredQueries = try database.read { db in
      try Row.fetchOne(db, sql: #"SELECT "at", "bytes" FROM "datedThings""#)
    }
    #expect(viaPrepared == viaStructuredQueries)
    #expect(try database.read { db in try DatedThing.all.fetchAll(db) } == [thing])
  }

  /// An upsert whose row is `id` plus the given JSON object members.
  private func upsert(
    _ seq: Int, _ entity: String, _ id: String, _ members: String
  ) throws -> Components.Schemas.Change {
    let row = try JSONDecoder().decode(
      OpenAPIObjectContainer.self, from: Data(#"{"id": "\#(id)", \#(members)}"#.utf8))
    return Components.Schemas.Change(
      seq: seq, entity: entity, id: id, op: "upsert", row: row, at: 1_760_400_000_000)
  }
}

@Suite
struct PreviewHealthDatabaseTests {
  @Test
  func coversEveryCategory() throws {
    let database = makePreviewHealthDatabase(now: now, calendar: calendar("UTC"))
    let (sampled, summed, source, summaries, correlations) = try database.read { db in
      (
        Set(try HealthSample.select(\.type).distinct().fetchAll(db)),
        Set(try HealthStatistic.select(\.type).distinct().fetchAll(db)),
        try HealthDatabase.statisticsSource(db, now: now),
        try HealthActivitySummary.fetchCount(db),
        try HealthCorrelation.fetchCount(db)
      )
    }
    // Categories with samples so far: medications get their own entities later.
    for category in HealthCategory.allCases {
      let types = Set(
        HealthCatalog.types(in: category).filter { [.quantity, .category].contains($0.kind) }
          .map(\.id))
      guard !types.isEmpty else { continue }
      #expect(!types.isDisjoint(with: sampled.union(summed)), "No preview data for \(category)")
    }
    #expect(source == device)
    #expect(summaries == 14)
    #expect(correlations == 7)
  }

  @Test
  func previewBucketsAreOnUTCHalfHoursEvenInQuarterHourZones() throws {
    let database = makePreviewHealthDatabase(now: now, calendar: calendar("Asia/Kathmandu"))
    let offGrid = try database.read { db in
      try HealthStatistic.all.fetchAll(db).filter { !$0.bucketStart.isMultiple(of: 1_800_000) }
    }
    #expect(offGrid.isEmpty)
  }
}

/// A table with the column kinds `PreparedUpsert` leaves to StructuredQueries.
@Table("datedThings")
private struct DatedThing: Equatable {
  let id: String
  var at: Date
  var bytes: [UInt8]
}

@Suite
struct ECGQueriesTests {
  @Test
  func voltagesDecodeAsLittleEndianFloats() {
    let microvolts: [Float] = [0, 1_000.5, -220, .nan, 42]
    var blob = Data()
    for value in microvolts {
      withUnsafeBytes(of: value.bitPattern.littleEndian) { blob.append(contentsOf: $0) }
    }
    // A stray byte past the last whole float is ignored.
    blob.append(0xFF)
    let decoded = HealthDatabase.electrocardiogramMicrovolts(blob)
    #expect(decoded.count == 5)
    #expect(decoded[1] == 1_000.5 && decoded[2] == -220 && decoded[4] == 42)
    #expect(decoded[3].isNaN)
  }

  @Test
  func thirtySecondsAreThreeStripsOfTen() {
    let trace = (0..<15_360).map { Float($0) }
    let strips = HealthDatabase.electrocardiogramStrips(
      trace, samplingFrequency: 512, seconds: 10)
    #expect(strips.map(\.count) == [5_120, 5_120, 5_120])
    #expect(strips.map { $0.first } == [0, 5_120, 10_240])
    // A shorter recording ends with a shorter strip.
    let short = HealthDatabase.electrocardiogramStrips(
      Array(trace.prefix(6_000)), samplingFrequency: 512, seconds: 10)
    #expect(short.map(\.count) == [5_120, 880])
  }

  @Test
  func theSampleRateComesFromTheCountWhenMissing() {
    var ecg = HealthElectrocardiogram(
      id: "a", startDate: 0, endDate: 30_000, classification: 1, symptomsStatus: 1,
      averageHeartRate: 70, samplingFrequency: 0, voltageCount: 15_000, voltages: nil,
      sourceName: "Watch", sourceBundleID: "com.apple.NanoHeartRhythm")
    #expect(ecg.measurementsPerSecond == 500)
    ecg.samplingFrequency = 512
    #expect(ecg.measurementsPerSecond == 512)
    ecg.samplingFrequency = nil
    ecg.voltageCount = 0
    #expect(ecg.measurementsPerSecond == 512)
  }

  @Test
  func classificationsAreNamedAsInHealth() {
    #expect(ECGClassification(rawValue: 1).name == "Sinus Rhythm")
    #expect(ECGClassification(rawValue: 2) == .atrialFibrillation)
    #expect(ECGClassification(rawValue: 2).isAlert)
    #expect(ECGClassification(rawValue: 5).name == "Poor Recording")
    #expect(ECGClassification(rawValue: 100) == .unrecognized)
    #expect(ECGClassification(rawValue: 0) == .notSet)
  }

  @Test
  func recordingsComeNewestFirst() throws {
    let database = try HealthDatabase.make()
    let ecg = { (id: String, start: Int, symptoms: Int) in
      HealthElectrocardiogram(
        id: id, startDate: start, endDate: start + 30_000, classification: 1,
        symptomsStatus: symptoms, averageHeartRate: 70, samplingFrequency: 512, voltageCount: 0,
        voltages: nil, sourceName: "Watch", sourceBundleID: "com.apple.NanoHeartRhythm")
    }
    try database.write { db in
      try HealthElectrocardiogram.insert {
        ecg("a", 1_000, 1)
        ecg("b", 3_000, 2)
        ecg("c", 2_000, 0)
      }
      .execute(db)
    }
    let recordings = try database.read { db in try HealthDatabase.electrocardiograms(limit: 2, db) }
    #expect(recordings.map(\.id) == ["b", "c"])
    #expect(recordings.map(\.hadSymptoms) == [true, nil])
  }
}

@Suite
struct HearingQueriesTests {
  private func audiogram(_ id: String, start: Int, points: String) -> HealthAudiogram {
    HealthAudiogram(
      id: id, startDate: start, endDate: start + 600_000, points: points, sourceName: "Test",
      sourceBundleID: "com.example.hearing")
  }

  @Test
  func eachEarsUnmaskedAirTestCounts() {
    let points = audiogram(
      "a", start: 0,
      points: """
        [{"frequency":500,"tests":[
          {"side":0,"type":1,"masked":false,"sensitivity":5,"clampingLower":null,"clampingUpper":null},
          {"side":0,"type":0,"masked":true,"sensitivity":15,"clampingLower":null,"clampingUpper":null},
          {"side":0,"type":0,"masked":false,"sensitivity":10,"clampingLower":null,"clampingUpper":null},
          {"side":1,"type":0,"masked":false,"sensitivity":20,"clampingLower":null,"clampingUpper":null}]},
         {"frequency":1000,"tests":[
          {"side":1,"type":0,"masked":false,"sensitivity":30,"clampingLower":null,"clampingUpper":null}]}]
        """
    ).decodedPoints
    #expect(
      points == [
        AudiogramPoint(frequency: 500, left: 10, right: 20),
        AudiogramPoint(frequency: 1_000, left: nil, right: 30),
      ])
    #expect(audiogram("b", start: 0, points: "not json").decodedPoints.isEmpty)
  }

  @Test
  func anUnreadablePointLeavesTheOthers() {
    let points = audiogram(
      "a", start: 0,
      points: """
        [{"frequency":500,"tests":[{"side":0,"sensitivity":10}]},
         {"frequency":"oops","tests":[]},
         {"frequency":1000,"tests":[{"side":"left","sensitivity":5},{"side":1,"sensitivity":20}]},
         {"frequency":2000,"tests":[{"side":1,"type":1,"masked":false,"sensitivity":5},
           {"side":1,"type":0,"masked":true,"sensitivity":40,"clampingLower":40,"clampingUpper":null}]}]
        """
    ).decodedPoints
    #expect(
      points == [
        AudiogramPoint(frequency: 500, left: 10, right: nil),
        AudiogramPoint(frequency: 1_000, left: nil, right: 20),
        // The masked air test over the other kind, and a bound, not a threshold.
        AudiogramPoint(frequency: 2_000, left: nil, right: 40, clamped: [.right]),
      ])
  }

  @Test
  func theHearingLevelIsTheSpeechRangesAverage() {
    let points = [
      AudiogramPoint(frequency: 250, left: 0, right: nil),
      AudiogramPoint(frequency: 500, left: 10, right: nil),
      AudiogramPoint(frequency: 1_000, left: 20, right: nil),
      AudiogramPoint(frequency: 2_000, left: 30, right: nil),
      AudiogramPoint(frequency: 4_000, left: 40, right: nil),
      AudiogramPoint(frequency: 8_000, left: 90, right: nil),
    ]
    #expect(points.averageHearingLevel(.left) == 25)
    // Whole decibels, so the number shown and its group agree.
    let edge = [25.0, 25, 25, 26].enumerated().map { index, level in
      AudiogramPoint(frequency: [500, 1_000, 2_000, 4_000][index], left: level, right: nil)
    }
    #expect(edge.averageHearingLevel(.left) == 25)
    #expect(HearingLevel(decibels: edge.averageHearingLevel(.left)!) == .normal)
    #expect(points.averageHearingLevel(.right) == nil)
    // Without speech frequencies, every frequency tested counts.
    let high = [
      AudiogramPoint(frequency: 6_000, left: 40, right: nil),
      AudiogramPoint(frequency: 8_000, left: 60, right: nil),
    ]
    #expect(high.averageHearingLevel(.left) == 50)
  }

  @Test
  func hearingLevelsAreGroupedAsInHealth() {
    #expect(HearingLevel(decibels: 25) == .normal)
    #expect(HearingLevel(decibels: 25.5) == .mild)
    #expect(HearingLevel(decibels: 60) == .moderate)
    #expect(HearingLevel(decibels: 61) == .severe)
    #expect(HearingLevel(decibels: 95) == .profound)
  }

  @Test
  func audiogramsComeNewestFirst() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthAudiogram.insert {
        audiogram("a", start: 1_000, points: "[]")
        audiogram("b", start: 3_000, points: "[]")
        audiogram("c", start: 2_000, points: "[]")
      }
      .execute(db)
    }
    let audiograms = try database.read { db in try HealthDatabase.audiograms(limit: 10, db) }
    #expect(audiograms.map(\.id) == ["b", "c", "a"])
  }
}

@Suite
struct MentalWellbeingQueriesTests {
  private func log(_ id: String, start: Int, labels: String, associations: String)
    -> HealthStateOfMind
  {
    HealthStateOfMind(
      id: id, startDate: start, endDate: start, kind: 2, valence: 0.4, valenceClassification: 5,
      labels: labels, associations: associations, sourceName: "Health",
      sourceBundleID: "com.apple.Health")
  }

  private func assessment(_ id: String, _ type: String, start: Int) -> HealthScoredAssessment {
    HealthScoredAssessment(
      id: id, type: type, startDate: start, endDate: start, score: 6, risk: 2, answers: "[]",
      sourceName: "Health", sourceBundleID: "com.apple.Health")
  }

  @Test
  func labelsAndAssociationsAreNamedByRawValue() {
    let entry = log("a", start: 0, labels: "[1,17,38,99]", associations: "[1,17,18,0]")
    // HealthKit numbers them from 1; values from a newer iOS are skipped.
    #expect(entry.labelNames == ["Amazed", "Happy", "Satisfied"])
    #expect(entry.associationNames == ["Community", "Work", "Weather"])
    #expect(entry.kindName == "Daily Mood")
    #expect(entry.decodedValenceClassification == .slightlyPleasant)
    #expect(log("b", start: 0, labels: "oops", associations: "[]").labelNames.isEmpty)
  }

  @Test
  func risksAreNamedPerQuestionnaire() {
    #expect(AssessmentKind.gad7.riskName(4) == "Severe")
    #expect(AssessmentKind.phq9.riskName(4) == "Moderately Severe")
    #expect(AssessmentKind.phq9.riskName(9) == "Unknown")
    #expect(AssessmentKind.gad7.maximumScore == 21 && AssessmentKind.phq9.maximumScore == 27)
  }

  @Test
  func eachQuestionnairesAssessmentsComeNewestFirst() throws {
    let database = try HealthDatabase.make()
    let (gad7, phq9) = (AssessmentKind.gad7.rawValue, AssessmentKind.phq9.rawValue)
    try database.write { db in
      try HealthScoredAssessment.insert {
        assessment("a", gad7, start: 1_000)
        assessment("b", phq9, start: 2_000)
        assessment("c", gad7, start: 3_000)
      }
      .execute(db)
      try HealthStateOfMind.insert {
        log("x", start: 1_000, labels: "[]", associations: "[]")
        log("y", start: 2_000, labels: "[]", associations: "[]")
      }
      .execute(db)
    }
    let found = try database.read { db in
      (
        try HealthDatabase.scoredAssessments(of: gad7, limit: 10, db).map(\.id),
        try HealthDatabase.stateOfMindLogs(limit: 10, db).map(\.id)
      )
    }
    #expect(found.0 == ["c", "a"])
    #expect(found.1 == ["y", "x"])
  }
}

@Suite
struct HeartQueriesTests {
  @Test
  func beatsBecomeHeartRatesAndVariability() {
    // Intervals of 1.0, 0.8, 1.2 s, then a gap, then 0.5 s.
    let analysis = HeartbeatAnalysis(beats: [0, 1, 1.8, 3, 10, 10.5], gaps: [4])
    #expect(analysis.beats.map(\.beatsPerMinute) == [60, 75, 50, 120])
    #expect(analysis.beats.map(\.run) == [0, 0, 0, 1])
    #expect(analysis.beatCount == 6)
    #expect(analysis.duration == 10.5)
    // Mean interval 0.875 s.
    #expect(abs((analysis.averageBeatsPerMinute ?? 0) - 60 / 0.875) < 0.0001)
    // Successive differences only within a run: -0.2 and +0.4 s.
    #expect(abs((analysis.rmssd ?? 0) - (0.1).squareRoot() * 1000) < 0.0001)
    let mean = 0.875
    let variance =
      [1.0, 0.8, 1.2, 0.5].map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 3
    #expect(abs((analysis.sdnn ?? 0) - variance.squareRoot() * 1000) < 0.0001)
  }

  @Test
  func tooFewBeatsHaveNoFigures() {
    let one = HeartbeatAnalysis(beats: [0], gaps: [])
    #expect(one.beats.isEmpty && one.averageBeatsPerMinute == nil && one.sdnn == nil)
    #expect(one.rmssd == nil)
    let two = HeartbeatAnalysis(beats: [0, 1], gaps: [])
    #expect(two.averageBeatsPerMinute == 60 && two.sdnn == nil && two.rmssd == nil)
  }

  @Test
  func seriesDecodeAndComeNewestFirst() throws {
    let series = { (id: String, start: Int) in
      HealthHeartbeatSeries(
        id: id, startDate: start, endDate: start + 60_000, beats: "[0,0.8,1.6]", gaps: "[]",
        sourceName: "Watch", sourceBundleID: "com.apple.health")
    }
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthHeartbeatSeries.insert {
        series("a", 1_000)
        series("b", 2_000)
      }
      .execute(db)
    }
    let found = try database.read { db in try HealthDatabase.heartbeatSeries(limit: 10, db) }
    #expect(found.map(\.id) == ["b", "a"])
    #expect(found.first?.analysis.averageBeatsPerMinute == 75)
    // Gaps that can't be read leave no intervals, not false ones across them.
    var broken = series("c", 0)
    broken.gaps = "oops"
    #expect(broken.analysis.beats.isEmpty && broken.analysis.beatCount == 3)
  }
}

@Suite
struct CycleQueriesTests {
  private let calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .gmt
    return c
  }()

  /// Noon UTC on day `n` of October 2025.
  private func day(_ n: Int) -> Date {
    calendar.date(from: DateComponents(year: 2025, month: 10, day: n, hour: 12))!
  }

  private func sample(
    _ id: String, _ type: String, day n: Int, value: Int?, endDay: Int? = nil,
    metadata: String? = nil
  ) -> HealthSample {
    HealthSample(
      id: id, type: type, startDate: day(n).unixMilliseconds,
      endDate: day(endDay ?? n).unixMilliseconds, categoryValue: value, sourceName: "Health",
      sourceBundleID: "com.apple.Health", metadata: metadata)
  }

  private func database(_ samples: [HealthSample]) throws -> any DatabaseWriter {
    let database = try HealthDatabase.make()
    try database.write { db in try HealthSample.insert { samples }.execute(db) }
    return database
  }

  @Test
  func daysGatherWhatWasLogged() throws {
    let flow = HealthDatabase.menstrualFlowType
    let database = try database([
      sample("a", flow, day: 3, value: 3),
      sample("b", flow, day: 3, value: 4),
      sample("c", flow, day: 4, value: 5),
      sample("c2", "HKCategoryTypeIdentifierBloating", day: 4, value: 3),
      // Logged as not present.
      sample("c3", "HKCategoryTypeIdentifierHeadache", day: 4, value: 1),
      sample("d", "HKCategoryTypeIdentifierIntermenstrualBleeding", day: 10, value: 0),
      sample("e", "HKCategoryTypeIdentifierOvulationTestResult", day: 15, value: 2),
      sample("f", "HKCategoryTypeIdentifierOvulationTestResult", day: 16, value: 1),
      sample("g", "HKCategoryTypeIdentifierHeadache", day: 3, value: 2),
      sample("h", "HKCategoryTypeIdentifierSexualActivity", day: 12, value: 0),
    ])
    let october = calendar.dateInterval(of: .month, for: day(1))!
    let days = try database.read { db in
      try HealthDatabase.cycleDays(in: october, calendar: calendar, db)
    }
    let start = { (n: Int) in self.calendar.startOfDay(for: self.day(n)) }
    // The heavier of two flows; "no flow" isn't a period day.
    #expect(days[start(3)] == CycleDay(flow: .heavy, symptoms: ["Headache"]))
    #expect(days[start(4)] == CycleDay(symptoms: ["Bloating"]))
    #expect(days[start(10)]?.spotting == true)
    #expect(days[start(15)]?.ovulationPositive == true)
    #expect(days[start(16)]?.ovulationPositive != true)
    #expect(days[start(12)]?.sexualActivity == true)
  }

  @Test
  func aDaysLogNamesEachValue() throws {
    let database = try database([
      sample("a", "HKCategoryTypeIdentifierCervicalMucusQuality", day: 5, value: 5),
      sample("b", "HKCategoryTypeIdentifierOvulationTestResult", day: 5, value: 1),
      sample("c", "HKCategoryTypeIdentifierPregnancyTestResult", day: 5, value: 2),
      sample("d", "HKCategoryTypeIdentifierBleedingDuringPregnancy", day: 6, value: 3),
      // No bleeding isn't marked, but it's in the log.
      sample("e", "HKCategoryTypeIdentifierBleedingAfterMenopause", day: 7, value: 5),
      sample("f", "HKCategoryTypeIdentifierContraceptive", day: 8, value: 6, endDay: 30),
      // Spans months: its first day says so, until it has a section (851-2871).
      sample("g", "HKCategoryTypeIdentifierIrregularMenstrualCycles", day: 9, value: 0),
    ])
    let october = calendar.dateInterval(of: .month, for: day(1))!
    let days = try database.read { db in
      try HealthDatabase.cycleDays(in: october, calendar: calendar, db)
    }
    let start = { (n: Int) in self.calendar.startOfDay(for: self.day(n)) }
    #expect(
      days[start(5)]?.log == [
        CycleLogEntry(name: "Cervical Mucus Quality", value: "Egg White"),
        CycleLogEntry(name: "Ovulation Test Result", value: "Negative"),
        CycleLogEntry(name: "Pregnancy Test Result", value: "Positive"),
      ])
    #expect(days[start(5)]?.ovulationPositive == false)
    #expect(
      days[start(6)]
        == CycleDay(
          bleeding: true, log: [.init(name: "Bleeding During Pregnancy", value: "Medium")]))
    #expect(days[start(7)]?.bleeding == false)
    #expect(days[start(7)]?.log == [.init(name: "Bleeding After Menopause", value: "None")])
    #expect(days[start(8)]?.log == [.init(name: "Contraceptives", value: "Oral")])
    #expect(days[start(9)]?.log == [.init(name: "Irregular Cycles", value: nil)])
  }

  @Test
  func valuesAreNamedAsHealthNamesThem() {
    let name = HealthDatabase.categoryValueName
    #expect(name(4, "HKCategoryTypeIdentifierOvulationTestResult") == "Estrogen Surge")
    #expect(name(2, "HKCategoryTypeIdentifierOvulationTestResult") == "Positive (LH Surge)")
    #expect(name(3, "HKCategoryTypeIdentifierProgesteroneTestResult") == "Indeterminate")
    #expect(name(1, "HKCategoryTypeIdentifierCervicalMucusQuality") == "Dry")
    #expect(name(4, HealthDatabase.menstrualFlowType) == "Heavy Flow")
    #expect(name(4, "HKCategoryTypeIdentifierBleedingAfterPregnancy") == "Heavy")
    // Unspecified, or nothing to name.
    #expect(name(1, "HKCategoryTypeIdentifierBleedingAfterPregnancy") == nil)
    #expect(name(1, "HKCategoryTypeIdentifierContraceptive") == nil)
    #expect(name(0, "HKCategoryTypeIdentifierSexualActivity") == nil)
    #expect(name(nil, "HKCategoryTypeIdentifierCervicalMucusQuality") == nil)
  }

  @Test
  func everyCycleCategoryTypeOpensCycleTrackingOnItsLatestSample() throws {
    let cycleTypes = HealthCatalog.all.filter { $0.category == .cycleTracking }
    let opening = cycleTypes.filter { HealthDatabase.opensCycleTracking($0.id) }.map(\.id)
    #expect(opening.count == cycleTypes.count - 1)
    #expect(!opening.contains("HKQuantityTypeIdentifierBasalBodyTemperature"))
    #expect(!HealthDatabase.opensCycleTracking("HKCategoryTypeIdentifierHeadache"))

    let mucus = "HKCategoryTypeIdentifierCervicalMucusQuality"
    let database = try database([
      sample("a", mucus, day: 3, value: 2), sample("b", mucus, day: 12, value: 4),
    ])
    // Not one dated later than now.
    let latest = try database.read { db in
      try HealthDatabase.latestSample(of: mucus, startedBy: day(10), db)?.start
    }
    #expect(latest == day(3))
  }

  @Test
  func periodsAreRunsOfFlowDaysWithTheirCycles() throws {
    let flow = HealthDatabase.menstrualFlowType
    let database = try database(
      [1, 2, 3].map { sample("p\($0)", flow, day: $0, value: 3) }
        + [29, 30].map { sample("q\($0)", flow, day: $0, value: 2) }
        // "No flow" isn't a period day.
        + [sample("x", flow, day: 31, value: 5)])
    let periods = try database.read { db in
      try HealthDatabase.periods(limit: 10, calendar: calendar, db)
    }
    #expect(periods.count == 2)
    #expect(periods[0].start == calendar.startOfDay(for: day(29)))
    #expect(periods[0].length(calendar) == 2 && periods[0].cycleLength == nil)
    #expect(periods[1].length(calendar) == 3 && periods[1].cycleLength == 28)
  }

  @Test
  func aCycleStartSplitsBackToBackPeriods() throws {
    let flow = HealthDatabase.menstrualFlowType
    for start in [#"{"HKMenstrualCycleStart":true}"#, #"{"HKMenstrualCycleStart":1}"#] {
      let database = try database([
        sample("a", flow, day: 1, value: 3), sample("b", flow, day: 2, value: 3),
        sample("c", flow, day: 3, value: 3, metadata: start),
      ])
      let periods = try database.read { db in
        try HealthDatabase.periods(limit: 10, calendar: calendar, db)
      }
      #expect(periods.map { $0.length(calendar) } == [1, 2], "\(start)")
      #expect(periods.last?.cycleLength == 2)
    }
  }

  @Test
  func factorsAreThoseGoingOnNow() throws {
    let database = try database([
      sample("a", "HKCategoryTypeIdentifierContraceptive", day: 1, value: 6, endDay: 30),
      sample("b", "HKCategoryTypeIdentifierLactation", day: 1, value: 0, endDay: 5),
      // No end yet.
      sample("c", "HKCategoryTypeIdentifierPregnancy", day: 2, value: 0),
    ])
    let factors = try database.read { db in try HealthDatabase.cycleFactors(at: day(10), db) }
    #expect(factors.map(\.name) == ["Pregnancy", "Contraceptives"])
    #expect(factors.last?.detail == "Oral")
  }
}

// Synthetic data only (AGENTS.md).
@Suite
struct CategoryChartTests {
  private let calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .gmt
    return c
  }()

  /// Wednesday, October 15, 2025, at `hour`:`minute` UTC, plus `days`.
  private func time(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(year: 2025, month: 10, day: 15 + days, hour: hour, minute: minute))!
  }

  private var now: Date { time(23, days: 0) }

  private func sample(
    _ id: String, _ type: String, from start: Date, to end: Date, value: Int = 0,
    source: String = "Watch"
  ) -> HealthSample {
    HealthSample(
      id: id, type: type, startDate: start.unixMilliseconds, endDate: end.unixMilliseconds,
      categoryValue: value, sourceName: source, sourceBundleID: "com.example.\(source)")
  }

  private func chart(
    _ type: String, _ range: ChartRange, _ samples: [HealthSample]
  ) throws -> MetricChart {
    let database = try HealthDatabase.make()
    try database.write { db in try HealthSample.insert { samples }.execute(db) }
    return try database.read { db in
      try HealthDatabase.categoryChart(
        of: type, range: range, offset: 0, now: now, calendar: calendar, db)
    }
  }

  @Test
  func standHoursCountTheHoursStood() throws {
    let stand = HealthDatabase.standHourType
    let samples = [
      sample("a", stand, from: time(9), to: time(10)),
      sample("b", stand, from: time(10), to: time(11)),
      // Idle.
      sample("c", stand, from: time(11), to: time(12), value: 1),
      sample("d", stand, from: time(9, days: -1), to: time(10, days: -1)),
    ]
    let day = try chart(stand, .day, samples)
    #expect(day.points.map(\.start) == [time(9), time(10)])
    #expect(day.points.map(\.value) == [1, 1])
    #expect(day.summary == .total(2))

    let week = try chart(stand, .week, samples)
    #expect(week.points.map(\.value) == [1, 2])
    #expect(week.summary == .dailyAverage(1.5))
  }

  @Test
  func overlappingMindfulSessionsCountOnce() throws {
    let mindful = HealthDatabase.mindfulSessionType
    let samples = [
      sample("a", mindful, from: time(10), to: time(10, 20), source: "Mindfulness"),
      // Another app's session, overlapping the first.
      sample("b", mindful, from: time(10, 10), to: time(10, 30), source: "Journal"),
      // Across an hour.
      sample("c", mindful, from: time(10, 50), to: time(11, 10)),
    ]
    let day = try chart(mindful, .day, samples)
    #expect(day.points.map(\.start) == [time(10), time(11)])
    #expect(day.points.map(\.value) == [40, 10])
    #expect(day.summary == .total(50))
    #expect(try chart(mindful, .week, samples).points.map(\.value) == [50])
  }

  @Test
  func handwashingCountsSessionsWithTheirAverageLength() throws {
    let handwashing = HealthDatabase.handwashingType
    let samples = [
      sample("a", handwashing, from: time(8), to: time(8, 0).addingTimeInterval(20)),
      sample("b", handwashing, from: time(12), to: time(12).addingTimeInterval(30)),
      sample(
        "c", handwashing, from: time(12, days: -1), to: time(12, days: -1).addingTimeInterval(10)),
    ]
    let week = try chart(handwashing, .week, samples)
    #expect(week.points.map(\.value) == [1, 2])
    #expect(week.summary == .averageDuration(20))
    #expect(try chart(handwashing, .day, samples).summary == .averageDuration(25))
  }

  @Test
  func longerPeriodsChartTheAverageDay() throws {
    let toothbrushing = HealthDatabase.toothbrushingType
    // Two sessions a day for three days in the week, one on another day of the month.
    let samples =
      (0..<3).flatMap { day in
        [8, 21].map { hour in
          sample(
            "\(day)-\(hour)", toothbrushing, from: time(hour, days: -day),
            to: time(hour, 2, days: -day))
        }
      } + [sample("x", toothbrushing, from: time(8, days: -10), to: time(8, 2, days: -10))]
    // Six months by week: the week of the 5th (one day, one session), then this week (three
    // days of two).
    let sixMonths = try chart(toothbrushing, .sixMonths, samples)
    #expect(sixMonths.points.map(\.value) == [1, 2])
    // A year by month: October's average day, 7 sessions over 4 days.
    #expect(try chart(toothbrushing, .year, samples).points.map(\.value) == [7.0 / 4])
  }

  @Test
  func everyChartedTypeHasAUnit() {
    for type in HealthDatabase.categoryChartTypes {
      #expect(HealthDatabase.categoryChartUnit(type) != nil)
    }
  }
}
