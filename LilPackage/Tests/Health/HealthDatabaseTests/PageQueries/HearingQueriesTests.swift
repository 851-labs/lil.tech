import Foundation
import HealthCatalog
import HealthDatabase
import SQLiteData
import Testing

// Synthetic data only (AGENTS.md).

private let headphones = "HKQuantityTypeIdentifierHeadphoneAudioExposure"
private let environment = "HKQuantityTypeIdentifierEnvironmentalAudioExposure"

/// 2025-10-08 00:00 UTC, a week before 2025-10-15.
private let weekStart = Date(timeIntervalSince1970: 1_759_881_600)
private let week = weekStart..<weekStart.addingTimeInterval(7 * 86_400)

/// `hours` past the start of `week`'s day `day` (0 to 6).
private func at(day: Int, hours: Double) -> Date {
  weekStart.addingTimeInterval(Double(day) * 86_400 + hours * 3600)
}

private func level(
  _ type: String = headphones, at start: Date, hours: Double, decibels: Double
) -> HealthSample {
  HealthSample(
    id: UUID().uuidString.lowercased(), type: type, startDate: start.unixMilliseconds,
    endDate: start.addingTimeInterval(hours * 3600).unixMilliseconds, value: decibels,
    unit: "dBASPL", sourceName: "iPhone", sourceBundleID: "com.example")
}

private func utcCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}

@Suite
struct SoundExposureTests {
  let database: any DatabaseWriter

  init() throws {
    database = try HealthDatabase.make()
  }

  private func insert(_ samples: [HealthSample]) throws {
    try database.write { db in try HealthSample.insert { samples }.execute(db) }
  }

  private func exposure(_ type: String = headphones) throws -> SoundExposure? {
    try database.read { try HealthDatabase.soundExposure(of: type, in: week, $0) }
  }

  @Test
  func underTheLimit() throws {
    // Two hours a day at 80 dB: 14 of the week's 40 hours.
    try insert((0..<7).map { level(at: at(day: $0, hours: 18), hours: 2, decibels: 80) })
    let exposure = try #require(try exposure())
    #expect(abs(exposure.dose - 14.0 / 40) < 1e-9)
    #expect(!exposure.isOverLimit)
  }

  @Test
  func overTheLimit() throws {
    // An hour a day at 95 dB: each is 10^1.5 hours at 80 dB, 5.5 times the week's limit.
    try insert((0..<7).map { level(at: at(day: $0, hours: 18), hours: 1, decibels: 95) })
    let exposure = try #require(try exposure())
    #expect(abs(exposure.dose - 7 * pow(10, 1.5) / 40) < 1e-9)
    #expect(exposure.isOverLimit)
  }

  @Test
  func everyThreeDecibelsHalveTheTime() throws {
    // 4 hours at 90 dB is the limit: 40 hours at 80 dB, ten times the energy for a tenth of the
    // time.
    try insert([level(at: at(day: 3, hours: 9), hours: 4, decibels: 90)])
    let atLimit = try #require(try exposure())
    #expect(abs(atLimit.dose - 1) < 1e-9)
    #expect(atLimit.isOverLimit)
  }

  @Test
  func noData() throws {
    // Only the other sound type, and headphones outside the week.
    try insert([
      level(environment, at: at(day: 2, hours: 12), hours: 3, decibels: 100),
      level(at: at(day: -3, hours: 12), hours: 3, decibels: 100),
      level(at: at(day: 7, hours: 1), hours: 3, decibels: 100),
    ])
    #expect(try exposure() == nil)
    #expect(try exposure(environment) != nil)
  }

  @Test
  func gapsCountAsQuietAndTheEdgesAsTheirPartInside() throws {
    try insert([
      // Half of this hour is before the week.
      level(at: at(day: 0, hours: -0.5), hours: 1, decibels: 80),
      // Days without samples between these two add nothing.
      level(at: at(day: 1, hours: 12), hours: 1, decibels: 83),
      level(at: at(day: 6, hours: 20), hours: 2, decibels: 80),
      // Half of this one is after it.
      level(at: at(day: 6, hours: 23.5), hours: 1, decibels: 80),
    ])
    let exposure = try #require(try exposure())
    let hours = 0.5 + pow(10, 0.3) + 2 + 0.5
    #expect(abs(exposure.dose - hours / 40) < 1e-9)
    #expect(!exposure.isOverLimit)
  }

  @Test
  func soundLevelSummariesHaveTheirWeeksExposureAndRanges() throws {
    try insert([
      level(at: at(day: 0, hours: 8), hours: 1, decibels: 70),
      level(at: at(day: 0, hours: 20), hours: 1, decibels: 90),
      // A month earlier, before the latest week.
      level(at: at(day: -30, hours: 8), hours: 40, decibels: 100),
      level(at: at(day: 6, hours: 8), hours: 2, decibels: 75),
    ])
    let summary = try database.read { db in
      try HealthDatabase.metricSummary(
        of: try #require(HealthCatalog.type(id: headphones)), now: week.upperBound,
        calendar: utcCalendar(), db)
    }
    let hours = pow(10, -1.0) + 10 + 2 * pow(10, -0.5)
    let dose = try #require(summary.soundExposure?.dose)
    #expect(abs(dose - hours / 40) < 1e-9)
    #expect(summary.days.map(\.minimum) == [70, 75])
    #expect(summary.days.map(\.maximum) == [90, 75])
  }

  @Test
  func otherTypesHaveNoExposure() throws {
    let heartRate = "HKQuantityTypeIdentifierHeartRate"
    try insert([level(heartRate, at: at(day: 2, hours: 8), hours: 1, decibels: 90)])
    let summary = try database.read { db in
      try HealthDatabase.metricSummary(
        of: try #require(HealthCatalog.type(id: heartRate)), now: week.upperBound,
        calendar: utcCalendar(), db)
    }
    #expect(summary.hasData)
    #expect(summary.soundExposure == nil)
  }
}
