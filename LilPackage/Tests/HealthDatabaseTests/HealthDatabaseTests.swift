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
  _ type: String, at start: Date, minutes: Double = 1, value: Double
) -> HealthSample {
  HealthSample(
    id: UUID().uuidString.lowercased(), type: type, startDate: start.unixMilliseconds,
    endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, value: value, unit: "x",
    sourceName: "Test iPhone", sourceBundleID: "com.example")
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
    ]
    let api = Client.mock { request, _ in
      #expect(request.path?.hasPrefix("/v1/sync/changes") == true)
      return (
        HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
        HTTPBody(
          try JSONEncoder().encode(
            Components.Schemas.ChangesPage(
              epoch: 1, changes: changes, next: 7, head: 7, hasMore: false)))
      )
    }
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = api
      $0.continuousClock = ImmediateClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SplitMix64(seed: "test"))
    } operation: {
      LilSyncEngine(entities: HealthDatabase.syncEntities)
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
}
