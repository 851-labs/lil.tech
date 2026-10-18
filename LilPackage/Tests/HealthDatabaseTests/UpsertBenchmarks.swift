import Foundation
import GRDB
import SQLiteData
import Testing

@testable import HealthDatabase

/// Upsert cost per row, one table's way against the other. Run in Release with
/// `LIL_BENCHMARKS=1 swift test -c release --filter UpsertBenchmarks`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIL_BENCHMARKS"] == "1"))
struct UpsertBenchmarks {
  @Test
  func workouts() throws {
    let rows = 20_000
    let workout = { (index: Int) in
      HealthWorkout(
        id: String(format: "6f1c2a40-0000-4000-8000-%012d", index), activityType: 37,
        startDate: 1_760_400_000_000 + index * 3_600_000,
        endDate: 1_760_400_000_000 + index * 3_600_000 + 1_800_000, duration: 1800,
        activities: #"[{"activityType":37,"startDate":1760400000000}]"#,
        events: #"[{"type":1,"startDate":1760400600000}]"#,
        statistics: #"{"HKQuantityTypeIdentifierActiveEnergyBurned":{"sum":312.5,"unit":"kcal"}}"#,
        sourceName: "Apple Watch", sourceBundleID: "com.apple.health",
        sourceRevision: #"{"version":"26.0"}"#, device: #"{"name":"Apple Watch"}"#,
        metadata: #"{"HKIndoorWorkout":false}"#)
    }
    let workouts = (0..<rows).map(workout)
    let upsert = PreparedUpsert<HealthWorkout>()
    try compare(
      "built queries", "prepared", rows: rows, unit: "workout",
      { db in for workout in workouts { try HealthWorkout.upsert { workout }.execute(db) } },
      { db in for workout in workouts { try upsert.execute(workout, db) } })
  }

  @Test
  func samples() throws {
    let rows = 100_000
    let samples = (0..<rows).map { index in
      HealthSample(
        id: String(format: "6f1c2a40-0000-4000-8000-%012d", index),
        type: "HKQuantityTypeIdentifierStepCount", startDate: 1_760_400_000_000 + index * 60_000,
        endDate: 1_760_400_000_000 + index * 60_000 + 30_000, value: Double(index % 100),
        unit: "count", sourceName: "Apple Watch", sourceBundleID: "com.apple.health",
        sourceRevision: #"{"version":"26.0"}"#, device: #"{"name":"Apple Watch"}"#)
    }
    let upsert = PreparedUpsert<HealthSample>()
    // As 851-2649 wrote it by hand: the values in column order, no query fragments.
    let byHand = { (sample: HealthSample) -> StatementArguments in
      [
        sample.id, sample.type, sample.startDate, sample.endDate, sample.value, sample.unit,
        sample.categoryValue, sample.correlationID, sample.sourceName, sample.sourceBundleID,
        sample.sourceRevision, sample.device, sample.metadata,
      ]
    }
    try compare(
      "values by hand", "from the columns", rows: rows, unit: "sample",
      { db in
        for sample in samples {
          try db.cachedStatement(sql: upsert.sql).execute(arguments: byHand(sample))
        }
      },
      { db in for sample in samples { try upsert.execute(sample, db) } })
  }
}

/// Times `first` and `second`, each writing into a new database, over four rounds. Which goes
/// first alternates, so warming up favors neither.
private func compare(
  _ firstName: String, _ secondName: String, rows: Int, unit: String,
  _ first: (Database) throws -> Void, _ second: (Database) throws -> Void
) throws {
  let clock = ContinuousClock()
  let time = { (body: (Database) throws -> Void) in
    let database = try HealthDatabase.make()
    return try clock.measure { try database.write(body) }
  }
  for round in 1...4 {
    let (firstTime, secondTime) =
      round.isMultiple(of: 2)
      ? try {
        let b = try time(second)
        return (try time(first), b)
      }()
      : (try time(first), try time(second))
    print(
      "Round \(round): \(firstName) \(microseconds(firstTime, rows)) µs a \(unit),"
        + " \(secondName) \(microseconds(secondTime, rows)) µs")
  }
}

private func microseconds(_ duration: Duration, _ rows: Int) -> String {
  let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  return String(format: "%.1f", seconds * 1e6 / Double(rows))
}
