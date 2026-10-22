import Dependencies
import Foundation
import HealthDatabase
import LilAPI
import LilSync
import SQLite3
import SQLiteData
import Testing

/// How many records `SyncLoadBenchmark` loads, from `LIL_BENCH_LOAD_RECORDS`.
private let loadBenchmarkRecords = ProcessInfo.processInfo.environment["LIL_BENCH_LOAD_RECORDS"]
  .flatMap { Int($0.replacingOccurrences(of: "_", with: "")) }

/// The Mac's bootstrap inserts alone, without a stage (851-2859): `LilSyncEngine.bootstrap()`
/// with the Mac's health entities loads a synthetic snapshot served from memory into a new
/// database on disk, so the time is all decoding and inserting. Run it in Release:
///
/// ```sh
/// LIL_BENCH_LOAD_RECORDS=1000000 swift test -c release --filter SyncLoadBenchmark
/// ```
///
/// The snapshot is shaped like a stage's: nine in ten records are health samples, in their key
/// order (type, then start date) with random HealthKit UUIDs, the rest statistics, by ID. It
/// prints the time a record and SQLite's page cache counters: pages read from disk (misses) and
/// written a record.
@Suite(.enabled(if: loadBenchmarkRecords != nil))
struct SyncLoadBenchmark {
  @Test
  func load() async throws {
    let records = try #require(loadBenchmarkRecords)
    let snapshot = try Self.snapshot(records: records)
    let directory = URL.temporaryDirectory.appending(
      path: "lil-bench-load-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try HealthDatabase.make(at: directory.appending(path: "health.sqlite"))
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = snapshot.client
      $0.snapshotDownloader = snapshot.downloader
      $0.continuousClock = ContinuousClock()
      $0.date = .init { Date() }
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
    } operation: {
      LilSyncEngine(
        entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema,
        partsDirectory: directory.appending(path: "parts", directoryHint: .isDirectory))
    }

    let start = ContinuousClock.now
    try await engine.bootstrap()
    let elapsed = ContinuousClock.now - start
    let seconds =
      Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let stored = try await database.read { db in
      try Int.fetchOne(
        db,
        sql:
          #"SELECT (SELECT count(*) FROM "healthSamples") + (SELECT count(*) FROM "healthStatistics")"#
      )
    }
    #expect(stored == records)
    // The writer's counters, since it opened.
    let (misses, writes) = try await database.writeWithoutTransaction { db in
      func counter(_ operation: Int32) -> Int32 {
        var current: Int32 = 0
        var highwater: Int32 = 0
        sqlite3_db_status(db.sqliteConnection, operation, &current, &highwater, 0)
        return current
      }
      return (counter(SQLITE_DBSTATUS_CACHE_MISS), counter(SQLITE_DBSTATUS_CACHE_WRITE))
    }
    let perRecord = { (value: Int32) in String(format: "%.2f", Double(value) / Double(records)) }
    print(
      """
      SyncLoadBenchmark: \(records) records in \(String(format: "%.1f", seconds)) s, \
      \(String(format: "%.1f", seconds / Double(records) * 1e6)) µs a record; pages read \
      \(perRecord(misses)) and written \(perRecord(writes)) a record
      """
    )
  }

  private static func snapshot(records: Int) throws -> TestSnapshot {
    var random = SeededGenerator(seed: 2859)
    let statistics = records / 10
    let samples = records - statistics
    // Sorted by type, as a store sends them.
    let types = [
      ("HKQuantityTypeIdentifierActiveEnergyBurned", "kcal", 0.2),
      ("HKQuantityTypeIdentifierBasalEnergyBurned", "kcal", 0.15),
      ("HKQuantityTypeIdentifierDistanceWalkingRunning", "m", 0.1),
      ("HKQuantityTypeIdentifierHeartRate", "count/min", 0.45),
      ("HKQuantityTypeIdentifierStepCount", "count", 0.1),
    ]
    let end = 1_760_400_000_000
    var sampleLines: [String] = []
    sampleLines.reserveCapacity(samples)
    for (index, (type, unit, share)) in types.enumerated() {
      let count =
        index == types.count - 1 ? samples - sampleLines.count : Int(Double(samples) * share)
      for sample in 0..<count {
        let startDate = end - (count - sample) * 60_000
        let value = Double(random.next() % 10_000) / 100
        sampleLines.append(
          #"{"id":"\#(random.uuid())","type":"\#(type)","startDate":\#(startDate),"#
            + #""endDate":\#(startDate + 60_000),"value":\#(value),"unit":"\#(unit)","#
            + #""categoryValue":null,"correlationId":null,"sourceName":"Synthetic Watch","#
            + #""sourceBundleId":"com.example.watch","sourceRevision":null,"device":null,"#
            + #""metadata":null,"provenance":"0123456789abcdef0123456789abcdef"}"#
        )
      }
    }
    let device = "dev_000000000000000000000000ph"
    var statisticLines = (0..<statistics).map { index in
      let type =
        index.isMultiple(of: 2)
        ? "HKQuantityTypeIdentifierStepCount" : "HKQuantityTypeIdentifierActiveEnergyBurned"
      let bucketStart = end - (statistics - index / 2) * 1_800_000
      return (id: "\(device)/\(type)@\(bucketStart)", type: type, bucketStart: bucketStart)
    }
    // By ID, as a store sends an entity without key fields.
    statisticLines.sort { $0.id < $1.id }
    let statisticRecords = statisticLines.map { statistic in
      let sum = Double(random.next() % 1_000)
      return #"{"id":"\#(statistic.id)","device":"\#(device)","type":"\#(statistic.type)","#
        + #""bucketStart":\#(statistic.bucketStart),"sum":\#(sum),"unit":"count"}"#
    }
    return try TestSnapshot(
      seq: records,
      entities: [("health_sample", sampleLines), ("health_statistic", statisticRecords)])
  }
}

/// A seeded generator, so every run loads the same records.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// A lowercase version 4 UUID, as HealthKit's are once lowercased.
  mutating func uuid() -> String {
    var bytes = (0..<16).map { _ in UInt8(truncatingIfNeeded: next()) }
    bytes[6] = bytes[6] & 0x0F | 0x40
    bytes[8] = bytes[8] & 0x3F | 0x80
    let uuid = UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
    return uuid.uuidString.lowercased()
  }
}
