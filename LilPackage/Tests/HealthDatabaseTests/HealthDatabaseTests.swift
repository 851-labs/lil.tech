import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import HealthCatalog
import LilAPI
import LilSync
import OpenAPIRuntime
import SQLiteData
import Testing

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
  func emptyBucketsAheadArentTheLatestDay() throws {
    let steps = "HKQuantityTypeIdentifierStepCount"
    try database.write { db in
      try HealthStatisticsDevice.insert { reported(device, paired: true, daysAgo: 0) }.execute(db)
      try HealthStatistic.insert {
        statistic(steps, at: utc(9, day: 13), sum: 4_000)
        // Zero-filled today and tomorrow, as the iPhone sends them.
        statistic(steps, at: utc(9), sum: 0)
        statistic(steps, at: utc(9, day: 15), sum: 0)
      }.execute(db)
    }
    let summary = try summary(steps)
    #expect(summary.latestDate == utc(0, day: 13))
    #expect(summary.latestValue == 4_000)
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
    }
    #expect(try summary(headache).latestDate == utc(10))
    #expect(try summary(headache).latestValue == nil)
    #expect(try summary("HKActivitySummaryTypeIdentifier").latestDate == utc(0, day: 13))
    // A day's, not a moment's.
    #expect(try summary("HKActivitySummaryTypeIdentifier").isDailyTotal)
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
      try #sql("INSERT INTO lilSyncState (id, cursor, epoch) VALUES (1, 0, 1)").execute(db)
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
        "device": null, "fieldFromTheFuture": "ignored"
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
    ]
    let api = Client.mock { request, _ in
      #expect(request.path?.hasPrefix("/v1/sync/changes") == true)
      return (
        HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
        HTTPBody(
          try JSONEncoder().encode(
            Components.Schemas.ChangesPage(
              epoch: 1, changes: changes, next: 14, head: 14, hasMore: false)))
      )
    }
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = api
      $0.continuousClock = ImmediateClock()
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
    let routes = try await database.read { db in try HealthWorkoutRoute.fetchAll(db) }
    #expect(routes.map(\.locationCount) == [3600])
    #expect(routes.map(\.workout) == ["6f1c2a40-0000-4000-8000-000000000004"])
    #expect(routes.map(\.locations) == [String(repeating: "b", count: 64)])
    #expect(workouts.first?.events == #"[{"type":1}]"#)
    #expect(
      workouts.first?.statistics
        == #"{"HKQuantityTypeIdentifierActiveEnergyBurned":{"sum":312.5,"unit":"kcal"}}"#)
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
