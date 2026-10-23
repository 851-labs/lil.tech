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

  /// A line's (or dots') period is its average over every reading, not over the days' averages,
  /// as Health's weight is (851-3097).
  @Test
  func aLineTypeChartsEachBucketsAverageAndThePeriodsAverage() throws {
    let weight = try #require(HealthCatalog.type(id: "HKQuantityTypeIdentifierBodyMass"))
    #expect(weight.chartStyle == .line)
    try database.write { db in
      try HealthSample.insert {
        sample(weight.id, at: utc(7, day: 13), value: 70)
        sample(weight.id, at: utc(7, day: 15), value: 71)
        sample(weight.id, at: utc(19, day: 15), value: 72)
      }.execute(db)
    }
    let week = try chart(weight, .week)
    #expect(week.points.map(\.value) == [70, 71.5])
    // (70 + 71 + 72) / 3, not (70 + 71.5) / 2.
    #expect(week.summary == .average(71))
    #expect(try chart(weight, .week, offset: -1).summary == nil)
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
  /// Pins are retired (851-2990): they no longer sync, and a Mac's leftover pins are deleted,
  /// with pin writes waiting to be pushed, and `health_pin` leaves the entities its data
  /// records, so an older release bootstraps. The table stays for that release.
  @Test
  func retiringPinsEmptiesTheirTable() throws {
    #expect(!HealthDatabase.syncEntities.contains { $0.name == "health_pin" })
    let database = try DatabaseQueue()
    let migrator = HealthDatabase.migrator
    try migrator.migrate(database, upTo: "Index samples by correlation")
    let pin = SyncMutation.delete("health_pin", id: "HKQuantityTypeIdentifierStepCount")
    let other = SyncMutation.delete("test_note", id: "n1")
    try database.write { db in
      try db.execute(
        sql: #"INSERT INTO "healthPins" ("id", "position") VALUES (?, 0)"#,
        arguments: ["HKQuantityTypeIdentifierStepCount"])
      for (id, mutation) in [("pins", pin), ("other", other)] {
        try db.execute(
          sql: #"INSERT INTO "lilPendingMutations" ("id", "mutations") VALUES (?, ?)"#,
          arguments: [id, String(decoding: try JSONEncoder().encode([mutation]), as: UTF8.self)])
      }
      try db.execute(
        sql:
          #"INSERT INTO "lilSyncState" ("id", "cursor", "epoch", "entities") VALUES (1, 5, 1, ?)"#,
        arguments: ["health_pin,health_provenance,health_sample"])
    }
    try migrator.migrate(database)
    let (pins, pending, entities) = try database.read { db in
      (
        try Int.fetchOne(db, sql: #"SELECT count(*) FROM "healthPins""#),
        try String.fetchAll(db, sql: #"SELECT "id" FROM "lilPendingMutations""#),
        try String.fetchOne(db, sql: #"SELECT "entities" FROM "lilSyncState""#)
      )
    }
    #expect(pins == 0)
    #expect(pending == ["other"])
    #expect(entities == "health_provenance,health_sample")
  }

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
    let changes = try everyEntitysChanges()
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
      writable(HealthProvenance.self), writable(HealthSample.self),
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

  /// A record that needs StructuredQueries' own binding can't be staged (851-2859): it's upserted
  /// into its table, and an earlier version staged for its ID is dropped, so moving the staged
  /// records doesn't put it back over the newer one.
  @Test
  func recordsThatCantBeStagedGoStraightToTheirTable() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try #sql(
        #"CREATE TABLE "datedThings" ("id" TEXT PRIMARY KEY NOT NULL, "at" TEXT NOT NULL, "bytes" BLOB NOT NULL)"#
      )
      .execute(db)
      try #sql(#"CREATE TEMP TABLE "staging" ("id", "at", "bytes")"#).execute(db)
    }
    let upsert = PreparedUpsert<DatedThing>()
    let older = DatedThing(id: "a", at: Date(timeIntervalSince1970: 1), bytes: [1])
    let newer = DatedThing(id: "a", at: Date(timeIntervalSince1970: 2), bytes: [])
    let other = DatedThing(id: "b", at: Date(timeIntervalSince1970: 3), bytes: [2])
    // A date binds specially, so nothing is staged.
    try database.write { db in
      try #sql(#"INSERT INTO "staging" VALUES ('a', 'staged', x'01'), ('b', 'staged', x'02')"#)
        .execute(db)
      try upsert.insert(older, into: "staging", db)
      try upsert.insert(newer, into: "staging", db)
      try upsert.insert(other, into: "staging", db)
    }
    let (stored, staged) = try database.write { db in
      (
        try DatedThing.order(by: \.id).fetchAll(db),
        try String.fetchAll(db, sql: #"SELECT "id" FROM "staging""#)
      )
    }
    #expect(stored == [newer, other])
    #expect(staged.isEmpty)
  }

  /// A change to every health entity, with a delete of two of them, as `appliesEveryHealthEntity`
  /// pulls them. Synthetic.
  private func everyEntitysChanges() throws -> [Components.Schemas.Change] {
    let sampleID = "6f1c2a40-0000-4000-8000-000000000001"
    return try [
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
  }

  /// A change to every health entity, pulled and loaded from a snapshot: the snapshot, which goes
  /// through staging tables (851-2859), stores exactly what pulling does, every value with its
  /// type, over data that was there, and leaves every table's indexes as they were.
  @Test
  func aSnapshotStoresWhatPullingTheSameRecordsDoes() async throws {
    let changes = try everyEntitysChanges()
    let pulled = try HealthDatabase.make()
    try await database(pulled, pulling: changes)

    // The records left after the deletes, as a snapshot has them.
    let deleted = Set(changes.filter { $0.op == "delete" }.map(\.id))
    var lines: [String: [String]] = [:]
    for change in changes where change.op == "upsert" && !deleted.contains(change.id) {
      let row = try #require(change.row)
      lines[change.entity, default: []].append(
        String(decoding: try JSONEncoder().encode(row), as: UTF8.self))
    }
    let snapshot = try TestSnapshot(
      seq: changes.count, entities: lines.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
      partRecords: 1)
    let bootstrapped = try HealthDatabase.make()
    // Local data from before: replaced, or gone if the snapshot hasn't it.
    try await database(
      bootstrapped,
      pulling: [
        try upsert(
          1, "health_sample", "6f1c2a40-0000-4000-8000-000000000001",
          """
          "type": "HKQuantityTypeIdentifierStepCount", "startDate": 1760300000000,
          "endDate": 1760300600000, "value": 1, "unit": "count",
          "sourceName": "Old", "sourceBundleId": "com.example.old"
          """),
        try upsert(
          2, "health_sample", "6f1c2a40-0000-4000-8000-0000000000ff",
          """
          "type": "HKQuantityTypeIdentifierStepCount", "startDate": 1760300000000,
          "endDate": 1760300600000, "value": 2, "unit": "count",
          "sourceName": "Old", "sourceBundleId": "com.example.old"
          """),
      ])
    let engine = withDependencies {
      $0.defaultDatabase = bootstrapped
      $0.api = snapshot.client
      $0.snapshotDownloader = snapshot.downloader
      $0.continuousClock = RecordingClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SplitMix64(seed: "test"))
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      LilSyncEngine(
        entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema,
        partsDirectory: URL.temporaryDirectory.appending(path: "lilsync-\(UUID().uuidString)"))
    }
    try await engine.bootstrap()

    let (pulledTables, bootstrappedTables) = (try contents(pulled), try contents(bootstrapped))
    #expect(bootstrappedTables == pulledTables)
    #expect(pulledTables.values.contains { !$0.isEmpty })
    #expect(try schema(bootstrapped) == schema(pulled))
    let integrity = try await bootstrapped.read { db in
      try String.fetchAll(db, sql: "PRAGMA integrity_check")
    }
    #expect(integrity == ["ok"])
  }

  /// Pulls `changes` into `database`, a new one.
  private func database(
    _ database: any DatabaseWriter, pulling changes: [Components.Schemas.Change]
  ) async throws {
    try await database.write { db in
      try #sql(
        """
        INSERT INTO lilSyncState (id, cursor, epoch, syncSchema)
        VALUES (1, 0, 1, \(HealthDatabase.syncSchema))
        """
      )
      .execute(db)
    }
    let head = changes.last?.seq ?? 0
    let api = Client.mock { _, _ in
      (
        HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
        HTTPBody(
          try JSONEncoder().encode(
            Components.Schemas.ChangesPage(
              epoch: 1, changes: changes, next: head, head: head, hasMore: false)))
      )
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
  }

  /// Every health table's rows, each value quoted as SQL, so its type shows (`412` against
  /// `412.0`, `'1'` against `1`).
  private func contents(_ database: any DatabaseWriter) throws -> [String: [String]] {
    try database.read { db in
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'health%'")
      return try Dictionary(
        uniqueKeysWithValues: tables.map { table in
          let columns = try String.fetchAll(
            db, sql: "SELECT name FROM pragma_table_info(?) ORDER BY cid", arguments: [table])
          let row = columns.map { #"quote("\#($0)")"# }.joined(separator: " || ', ' || ")
          return (
            table,
            try String.fetchAll(db, sql: #"SELECT \#(row) FROM "\#(table)" ORDER BY "id""#)
          )
        })
    }
  }

  /// The database's tables and indexes, with their SQL.
  private func schema(_ database: any DatabaseWriter) throws -> [String] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql:
          "SELECT type || ' ' || name || ': ' || ifnull(sql, '') FROM sqlite_master ORDER BY name")
    }
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

  /// Snapshot catalogs' database has the same rows every time it's built (851-2950): its data
  /// comes only from `previewNow`, `previewCalendar` and seeded generators, never the time it's
  /// built at or a random seed.
  @Test
  func catalogDatabaseIsTheSameEveryTime() throws {
    let catalog = try contents(of: catalogDatabase)
    let again = try contents(
      of: makePreviewHealthDatabase(now: previewNow, calendar: previewCalendar))
    #expect(!catalog.isEmpty)
    #expect(catalog == again)
  }

  /// Every table's rows, sorted.
  private func contents(of database: any DatabaseWriter) throws -> [String] {
    try database.read { db in
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
      return try tables.flatMap { table in
        try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"").map { "\(table) \($0)" }
      }
      .sorted()
    }
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
      // Spans months: its first day says so, as well as its section (851-2871).
      sample("g", "HKCategoryTypeIdentifierIrregularMenstrualCycles", day: 9, value: 0),
      // Menopause has a section, and its first day still says so (851-2870).
      sample("h", "HKCategoryTypeIdentifierMenopausalState", day: 10, value: 2),
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
    #expect(days[start(10)]?.log == [.init(name: "Menopause", value: "Perimenopause")])
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
    // HKCategoryValueMenopausalState numbers None last (iOS 27).
    #expect(name(1, "HKCategoryTypeIdentifierMenopausalState") == "Menopause")
    #expect(name(2, "HKCategoryTypeIdentifierMenopausalState") == "Perimenopause")
    #expect(name(3, "HKCategoryTypeIdentifierMenopausalState") == "None")
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
    #expect(factors.allSatisfy { $0.end == nil })
  }

  @Test
  func pastFactorsAreThoseThatEndedLatestToEndFirst() throws {
    let contraceptive = "HKCategoryTypeIdentifierContraceptive"
    let database = try database([
      sample("a", contraceptive, day: 1, value: 6, endDay: 4),
      sample("b", "HKCategoryTypeIdentifierPregnancy", day: 5, value: 0, endDay: 8),
      sample("c", "HKCategoryTypeIdentifierLactation", day: 2, value: 0, endDay: 9),
      // Going on now: one that ends later, and one with no end yet.
      sample("d", contraceptive, day: 9, value: 4, endDay: 30),
      sample("e", "HKCategoryTypeIdentifierLactation", day: 3, value: 0),
      // Not a factor.
      sample("f", "HKCategoryTypeIdentifierIrregularMenstrualCycles", day: 1, value: 0, endDay: 3),
    ])
    let past = try database.read { db in
      try HealthDatabase.cycleFactorHistory(before: day(10), limit: 10, db)
    }
    // By when they ended, not when they started.
    #expect(
      past == [
        CycleFactor(name: "Lactation", detail: nil, start: day(2), end: day(9)),
        CycleFactor(name: "Pregnancy", detail: nil, start: day(5), end: day(8)),
        CycleFactor(name: "Contraceptives", detail: "Oral", start: day(1), end: day(4)),
      ])
    let current = try database.read { db in try HealthDatabase.cycleFactors(at: day(10), db) }
    #expect(current.map(\.name) == ["Contraceptives", "Lactation"])
    #expect(current.first?.detail == "Intrauterine Device")
    #expect(current.allSatisfy { $0.end == nil })

    // The limit keeps the one that ended last.
    let latest = try database.read { db in
      try HealthDatabase.cycleFactorHistory(before: day(10), limit: 1, db)
    }
    #expect(latest.map(\.name) == ["Lactation"])
  }

  @Test
  func menopauseIsTheStageGoingOnSinceItsRunStarted() throws {
    let menopause = "HKCategoryTypeIdentifierMenopausalState"
    let stage = { (database: any DatabaseWriter, n: Int) in
      try database.read { db in try HealthDatabase.menopauseStage(at: self.day(n), db) }
    }
    #expect(try stage(database([]), 10) == nil)

    let database = try database([
      sample("a", menopause, day: 2, value: 2),
      // Logged again: still perimenopause since the 2nd.
      sample("b", menopause, day: 4, value: 2),
      sample("c", menopause, day: 6, value: 1),
      sample("d", menopause, day: 7, value: 1),
      // Not logged by the 10th.
      sample("e", menopause, day: 20, value: 1),
    ])
    #expect(try stage(database, 10) == MenopauseStage(name: "Menopause", since: day(6)))
    #expect(try stage(database, 5) == MenopauseStage(name: "Perimenopause", since: day(2)))
    #expect(try stage(database, 1) == nil)
    // A value Health doesn't have yet keeps its date, without a name.
    try database.write { db in
      try HealthSample.insert { sample("f", menopause, day: 8, value: 9) }.execute(db)
    }
    #expect(try stage(database, 10) == MenopauseStage(name: nil, since: day(8)))
  }

  @Test
  func aStageThatEndedOrSaysNoneIsntShown() throws {
    let menopause = "HKCategoryTypeIdentifierMenopausalState"
    let stage = { (database: any DatabaseWriter, n: Int) in
      try database.read { db in try HealthDatabase.menopauseStage(at: self.day(n), db) }
    }
    // Over by the 10th, with nothing after it; going on while it lasted.
    let ended = try database([sample("a", menopause, day: 2, value: 2, endDay: 8)])
    #expect(try stage(ended, 10) == nil)
    #expect(try stage(ended, 5) == MenopauseStage(name: "Perimenopause", since: day(2)))
    // Ending later, it's going on.
    let ongoing = try database([sample("a", menopause, day: 2, value: 2, endDay: 20)])
    #expect(try stage(ongoing, 10) == MenopauseStage(name: "Perimenopause", since: day(2)))
    // A run breaks where a sample ended before the next started.
    let gap = try database([
      sample("a", menopause, day: 1, value: 1, endDay: 3), sample("b", menopause, day: 6, value: 1),
    ])
    #expect(try stage(gap, 10) == MenopauseStage(name: "Menopause", since: day(6)))
    // None (3) is no stage.
    let none = try database([
      sample("a", menopause, day: 2, value: 2), sample("b", menopause, day: 6, value: 3),
    ])
    #expect(try stage(none, 10) == nil)
  }

  @Test
  func cycleDeviationsAreThoseThatStartedNewestFirst() throws {
    let irregular = "HKCategoryTypeIdentifierIrregularMenstrualCycles"
    let database = try database([
      sample("a", "HKCategoryTypeIdentifierInfrequentMenstrualCycles", day: 1, value: 0, endDay: 6),
      sample("b", "HKCategoryTypeIdentifierProlongedMenstrualPeriods", day: 3, value: 0, endDay: 4),
      // Starts with b, and ends later: first of the two.
      sample(
        "c", "HKCategoryTypeIdentifierPersistentIntermenstrualBleeding", day: 3, value: 0,
        endDay: 9),
      // Ends as it starts.
      sample("d", irregular, day: 7, value: 0),
      // Ends after the 10th (dated to the end of a day, or by a clock ahead): still shown.
      sample("e", irregular, day: 8, value: 0, endDay: 12),
      // Not started by the 10th.
      sample("f", irregular, day: 11, value: 0, endDay: 13),
      // Not a deviation.
      sample("g", "HKCategoryTypeIdentifierIntermenstrualBleeding", day: 9, value: 0),
    ])
    let deviations = try database.read { db in
      try HealthDatabase.cycleDeviations(startedBy: day(10), limit: 10, db)
    }
    #expect(
      deviations == [
        CycleDeviation(name: "Irregular Cycles", start: day(8), end: day(12)),
        CycleDeviation(name: "Irregular Cycles", start: day(7), end: day(7)),
        CycleDeviation(name: "Persistent Spotting", start: day(3), end: day(9)),
        CycleDeviation(name: "Prolonged Periods", start: day(3), end: day(4)),
        CycleDeviation(name: "Infrequent Periods", start: day(1), end: day(6)),
      ])
    // Not only the last 6 months'.
    let yearsLater = calendar.date(byAdding: .year, value: 3, to: day(10))!
    let all = try database.read { db in
      try HealthDatabase.cycleDeviations(startedBy: yearsLater, limit: 10, db)
    }
    #expect(all.count == 6)
  }

  @Test
  func aDeviationLoggedTwiceIsListedOnce() throws {
    let irregular = "HKCategoryTypeIdentifierIrregularMenstrualCycles"
    let database = try database([
      sample("a", irregular, day: 1, value: 0, endDay: 6),
      // The same one again, from another source.
      HealthSample(
        id: "b", type: irregular, startDate: day(1).unixMilliseconds,
        endDate: day(6).unixMilliseconds, categoryValue: 0, sourceName: "Cycles",
        sourceBundleID: "com.example.cycles"),
      sample("c", irregular, day: 1, value: 0, endDay: 6),
      // Another type, or other dates: not the same.
      sample("d", "HKCategoryTypeIdentifierProlongedMenstrualPeriods", day: 1, value: 0, endDay: 6),
      sample("e", irregular, day: 1, value: 0, endDay: 7),
    ])
    let deviations = try database.read { db in
      try HealthDatabase.cycleDeviations(startedBy: day(10), limit: 10, db)
    }
    #expect(
      deviations == [
        CycleDeviation(name: "Irregular Cycles", start: day(1), end: day(7)),
        CycleDeviation(name: "Irregular Cycles", start: day(1), end: day(6)),
        CycleDeviation(name: "Prolonged Periods", start: day(1), end: day(6)),
      ])
    // Duplicates don't use up the limit: the page asks for one more than it shows, to know
    // whether there are more.
    let two = try database.read { db in
      try HealthDatabase.cycleDeviations(startedBy: day(10), limit: 2, db)
    }
    #expect(two == Array(deviations.prefix(2)))
  }

  @Test
  func theNextChangeIsTheFirstFactorOrStageToStartOrEnd() throws {
    let next = { (database: any DatabaseWriter, n: Int) in
      try database.read { db in try HealthDatabase.nextCycleChange(after: self.day(n), db) }
    }
    let database = try database([
      sample("a", "HKCategoryTypeIdentifierContraceptive", day: 1, value: 6, endDay: 20),
      // No end: it never changes on its own.
      sample("b", "HKCategoryTypeIdentifierPregnancy", day: 2, value: 0),
      sample("c", "HKCategoryTypeIdentifierMenopausalState", day: 15, value: 2),
      // Not a factor, stage or deviation.
      sample("d", "HKCategoryTypeIdentifierIntermenstrualBleeding", day: 12, value: 0),
    ])
    #expect(try next(database, 10) == day(15))
    #expect(try next(database, 15) == day(20))
    #expect(try next(database, 20) == nil)
  }

  @Test
  func theNextChangeIncludesTheNextDeviationToStart() throws {
    let next = { (database: any DatabaseWriter, n: Int) in
      try database.read { db in try HealthDatabase.nextCycleChange(after: self.day(n), db) }
    }
    let irregular = "HKCategoryTypeIdentifierIrregularMenstrualCycles"
    let database = try database([
      sample("a", "HKCategoryTypeIdentifierContraceptive", day: 1, value: 6, endDay: 20),
      // Its end changes nothing: it's shown from its start.
      sample("b", irregular, day: 11, value: 0, endDay: 14),
      // Ends as it starts.
      sample("c", irregular, day: 16, value: 0),
    ])
    #expect(try next(database, 10) == day(11))
    #expect(try next(database, 11) == day(16))
    #expect(try next(database, 16) == day(20))
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
    // The idle hour has a bar of none.
    #expect(day.points.map(\.start) == [time(9), time(10), time(11)])
    #expect(day.points.map(\.value) == [1, 1, 0])
    #expect(day.summary == .total(2))

    let week = try chart(stand, .week, samples)
    #expect(week.points.map(\.value) == [1, 2])
    #expect(week.summary == .dailyAverage(1.5))
  }

  @Test
  func anHourStoodCountsOnceAndIdleDaysCount() throws {
    let stand = HealthDatabase.standHourType
    let samples = [
      // Two watches recorded the same hour.
      sample("a", stand, from: time(9), to: time(10), source: "Watch"),
      sample("b", stand, from: time(9), to: time(10), source: "Other Watch"),
      // A day with only idle hours.
      sample("c", stand, from: time(9, days: -1), to: time(10, days: -1), value: 1),
    ]
    #expect(try chart(stand, .day, samples).summary == .total(1))
    let week = try chart(stand, .week, samples)
    #expect(week.points.map(\.value) == [0, 1])
    #expect(week.summary == .dailyAverage(0.5))
  }

  @Test
  func theSameToothbrushingSessionFromTwoSourcesCountsOnce() throws {
    let toothbrushing = HealthDatabase.toothbrushingType
    let samples = [
      sample("a", toothbrushing, from: time(8), to: time(8, 2), source: "Toothbrush"),
      sample(
        "b", toothbrushing, from: time(8, 0).addingTimeInterval(10), to: time(8, 2), source: "Watch"
      ),
      sample("c", toothbrushing, from: time(21), to: time(21, 2)),
    ]
    let day = try chart(toothbrushing, .week, samples)
    #expect(day.points.map(\.value) == [2])
    #expect(day.summary == .averageDuration(120))
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

// Synthetic data only (AGENTS.md).
@Suite
struct ActivityQueriesTests {
  private let calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .gmt
    return c
  }()

  @Test
  func aMonthOfRingsByDay() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthActivitySummary.insert {
        // The month before and after aren't October's.
        HealthActivitySummary(id: "2025-09-30", activeEnergyBurned: 1, activeEnergyBurnedGoal: 1)
        HealthActivitySummary(
          id: "2025-10-01", activeEnergyBurned: 620, activeEnergyBurnedGoal: 500,
          appleExerciseTime: 20, appleExerciseTimeGoal: 30, appleStandHours: 12,
          appleStandHoursGoal: 12, activityMoveMode: "activeEnergy", paused: false)
        // Move minutes, paused.
        HealthActivitySummary(
          id: "2025-10-15", activeEnergyBurned: 90, activeEnergyBurnedGoal: 0,
          appleMoveTime: 45, appleMoveTimeGoal: 30, appleExerciseTime: 10,
          appleExerciseTimeGoal: 30, appleStandHours: 5, appleStandHoursGoal: 12,
          activityMoveMode: "appleMoveTime", paused: true)
        // No Watch: no Exercise or Stand goals.
        HealthActivitySummary(
          id: "2025-10-31", activeEnergyBurned: 300, activeEnergyBurnedGoal: 400,
          appleExerciseTime: 0, appleExerciseTimeGoal: 0, appleStandHours: 0,
          appleStandHoursGoal: 0, activityMoveMode: "activeEnergy", paused: false)
        HealthActivitySummary(id: "2025-11-01", activeEnergyBurned: 1, activeEnergyBurnedGoal: 1)
      }
      .execute(db)
    }
    let october = calendar.dateInterval(
      of: .month, for: calendar.date(from: DateComponents(year: 2025, month: 10, day: 31))!)!
    let days = try database.read { db in
      try HealthDatabase.activityDays(in: october, calendar: calendar, db)
    }
    #expect(days.keys.sorted() == ["2025-10-01", "2025-10-15", "2025-10-31"])

    let first = try #require(days["2025-10-01"])
    #expect(first.move == ActivityRing(value: 620, goal: 500))
    #expect(first.move.progress == 1.24)
    #expect(!first.movesInMinutes && !first.isPaused)
    #expect(first.exercise == ActivityRing(value: 20, goal: 30))

    let paused = try #require(days["2025-10-15"])
    #expect(paused.movesInMinutes && paused.isPaused)
    #expect(paused.move == ActivityRing(value: 45, goal: 30))

    let noWatch = try #require(days["2025-10-31"])
    #expect(noWatch.exercise == nil && noWatch.stand == nil)
  }

  @Test
  func decemberRunsToTheNextYear() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthActivitySummary.insert {
        HealthActivitySummary(id: "2025-12-31", activeEnergyBurned: 1, activeEnergyBurnedGoal: 1)
        HealthActivitySummary(id: "2026-01-01", activeEnergyBurned: 1, activeEnergyBurnedGoal: 1)
      }
      .execute(db)
    }
    let december = calendar.dateInterval(
      of: .month, for: calendar.date(from: DateComponents(year: 2025, month: 12, day: 5))!)!
    let days = try database.read { db in
      try HealthDatabase.activityDays(in: december, calendar: calendar, db)
    }
    #expect(days.keys.sorted() == ["2025-12-31"])
  }

  @Test
  func daysAreGregorianWhateverTheMacsCalendar() throws {
    var buddhist = Calendar(identifier: .buddhist)
    buddhist.timeZone = .gmt
    let date = buddhist.date(from: DateComponents(year: 2568, month: 10, day: 5))!
    #expect(ActivityDay.key(for: date, calendar: buddhist) == "2025-10-05")

    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthActivitySummary.insert {
        HealthActivitySummary(id: "2025-10-05", activeEnergyBurned: 1, activeEnergyBurnedGoal: 1)
        // Later than now: not the latest.
        HealthActivitySummary(id: "2025-10-20", activeEnergyBurned: 1, activeEnergyBurnedGoal: 1)
      }
      .execute(db)
    }
    let month = buddhist.dateInterval(of: .month, for: date)!
    let days = try database.read { db in
      try HealthDatabase.activityDays(in: month, calendar: buddhist, db)
    }
    #expect(days.keys.sorted() == ["2025-10-05", "2025-10-20"])
    let latest = try database.read { db in
      try HealthDatabase.latestActivityDay(
        by: buddhist.date(from: DateComponents(year: 2568, month: 10, day: 10))!,
        calendar: buddhist, db)
    }
    #expect(latest == calendar.date(from: DateComponents(year: 2025, month: 10, day: 5)))
  }
}

// Synthetic data only (AGENTS.md).
@Suite
struct BloodPressureQueriesTests {
  private let calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .gmt
    return c
  }()

  /// October `day`, 2025, at `hour` UTC.
  private func time(_ day: Int, _ hour: Int) -> Date {
    calendar.date(from: DateComponents(year: 2025, month: 10, day: day, hour: hour))!
  }

  private func reading(
    _ id: String, at date: Date, systolic: Double?, diastolic: Double?
  ) -> (HealthCorrelation, [HealthSample]) {
    let ms = date.unixMilliseconds
    let correlation = HealthCorrelation(
      id: id, type: HealthDatabase.bloodPressureType, startDate: ms, endDate: ms,
      sourceName: "Cuff", sourceBundleID: "com.example.cuff")
    var samples: [HealthSample] = []
    if let systolic {
      samples.append(
        HealthSample(
          id: "\(id)-s", type: "HKQuantityTypeIdentifierBloodPressureSystolic", startDate: ms,
          endDate: ms, value: systolic, unit: "mmHg", correlationID: id, sourceName: "Cuff",
          sourceBundleID: "com.example.cuff"))
    }
    if let diastolic {
      samples.append(
        HealthSample(
          id: "\(id)-d", type: "HKQuantityTypeIdentifierBloodPressureDiastolic", startDate: ms,
          endDate: ms, value: diastolic, unit: "mmHg", correlationID: id, sourceName: "Cuff",
          sourceBundleID: "com.example.cuff"))
    }
    return (correlation, samples)
  }

  private func database(_ readings: [(HealthCorrelation, [HealthSample])]) throws
    -> any DatabaseWriter
  {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthCorrelation.insert { readings.map(\.0) }.execute(db)
      try HealthSample.insert { readings.flatMap(\.1) }.execute(db)
    }
    return database
  }

  @Test
  func readingsPairTheirValues() throws {
    let database = try database([
      reading("a", at: time(14, 8), systolic: 121, diastolic: 79),
      // Missing its diastolic.
      reading("b", at: time(15, 8), systolic: 133, diastolic: nil),
      reading("c", at: time(15, 21), systolic: 117, diastolic: 75),
    ])
    let week = calendar.dateInterval(of: .weekOfYear, for: time(15, 0))!
    let readings = try database.read { db in
      try HealthDatabase.bloodPressureReadings(in: week, db)
    }
    #expect(readings.map(\.id) == ["c", "b", "a"])
    #expect(readings.map(\.systolic) == [117, 133, 121])
    #expect(readings.map(\.diastolic) == [75, nil, 79])
  }

  @Test
  func longerPeriodsChartEachValuesRange() throws {
    let database = try database([
      reading("a", at: time(14, 8), systolic: 121, diastolic: 79),
      reading("b", at: time(14, 20), systolic: 129, diastolic: 83),
      reading("c", at: time(15, 8), systolic: 133, diastolic: nil),
    ])
    let now = time(20, 12)
    let month = try database.read { db in
      try HealthDatabase.bloodPressureChart(
        range: .month, offset: 0, now: now, calendar: calendar, db)
    }
    #expect(month.points.map(\.start) == [time(14, 0), time(15, 0)])
    #expect(month.points[0].systolic == 121...129)
    #expect(month.points[0].diastolic == 79...83)
    #expect(month.points[1].diastolic == nil)
    #expect(month.average?.systolic == (121 + 129 + 133) / 3.0)
    #expect(month.average?.diastolic == 81)
    #expect(month.span.systolic == 121...133)

    // A week charts each reading, oldest first.
    let week = try database.read { db in
      try HealthDatabase.bloodPressureChart(
        range: .week, offset: -1, now: now, calendar: calendar, db)
    }
    #expect(week.points.map(\.start) == [time(14, 8), time(14, 20), time(15, 8)])
    #expect(week.points[0].systolic == 121...121)
  }

  @Test
  func aValueNoReadingHasHasNoAverage() {
    let reading = BloodPressureReading(
      id: "a", date: time(14, 8), systolic: 133, diastolic: nil, sourceName: "Cuff")
    let chart = BloodPressureChart(interval: DateInterval(), points: [], readings: [reading])
    #expect(chart.average?.systolic == 133)
    #expect(chart.average?.diastolic == nil)
    #expect(chart.span.diastolic == nil)
  }
}

// Synthetic data only (AGENTS.md).
@Suite
struct FoodQueriesTests {
  private let calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .gmt
    return c
  }()

  /// October `day`, 2025, at `hour`:`minute` UTC.
  private func time(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(
        year: 2025, month: 10, day: day, hour: hour, minute: minute, second: second))!
  }

  /// A food with a sample of each nutrient given, by type identifier without its prefix.
  private func food(
    _ id: String, at date: Date, metadata: String? = nil, _ nutrients: [(String, Double)] = []
  ) -> (HealthCorrelation, [HealthSample]) {
    let ms = date.unixMilliseconds
    let correlation = HealthCorrelation(
      id: id, type: HealthDatabase.foodType, startDate: ms, endDate: ms, sourceName: "Food Log",
      sourceBundleID: "com.example.food", metadata: metadata)
    let samples = nutrients.map { name, value in
      HealthSample(
        id: "\(id)-\(name)", type: "HKQuantityTypeIdentifier\(name)", startDate: ms,
        endDate: ms, value: value,
        unit: HealthCatalog.type(id: "HKQuantityTypeIdentifier\(name)")?.unit,
        correlationID: id, sourceName: "Food Log", sourceBundleID: "com.example.food")
    }
    return (correlation, samples)
  }

  private func database(_ foods: [(HealthCorrelation, [HealthSample])]) throws
    -> any DatabaseWriter
  {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthCorrelation.insert { foods.map(\.0) }.execute(db)
      let samples = foods.flatMap(\.1)
      if !samples.isEmpty {
        try HealthSample.insert { samples }.execute(db)
      }
      // A blood pressure reading, which isn't a food.
      try HealthCorrelation.insert {
        HealthCorrelation(
          id: "bp", type: HealthDatabase.bloodPressureType,
          startDate: time(15, 9).unixMilliseconds, endDate: time(15, 9).unixMilliseconds,
          sourceName: "Cuff", sourceBundleID: "com.example.cuff")
      }
      .execute(db)
    }
    return database
  }

  @Test
  func pagesReadFoodsWithTheirSummaryNutrients() throws {
    let database = try database([
      food(
        "a", at: time(14, 8), metadata: #"{"HKFoodType":"Oatmeal","HKFoodMeal":"Breakfast"}"#,
        [
          ("DietaryEnergyConsumed", 310), ("DietaryCarbohydrates", 54), ("DietaryProtein", 9.5),
          ("DietaryFatTotal", 6.1), ("DietaryFiber", 8),
        ]),
      // No name, only its energy.
      food("b", at: time(15, 12), [("DietaryEnergyConsumed", 250)]),
      // A blank name, and no nutrients at all.
      food("c", at: time(15, 18), metadata: #"{"HKFoodType":"  "}"#),
      // Metadata that isn't an object.
      food("d", at: time(16, 7), metadata: #"["HKFoodType"]"#, [("DietaryProtein", 20)]),
    ])
    let foods = try database.read { db in
      try HealthDatabase.foodPage(after: nil, limit: 10, db)
    }
    #expect(foods.map(\.id) == ["d", "c", "b", "a"])
    #expect(foods.map(\.name) == [nil, nil, nil, "Oatmeal"])
    #expect(foods.map(\.title) == ["Food", "Food", "Food", "Oatmeal"])
    #expect(foods.map(\.energy) == [nil, nil, 250, 310])
    #expect(foods[3].carbohydrates == 54)
    #expect(foods[3].protein == 9.5)
    #expect(foods[3].fat == 6.1)
    #expect(foods[0].protein == 20)
    #expect(foods[0].carbohydrates == nil)
    #expect(foods[3].sourceName == "Food Log")
  }

  @Test
  func pagesContinueAfterTheirCursor() throws {
    // Two foods at the same moment, told apart by ID.
    let database = try database([
      food("a", at: time(14, 8)),
      food("b", at: time(14, 12)),
      food("c", at: time(14, 12)),
      food("d", at: time(15, 9)),
      food("e", at: time(16, 9)),
    ])
    var pages: [[String]] = []
    var cursor: SampleCursor?
    repeat {
      let page = try database.read { [cursor] db in
        try HealthDatabase.foodPage(after: cursor, limit: 2, db)
      }
      pages.append(page.map(\.id))
      cursor = page.last?.cursor
    } while pages.last?.count == 2
    #expect(pages == [["e", "d"], ["c", "b"], ["a"]])
  }

  @Test
  func daysGroupFoodsAtTheirEdgesWithEnergyTotals() throws {
    let foods = [
      Food(
        id: "a", name: "Late Snack", startDate: time(15, 23, 59, 59).unixMilliseconds, energy: 200,
        sourceName: "Food Log"),
      Food(
        id: "b", name: nil, startDate: time(15, 12).unixMilliseconds, energy: 640.5, protein: 30,
        sourceName: "Food Log"),
      Food(
        id: "c", name: "Coffee", startDate: time(15, 0).unixMilliseconds, sourceName: "Food Log"),
      Food(
        id: "d", name: "Dinner", startDate: time(14, 23, 59, 59).unixMilliseconds,
        sourceName: "Food Log"),
      Food(
        id: "e", name: "Toast", startDate: time(12, 8).unixMilliseconds, energy: 180,
        sourceName: "Food Log"),
    ]
    let days = HealthDatabase.foodDays(foods, calendar: calendar)
    #expect(days.map(\.day) == [time(15, 0), time(14, 0), time(12, 0)])
    #expect(days.map { $0.foods.map(\.id) } == [["a", "b", "c"], ["d"], ["e"]])
    #expect(days.map(\.energy) == [840.5, nil, 180])

    // The same foods in a zone behind GMT: midnight there is still the 14th.
    let newYork = {
      var c = Calendar(identifier: .gregorian)
      c.timeZone = TimeZone(identifier: "America/New_York")!
      return c
    }()
    let local = HealthDatabase.foodDays(foods, calendar: newYork)
    #expect(local.map { $0.foods.map(\.id) } == [["a", "b"], ["c", "d"], ["e"]])
    #expect(local.map(\.energy) == [840.5, nil, 180])
  }

  @Test
  func detailsListEveryNutrientInTheCatalogsOrder() throws {
    let database = try database([
      food(
        "a", at: time(14, 8), metadata: #"{"HKFoodType":"Salad"}"#,
        [
          ("DietarySodium", 1_120), ("DietaryFatTotal", 34), ("DietaryEnergyConsumed", 540),
          ("DietaryProtein", 38), ("DietaryVitaminC", 22), ("DietaryCarbohydrates", 18),
        ]),
      food("b", at: time(14, 9), [("DietaryEnergyConsumed", 100)]),
    ])
    try database.write { db in
      // A type the catalog doesn't know goes last.
      try HealthSample.insert {
        HealthSample(
          id: "a-unknown", type: "HKQuantityTypeIdentifierDietaryUnobtainium",
          startDate: time(14, 8).unixMilliseconds, endDate: time(14, 8).unixMilliseconds,
          value: 1, unit: "mg", correlationID: "a", sourceName: "Food Log",
          sourceBundleID: "com.example.food")
      }
      .execute(db)
    }
    let nutrients = try database.read { db in
      try HealthDatabase.foodNutrients(of: "a", db)
    }
    #expect(
      nutrients.map(\.name) == [
        "Dietary Energy", "Carbohydrates", "Protein", "Total Fat", "Sodium", "Vitamin C",
        "HKQuantityTypeIdentifierDietaryUnobtainium",
      ])
    #expect(nutrients.map(\.value) == [540, 18, 38, 34, 1_120, 22, 1])
    #expect(nutrients.first?.unit == "kcal")
  }
}

@Suite
struct NotificationQueriesTests {
  // Metadata as the iPhone uploads it: HealthKit's raw keys, quantities as their descriptions.
  private func notification(
    _ kind: HealthNotificationKind, start: Date = utc(9), minutes: Double = 10, value: Int = 0,
    metadata: String? = nil, id: String = UUID().uuidString.lowercased()
  ) -> HealthSample {
    HealthSample(
      id: id, type: kind.rawValue, startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, categoryValue: value,
      sourceName: "Apple Watch", sourceBundleID: "com.example.watch", metadata: metadata)
  }

  private func summary(_ sample: HealthSample) -> HealthNotificationSummary? {
    HealthDatabase.notificationSummary(sample)
  }

  private var english: Calendar {
    var english = calendar("UTC")
    english.locale = Locale(identifier: "en_US_POSIX")
    return english
  }

  @Test
  func heartRateThresholds() {
    let high = notification(
      .highHeartRate, metadata: #"{"HKHeartRateEventThreshold":"120 count/min"}"#)
    #expect(summary(high) == .heartRateAbove(120))
    #expect(summary(high)?.line(calendar: english) == "Above 120 BPM")

    let low = notification(
      .lowHeartRate, metadata: #"{"HKHeartRateEventThreshold":"40 count/min"}"#)
    #expect(summary(low)?.line(calendar: english) == "Below 40 BPM")

    // A plain number is in BPM; beats per second are converted.
    #expect(
      summary(notification(.highHeartRate, metadata: #"{"HKHeartRateEventThreshold":110}"#))
        == .heartRateAbove(110))
    #expect(
      summary(notification(.highHeartRate, metadata: #"{"HKHeartRateEventThreshold":"2 count/s"}"#))
        == .heartRateAbove(120))
  }

  @Test
  func heartRateWithoutAThresholdIsJustItsDate() {
    #expect(summary(notification(.highHeartRate)) == nil)
    #expect(summary(notification(.highHeartRate, metadata: "{}")) == nil)
    #expect(summary(notification(.lowHeartRate, metadata: "not json")) == nil)
    #expect(
      summary(notification(.highHeartRate, metadata: #"{"HKHeartRateEventThreshold":"120 ms"}"#))
        == nil)
    #expect(
      summary(notification(.highHeartRate, metadata: #"{"HKHeartRateEventThreshold":"high"}"#))
        == nil)
    #expect(
      summary(notification(.highHeartRate, metadata: #"{"HKHeartRateEventThreshold":true}"#))
        == nil)
  }

  @Test
  func lowCardioFitness() {
    let both = notification(
      .lowCardioFitness,
      metadata:
        #"{"HKVO2MaxValue":"27.4 ml/kg*min","HKLowCardioFitnessEventThreshold":"30.1 ml/kg*min"}"#
    )
    #expect(summary(both) == .cardioFitness(vo2Max: 27.4, threshold: 30.1))
    #expect(summary(both)?.line(calendar: english) == "27.4 VO₂ max, below 30.1")

    let vo2Only = notification(.lowCardioFitness, metadata: #"{"HKVO2MaxValue":"27 ml/kg*min"}"#)
    #expect(summary(vo2Only)?.line(calendar: english) == "27 VO₂ max")
    #expect(summary(vo2Only) == .cardioFitness(vo2Max: 27, threshold: nil))
    let thresholdOnly = notification(
      .lowCardioFitness, metadata: #"{"HKLowCardioFitnessEventThreshold":"30.1 ml/kg*min"}"#)
    #expect(summary(thresholdOnly) == .cardioFitnessThreshold(30.1))
    #expect(summary(thresholdOnly)?.line(calendar: english) == "Below 30.1 VO₂ max")

    #expect(summary(notification(.lowCardioFitness)) == nil)
  }

  @Test
  func soundExposure() {
    let noise = notification(
      .noise, metadata: #"{"HKAudioExposureLevel":"96.2 dBASPL","HKAudioExposureDuration":"240 s"}"#
    )
    #expect(summary(noise) == .soundExposure(level: 96.2, duration: 240))
    #expect(summary(noise)?.line(calendar: english) == "96 dB for 4 min")

    let headphone = notification(
      .headphone,
      metadata: #"{"HKAudioExposureLevel":"88 dBASPL","HKAudioExposureDuration":"1.25 hr"}"#)
    #expect(summary(headphone)?.line(calendar: english) == "88 dB for 1 hr 15 min")

    let levelOnly = notification(.noise, metadata: #"{"HKAudioExposureLevel":"100 dBASPL"}"#)
    #expect(summary(levelOnly)?.line(calendar: english) == "100 dB")
    let durationOnly = notification(.noise, metadata: #"{"HKAudioExposureDuration":"45 s"}"#)
    #expect(summary(durationOnly) == .soundDuration(45))
    #expect(summary(durationOnly)?.line(calendar: english) == "For 45 sec")

    // A duration in a unit that isn't time doesn't count.
    #expect(summary(notification(.noise, metadata: #"{"HKAudioExposureDuration":"3 m"}"#)) == nil)
    #expect(summary(notification(.headphone)) == nil)
  }

  @Test
  func walkingSteadiness() {
    let names = (1...4).map {
      summary(notification(.walkingSteadiness, value: $0))?.line(calendar: english)
    }
    #expect(names == ["Low", "Very Low", "Still Low", "Still Very Low"])
    #expect(
      HealthDatabase.categoryValueName(
        2, typeID: HealthNotificationKind.walkingSteadiness.rawValue) == "Very Low")
    // Values HealthKit may add later.
    #expect(summary(notification(.walkingSteadiness, value: 7)) == nil)
    #expect(summary(notification(.walkingSteadiness, value: 0)) == nil)
  }

  /// Every kind takes its name and color from its type in the catalog, so none falls back.
  @Test
  func kindsAreCategorizedTypes() {
    for kind in HealthNotificationKind.allCases {
      #expect(HealthCatalog.type(id: kind.rawValue)?.category != nil, "\(kind)")
    }
  }

  @Test
  func periods() {
    for kind in [HealthNotificationKind.irregularRhythm, .sleepApnea, .hypertension] {
      let sample = notification(kind, start: utc(0, day: 1), minutes: 30 * 24 * 60)
      #expect(summary(sample) == .period(DateInterval(start: sample.start, end: sample.end)))
      // Without a period to show, just its date.
      #expect(summary(notification(kind, minutes: 0)) == nil)
    }
    // September 20 to October 20: days, without times.
    let days = notification(.sleepApnea, start: utc(0, day: -10), minutes: 30 * 24 * 60)
    let line = summary(days)?.line(calendar: english) ?? ""
    #expect(line.contains("Sep 20") && line.contains("Oct 20") && !line.contains(":"), "\(line)")
    // Within a day: with times.
    let hours = notification(.irregularRhythm, start: utc(2), minutes: 5 * 60)
    #expect(summary(hours)?.line(calendar: english).contains(":") == true)
  }

  @Test
  func numbersNoNotificationCouldMeanDontCount() {
    // Finite, but past what an Int holds: no line rather than a trap.
    for metadata in [
      #"{"HKHeartRateEventThreshold":"1e300 count/min"}"#,
      #"{"HKHeartRateEventThreshold":1e300}"#,
      #"{"HKHeartRateEventThreshold":"inf count/min"}"#,
    ] {
      #expect(summary(notification(.highHeartRate, metadata: metadata)) == nil)
    }
    #expect(
      summary(notification(.noise, metadata: #"{"HKAudioExposureLevel":"1e20 dBASPL"}"#)) == nil)
    // A duration given directly still reads, however long.
    #expect(
      HealthNotificationSummary.duration(1e300, locale: Locale(identifier: "en_US_POSIX"))
        .hasSuffix(" sec"))
    #expect(
      HealthNotificationSummary.line(.heartRateAbove(1e300))(calendar: english).hasPrefix("Above"))
  }

  @Test
  func otherTypesAreNotNotifications() {
    #expect(
      HealthDatabase.notificationSummary(
        sample("HKCategoryTypeIdentifierHandwashingEvent", at: utc(9), value: 0)) == nil)
  }

  @Test
  func notificationsAreNewestFirst() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthProvenance.insert {
        HealthProvenance(id: "prov-watch", device: #"{"name":"Apple Watch"}"#)
      }
      .execute(db)
      var withProvenance = notification(.highHeartRate, start: utc(8), id: "c")
      withProvenance.provenance = "prov-watch"
      try HealthSample.insert {
        notification(.highHeartRate, start: utc(9, day: 10), id: "a")
        withProvenance
        // Same start: by ID, last first.
        notification(.highHeartRate, start: utc(9, day: 10), id: "b")
        notification(.highHeartRate, start: utc(7), id: "d")
        // Another kind.
        notification(.lowHeartRate, start: utc(10), id: "e")
      }
      .execute(db)
    }
    let notifications = try database.read { db in
      try HealthDatabase.notifications(of: .highHeartRate, limit: 3, db)
    }
    #expect(notifications.map(\.id) == ["c", "d", "b"])
    #expect(notifications.first?.sample.decodedDevice?.name == "Apple Watch")
    // Worked out with the query.
    #expect(notifications.first?.summary == nil)
  }

  @Test
  func sleepApneaAndHypertensionAreListedByTheirEnd() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthSample.insert {
        // Starts later, but ends sooner.
        notification(.sleepApnea, start: utc(0, day: 5), minutes: 24 * 60, id: "short")
        notification(.sleepApnea, start: utc(0, day: 1), minutes: 30 * 24 * 60, id: "long")
      }
      .execute(db)
    }
    let notifications = try database.read { db in
      try HealthDatabase.notifications(of: .sleepApnea, limit: 10, db)
    }
    #expect(notifications.map(\.id) == ["long", "short"])
    let long = try #require(notifications.first)
    #expect(HealthNotificationKind.sleepApnea.listedDate(of: long.sample) == long.sample.end)
    #expect(HealthNotificationKind.hypertension.listedByEnd)
    #expect(
      HealthNotificationKind.allCases.filter(\.listedByEnd).sorted { $0.rawValue < $1.rawValue }
        == [.hypertension, .sleepApnea])
    #expect(HealthNotificationKind.highHeartRate.listedDate(of: long.sample) == long.sample.start)
  }
}

// Synthetic data only (AGENTS.md).
@Suite
struct WorkoutRouteQueriesTests {
  let database: any DatabaseWriter

  init() throws {
    database = try HealthDatabase.make()
  }

  private func workout(_ id: String, at start: Date, minutes: Double = 30) -> HealthWorkout {
    HealthWorkout(
      id: id, activityType: 37, startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, duration: minutes * 60,
      activities: "[]", events: "[]", statistics: "{}", sourceName: "Test",
      sourceBundleID: "com.example")
  }

  private func route(
    _ id: String, from start: Date, to end: Date, workout: String? = nil, count: Int = 2,
    locations: String? = "abc"
  ) -> HealthWorkoutRoute {
    HealthWorkoutRoute(
      id: id, startDate: start.unixMilliseconds, endDate: end.unixMilliseconds, workout: workout,
      locationCount: count, locations: locations, sourceName: "Test",
      sourceBundleID: "com.example")
  }

  private func insert(_ workouts: [HealthWorkout], _ routes: [HealthWorkoutRoute]) throws {
    try database.write { db in
      try HealthWorkout.insert { workouts }.execute(db)
      try HealthWorkoutRoute.insert { routes }.execute(db)
    }
  }

  private func lists(limit: Int = 10) throws -> (workouts: [String], otherRoutes: [String]) {
    let (workouts, routes) = try database.read { db in
      try HealthDatabase.workoutRoutes(limit: limit, db)
    }
    return (workouts.map(\.id), routes.map(\.id))
  }

  /// Every workout shows the route `route(of:)` picks for it, and Other Routes lists the rest.
  private func expectEveryRouteShowsOnce() throws {
    let (workouts, others) = try database.read { db in
      try HealthDatabase.workoutRoutes(limit: 100, db)
    }
    let shown = try database.read { db in
      try HealthWorkout.fetchAll(db).compactMap { try HealthDatabase.route(of: $0, db)?.id }
    }
    let routes = try database.read { db in
      try HealthWorkoutRoute.where { $0.locations.isNot(nil) }.fetchAll(db).map(\.id)
    }
    #expect(workouts.count == shown.count)
    #expect(Set(shown + others.map(\.id)) == Set(routes))
    #expect(Set(shown).isDisjoint(with: others.map(\.id)))
  }

  @Test
  func workoutsWithRoutesAreThoseARouteIsLinkedToOrRecordedDuring() throws {
    try insert(
      [
        workout("linked", at: utc(8, day: 12)),
        workout("overlapped", at: utc(8, day: 13)),
        workout("strength", at: utc(8, day: 14)),
        // A route linked to another workout doesn't count, though it was recorded during this.
        workout("during-linked", at: utc(18, day: 12)),
        workout("newest", at: utc(8, day: 15)),
        // Its only route has no locations.
        workout("no-locations", at: utc(8, day: 16)),
      ],
      [
        route("a", from: utc(8, day: 12), to: utc(8.5, day: 12), workout: "linked"),
        route("b", from: utc(18, day: 12), to: utc(18.5, day: 12), workout: "linked"),
        // Starts before the workout and ends during it.
        route("c", from: utc(7.9, day: 13), to: utc(8.2, day: 13)),
        // Ends just as the workout starts.
        route("d", from: utc(7.5, day: 14), to: utc(8, day: 14)),
        route("e", from: utc(8, day: 15), to: utc(8.5, day: 15), workout: "newest"),
        route(
          "f", from: utc(8, day: 16), to: utc(8.5, day: 16), workout: "no-locations",
          locations: nil),
      ])
    #expect(try lists().workouts == ["newest", "overlapped", "linked"])
    #expect(try lists(limit: 2).workouts == ["newest", "overlapped"])
    try expectEveryRouteShowsOnce()
  }

  @Test
  func otherRoutesAreThoseNoWorkoutShows() throws {
    try insert(
      [workout("run", at: utc(8, day: 13)), workout("walk", at: utc(18, day: 13))],
      [
        route("linked", from: utc(8, day: 13), to: utc(8.5, day: 13), workout: "run"),
        // Recorded during the walk, which no route is linked to.
        route("overlapping", from: utc(18.2, day: 13), to: utc(19, day: 13)),
        // Linked to a workout that isn't here.
        route("orphaned", from: utc(8, day: 12), to: utc(8.5, day: 12), workout: "deleted"),
        // Recorded while no workout was: right after the run.
        route("unlinked", from: utc(8.5, day: 13), to: utc(9, day: 13)),
        route("newest", from: utc(8, day: 15), to: utc(8.5, day: 15)),
        // Without locations, it would open with no map.
        route("empty", from: utc(8, day: 16), to: utc(8.5, day: 16), locations: nil),
      ])
    #expect(try lists().otherRoutes == ["newest", "unlinked", "orphaned"])
    #expect(try lists(limit: 1).otherRoutes == ["newest"])
    try expectEveryRouteShowsOnce()
  }

  @Test
  func aRouteDuringAWorkoutWithALinkedOneIsAnOtherRoute() throws {
    try insert(
      [workout("run", at: utc(8))],
      [
        route("linked", from: utc(8, day: 14), to: utc(8.5), workout: "run"),
        // More locations, but the workout shows the one HealthKit linked.
        route("overlapping", from: utc(8.1), to: utc(8.4), count: 50),
      ])
    #expect(try lists().workouts == ["run"])
    #expect(try lists().otherRoutes == ["overlapping"])
    try expectEveryRouteShowsOnce()
  }

  @Test
  func ofTwoRoutesDuringAWorkoutTheSmallerIsAnOtherRoute() throws {
    try insert(
      [workout("run", at: utc(8)), workout("walk", at: utc(18))],
      [
        route("small", from: utc(8), to: utc(8.2), count: 10),
        route("large", from: utc(8.1), to: utc(8.5), count: 90),
        // As many locations: the first by ID is shown.
        route("b", from: utc(18), to: utc(18.2), count: 10),
        route("a", from: utc(18.1), to: utc(18.5), count: 10),
      ])
    #expect(try lists().workouts == ["walk", "run"])
    #expect(try lists().otherRoutes == ["b", "small"])
    try expectEveryRouteShowsOnce()
  }

  @Test
  func aLongRouteOverlapsTheWorkoutsDuringIt() throws {
    // Starts long before the workouts after it, so the search back from each must reach it.
    try insert(
      [workout("early", at: utc(9)), workout("late", at: utc(20))],
      [
        route("all-day", from: utc(6), to: utc(22)),
        route("short", from: utc(7), to: utc(7.5)),
      ])
    #expect(try lists().workouts == ["late", "early"])
    #expect(try lists().otherRoutes == ["short"])
    try expectEveryRouteShowsOnce()
  }

  @Test
  func noRoutesNoWorkoutsWithRoutes() throws {
    try insert([workout("run", at: utc(8))], [])
    #expect(try lists().workouts.isEmpty)
    #expect(try lists().otherRoutes.isEmpty)
  }

  @Test
  func aRoutesDistanceAddsUpItsSteps() {
    // Synthetic: about 100 m north, then about 100 m east, on the equator.
    let start = Date(timeIntervalSince1970: 1_760_400_000)
    let locations = [(0.0, 0.0), (0.0009, 0.0), (0.0009, 0.0009)].enumerated().map {
      RouteLocation(
        time: start.addingTimeInterval(Double($0.offset) * 20), latitude: $0.element.0,
        longitude: $0.element.1, altitude: 0, speed: 5)
    }
    #expect(abs(HealthDatabase.routeDistance(locations) - 200) < 0.5)
    #expect(HealthDatabase.routeDistance(Array(locations.prefix(1))) == 0)
    #expect(HealthDatabase.routeDistance([]) == 0)
  }
}

// Synthetic data only (AGENTS.md).
@Suite
struct SymptomQueriesTests {
  private let headache = "HKCategoryTypeIdentifierHeadache"
  private let gmt = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .gmt
    return c
  }()

  /// October `day`, 2025, at `hour`:`minute` UTC.
  private func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    gmt.date(from: DateComponents(year: 2025, month: 10, day: day, hour: hour, minute: minute))!
  }

  private func sample(
    _ id: String, _ type: String? = nil, at start: Date, minutes: Double = 0, value: Int
  ) -> HealthSample {
    HealthSample(
      id: id, type: type ?? headache, startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, categoryValue: value,
      sourceName: "Phone", sourceBundleID: "com.example.phone")
  }

  private func chart(
    _ range: ChartRange, _ samples: [HealthSample], now: Date, offset: Int = 0,
    calendar: Calendar? = nil, type: String? = nil
  ) throws -> SymptomChart {
    let database = try HealthDatabase.make()
    try database.write { db in try HealthSample.insert { samples }.execute(db) }
    return try database.read { db in
      try HealthDatabase.symptomChart(
        of: type ?? headache, range: range, offset: offset, now: now, calendar: calendar ?? gmt,
        db)
    }
  }

  @Test
  func valuesAreNamedForEachKind() {
    let name = HealthDatabase.categoryValueName
    // Severity.
    #expect(
      (0...4).map { name($0, headache) }
        == ["Present", "Not Present", "Mild", "Moderate", "Severe"])
    // One Health doesn't name yet, or none, reads as present, as the page charts it.
    #expect(name(5, headache) == "Present")
    #expect(name(nil, headache) == "Present")
    // Presence.
    for type in ["HKCategoryTypeIdentifierMoodChanges", "HKCategoryTypeIdentifierSleepChanges"] {
      #expect((0...2).map { name($0, type) } == ["Present", "Not Present", "Present"])
    }
    // Appetite.
    #expect(
      (0...3).map { name($0, "HKCategoryTypeIdentifierAppetiteChanges") }
        == ["Present", "No Change", "Decreased", "Increased"])
    // Every symptom has names, from its scale.
    for type in HealthCatalog.all where type.category == .symptoms {
      let scale = try! #require(SymptomScale(typeID: type.id))
      #expect((0...4).map { name($0, type.id) } == (0...4).map { scale.name($0) })
    }
    #expect(SymptomScale(typeID: HealthDatabase.standHourType) == nil)
  }

  @Test
  func levelsLeaveOutNotPresent() {
    #expect(SymptomScale(typeID: headache) == .severity)
    #expect((0...4).map { SymptomScale.severity.level($0) } == [1, nil, 2, 3, 4])
    #expect(SymptomScale(typeID: "HKCategoryTypeIdentifierSleepChanges") == .presence)
    #expect((0...1).map { SymptomScale.presence.level($0) } == [1, nil])
    #expect(SymptomScale(typeID: "HKCategoryTypeIdentifierAppetiteChanges") == .appetite)
    #expect((0...3).map { SymptomScale.appetite.level($0) } == [1, nil, 2, 3])
    #expect(SymptomScale.appetite.levels == ["Present", "Decreased", "Increased"])
    #expect(!SymptomScale.appetite.isOrdered && SymptomScale.severity.isOrdered)
  }

  @Test
  func aWeekChartsEachDaysHighestSeverity() throws {
    let samples = [
      sample("a", at: time(13, 8), value: 2),
      sample("b", at: time(13, 14), minutes: 90, value: 4),
      sample("c", at: time(13, 20), value: 3),
      // Not present: listed, not charted or counted.
      sample("d", at: time(14, 9), value: 1),
      sample("e", at: time(15, 23, 59), value: 0),
      // The next week, and another symptom.
      sample("f", at: time(19, 0), value: 4),
      sample("g", "HKCategoryTypeIdentifierNausea", at: time(14, 9), value: 4),
    ]
    // Sunday, October 12, to Saturday the 18th.
    let week = try chart(.week, samples, now: time(16, 12))
    #expect(week.interval == DateInterval(start: time(12, 0), end: time(19, 0)))
    #expect(week.points.map(\.start) == [time(13, 0), time(15, 0)])
    #expect(week.points.map(\.end) == [time(14, 0), time(16, 0)])
    #expect(week.points.map(\.value) == [4, 1])
    #expect(week.points[0].entries.map(\.id) == ["a", "b", "c"])
    #expect(week.days == 2)
    // Newest first, with names.
    #expect(week.entries.map(\.id) == ["e", "d", "c", "b", "a"])
    #expect(week.entries.map(\.name) == ["Present", "Not Present", "Moderate", "Severe", "Mild"])
    #expect(week.entries.map(\.level) == [1, nil, 3, 4, 2])
  }

  @Test
  func aDayChartsEachEntryOverItsHours() throws {
    let samples = [
      sample("a", at: time(15, 7), minutes: 150, value: 3),
      sample("b", at: time(15, 11, 15), value: 2),
      // Runs past midnight: its bar ends with the day.
      sample("c", at: time(15, 22), minutes: 240, value: 4),
      sample("d", at: time(15, 23), value: 1),
      // The day before, ending as the day starts.
      sample("e", at: time(14, 23), minutes: 60, value: 2),
    ]
    let day = try chart(.day, samples, now: time(15, 12))
    #expect(day.points.map(\.start) == [time(15, 7), time(15, 11, 15), time(15, 22)])
    #expect(day.points.map(\.end) == [time(15, 9, 30), time(15, 11, 15), time(16, 0)])
    #expect(day.points.map(\.value) == [3, 2, 4])
    #expect(day.days == 1)
    #expect(day.entries.map(\.id) == ["d", "c", "b", "a"])
  }

  @Test
  func longerPeriodsCountDaysPerWeekOrMonth() throws {
    let samples = [
      // Two on one day count it once.
      sample("a", at: time(1, 9), value: 2),
      sample("b", at: time(1, 18), value: 3),
      sample("c", at: time(2, 9), value: 0),
      sample("d", at: time(3, 9), value: 1),
      sample("e", at: time(14, 9), value: 4),
      sample(
        "f", at: gmt.date(from: DateComponents(year: 2025, month: 7, day: 4, hour: 9))!,
        value: 2),
    ]
    let year = try chart(.year, samples, now: time(20, 12))
    #expect(
      year.points.map(\.start) == [
        gmt.date(from: DateComponents(year: 2025, month: 7, day: 1))!, time(1, 0),
      ])
    #expect(year.points.map(\.value) == [1, 3])
    #expect(year.points[1].entries.map(\.id) == ["a", "b", "c", "e"])
    #expect(year.days == 4)

    let sixMonths = try chart(.sixMonths, samples, now: time(20, 12))
    // Weeks from Sunday: September 28 has the 1st and 2nd; October 12 the 14th.
    #expect(
      sixMonths.points.map(\.start) == [
        gmt.date(from: DateComponents(year: 2025, month: 6, day: 29))!,
        gmt.date(from: DateComponents(year: 2025, month: 9, day: 28))!, time(12, 0),
      ])
    #expect(sixMonths.points.map(\.value) == [1, 2, 1])
  }

  @Test
  func daysSplitInTheCalendarsTimeZone() throws {
    var tokyo = Calendar(identifier: .gregorian)
    tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let samples = [
      // October 15 at 8 PM UTC is the 16th at 5 AM in Tokyo.
      sample("a", at: time(15, 20), value: 2),
      sample("b", at: time(15, 10), value: 3),
    ]
    let gmtWeek = try chart(.week, samples, now: time(16, 12))
    #expect(gmtWeek.points.map(\.value) == [3])
    #expect(gmtWeek.days == 1)

    let tokyoWeek = try chart(.week, samples, now: time(16, 12), calendar: tokyo)
    // Midnight in Tokyo is 3 PM UTC the day before.
    #expect(tokyoWeek.points.map(\.start) == [time(14, 15), time(15, 15)])
    #expect(tokyoWeek.points.map(\.value) == [3, 2])
    #expect(tokyoWeek.days == 2)

    // A Tokyo day: from 3 PM UTC.
    let tokyoDay = try chart(.day, samples, now: time(16, 1), calendar: tokyo)
    #expect(tokyoDay.interval.start == time(15, 15))
    #expect(tokyoDay.points.map(\.start) == [time(15, 20)])
  }

  @Test
  func entriesThatRunIntoThePeriodCountForEachDayTheyCover() throws {
    let samples = [
      // 10 PM to 4 AM, into the 15th.
      sample("a", at: time(14, 22), minutes: 360, value: 3),
      // Ends at midnight: only its own day.
      sample("b", at: time(15, 22), minutes: 120, value: 2),
      // Three days long, from Saturday the 11th, before the week.
      sample("c", at: time(11, 12), minutes: 3 * 1440, value: 4),
      // Over before the 15th, and a moment on the 14th.
      sample("d", at: time(14, 20), minutes: 60, value: 2),
      sample("e", at: time(14, 23, 59), value: 2),
      // Starts a week and more before: not found, though it runs into the week and the day.
      sample(
        "f", at: gmt.date(from: DateComponents(year: 2025, month: 9, day: 20))!,
        minutes: 30 * 1440, value: 4),
    ]
    let day = try chart(.day, samples, now: time(15, 12))
    #expect(day.entries.map(\.id) == ["b", "a"])
    // Clipped to the day.
    #expect(day.points.map(\.start) == [time(15, 0), time(15, 22)])
    #expect(day.points.map(\.end) == [time(15, 4), time(16, 0)])
    #expect(day.days == 1)

    // Sunday the 12th to Saturday the 18th.
    let week = try chart(.week, samples, now: time(15, 12))
    #expect(week.entries.map(\.id) == ["b", "e", "a", "d", "c"])
    #expect(week.points.map(\.start) == [time(12, 0), time(13, 0), time(14, 0), time(15, 0)])
    #expect(week.points.map(\.value) == [4, 4, 4, 3])
    #expect(week.points[2].entries.map(\.id) == ["c", "d", "a", "e"])
    #expect(week.points[3].entries.map(\.id) == ["a", "b"])
    #expect(week.days == 4)

    // A month counts each day once, however many entries cover it (the year starts long
    // before the long one, so it's left out here).
    let year = try chart(.year, Array(samples.dropLast()), now: time(15, 12))
    #expect(year.points.map(\.start) == [time(1, 0)])
    #expect(year.points.map(\.value) == [5])
    #expect(year.days == 5)
    #expect(year.points[0].entries.map(\.id) == ["c", "d", "a", "e", "b"])
  }

  @Test
  func presenceAndAppetiteChartTheirOwnLevels() throws {
    let mood = "HKCategoryTypeIdentifierMoodChanges"
    let appetite = "HKCategoryTypeIdentifierAppetiteChanges"
    let samples = [
      sample("a", mood, at: time(13, 9), value: 0),
      sample("b", mood, at: time(14, 9), value: 1),
      sample("c", appetite, at: time(13, 9), value: 3),
      sample("d", appetite, at: time(13, 12), value: 2),
      // No change: not charted.
      sample("e", appetite, at: time(14, 9), value: 1),
    ]
    let moodWeek = try chart(.week, samples, now: time(16, 12), type: mood)
    #expect(moodWeek.scale == .presence)
    #expect(moodWeek.points.map(\.value) == [1])
    #expect(moodWeek.days == 1)

    // Kinds of change, not an order: a day with both has a mark for each.
    let appetiteWeek = try chart(.week, samples, now: time(16, 12), type: appetite)
    #expect(appetiteWeek.points.map(\.start) == [time(13, 0), time(13, 0)])
    #expect(appetiteWeek.points.map(\.value) == [2, 3])
    #expect(appetiteWeek.points.map { $0.entries.map(\.id) } == [["d"], ["c"]])
    #expect(appetiteWeek.days == 1)
    #expect(appetiteWeek.entries.map(\.name) == ["No Change", "Decreased", "Increased"])
  }
}

/// Where the Mac app keeps its data (851-2977).
struct MacDirectoryTests {
  /// A Release build keeps today's folder, `tech.lil.health` in Application Support, so updating
  /// moves and migrates nothing. Debug builds keep a folder per server inside it.
  @Test
  func releaseBuildsKeepTodaysFolder() {
    #expect(
      HealthDatabase.macDirectory(for: .prod, allowsOverride: false)
        == URL.applicationSupportDirectory.appending(
          path: "tech.lil.health", directoryHint: .isDirectory))
    let support = URL(filePath: "/home/Library/Application Support/")
    #expect(
      HealthDatabase.macDirectory(for: .prod, allowsOverride: false, applicationSupport: support)
        .path(percentEncoded: false) == "/home/Library/Application Support/tech.lil.health/")
    #expect(
      HealthDatabase.macDirectory(for: .staging, allowsOverride: true, applicationSupport: support)
        .path(percentEncoded: false)
        == "/home/Library/Application Support/tech.lil.health/Servers/api.staging.lil.tech/")
    #expect(
      HealthDatabase.macDirectory(for: .prod, allowsOverride: true, applicationSupport: support)
        .path(percentEncoded: false)
        == "/home/Library/Application Support/tech.lil.health/Servers/api.lil.tech/")
  }
}
