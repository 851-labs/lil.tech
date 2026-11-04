import Dependencies
import Foundation
import GRDB
import HealthDatabase
import LilTestSupport
import SQLiteData
import Testing

/// `throttledObservation` (851-3237): a first value at once, a lone change at once, and a burst
/// of changes at most once per interval, on a `ManualClock`.
@Suite
struct ThrottledObservationTests {
  /// Counts the samples, and the fetches.
  private final class Observed: Sendable {
    let database: any DatabaseWriter
    let clock = ManualClock()
    let fetches = LockIsolated(0)
    let values = LockIsolated<[Result<Int, any Error>]>([])
    /// What a fetch does before counting: throw, or take time.
    let before = LockIsolated<@Sendable (Int) throws -> Void>({ _ in })
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init() throws {
      database = try HealthDatabase.make()
    }

    func start() {
      let stream = throttledObservation(
        of: [GRDB.Table<Row>(HealthSample.tableName)], in: database, clock: clock
      ) { [fetches, before] db in
        let count = try HealthSample.count().fetchOne(db) ?? 0
        fetches.withValue { $0 += 1 }
        try before.value(count)
        return count
      }
      task.setValue(
        Task { [values] in
          for await value in stream { values.withValue { $0.append(value) } }
        })
    }

    func stop() { task.value?.cancel() }

    var counts: [Int?] { values.value.map { try? $0.get() } }

    func writeSample() throws {
      try database.write { db in
        let id = UUID().uuidString.lowercased()
        try HealthSample.insert {
          HealthSample(
            id: id, type: HealthDatabase.heartRateType, startDate: 0, endDate: 1, value: 60,
            unit: "count/min", sourceName: "Apple Watch", sourceBundleID: "com.apple.health.watch")
        }
        .execute(db)
      }
    }
  }

  @Test
  func aBurstOfWritesIsFetchedOncePerInterval() async throws {
    let observed = try Observed()
    observed.start()
    defer { observed.stop() }
    try await eventually { observed.counts == [0] }

    // Within a second of the first fetch: one fetch once it's passed, of every write.
    for _ in 0..<5 { try observed.writeSample() }
    try await observed.clock.waitUntilAsleep(endingIn: .seconds(1))
    #expect(observed.fetches.value == 1)
    observed.clock.advance(by: .seconds(1))
    try await eventually { observed.counts == [0, 5] }
    #expect(observed.fetches.value == 2)

    // More, a second after that one.
    for _ in 0..<3 { try observed.writeSample() }
    try await observed.clock.waitUntilAsleep(endingIn: .seconds(1))
    observed.clock.advance(by: .seconds(1))
    try await eventually { observed.counts == [0, 5, 8] }
    #expect(observed.fetches.value == 3)
  }

  @Test
  func aWriteAfterAQuietSecondIsFetchedAtOnce() async throws {
    let observed = try Observed()
    observed.start()
    defer { observed.stop() }
    try await eventually { observed.counts == [0] }
    observed.clock.advance(by: .seconds(5))
    try observed.writeSample()
    try await eventually { observed.counts == [0, 1] }
    #expect(!observed.clock.isAsleep(dueWithin: .seconds(60)))
  }

  /// A write to a table it doesn't follow isn't fetched.
  @Test
  func otherTablesAreIgnored() async throws {
    let observed = try Observed()
    observed.start()
    defer { observed.stop() }
    try await eventually { observed.counts == [0] }
    observed.clock.advance(by: .seconds(5))
    try await observed.database.write { db in
      try HealthWorkout.insert {
        HealthWorkout(
          id: "w", activityType: 37, startDate: 0, endDate: 1, duration: 1, activities: "[]",
          events: "[]", statistics: "{}", sourceName: "Apple Watch",
          sourceBundleID: "com.apple.health.watch")
      }
      .execute(db)
    }
    try observed.writeSample()
    try await eventually { observed.counts == [0, 1] }
    #expect(observed.fetches.value == 2)
  }

  /// A fetch that throws is a value, and observing goes on.
  @Test
  func failuresAreValues() async throws {
    struct Failure: Error {}
    let observed = try Observed()
    observed.before.setValue { count in if count == 1 { throw Failure() } }
    observed.start()
    defer { observed.stop() }
    try await eventually { observed.counts == [0] }
    observed.clock.advance(by: .seconds(5))
    try observed.writeSample()
    try await eventually { observed.values.value.count == 2 }
    #expect(observed.counts == [0, nil])
    observed.clock.advance(by: .seconds(5))
    try observed.writeSample()
    try await eventually { observed.counts == [0, nil, 2] }
  }

  /// A slow fetch spaces the next out to 4 times its length.
  @Test
  func slowFetchesAreSpacedOut() async throws {
    let observed = try Observed()
    observed.before.setValue { [clock = observed.clock] _ in clock.advance(by: .seconds(2)) }
    observed.start()
    defer { observed.stop() }
    try await eventually { observed.counts == [0] }
    try observed.writeSample()
    // The first fetch started 2 seconds ago, so the next starts in 6.
    try await observed.clock.waitUntilAsleep(endingIn: .seconds(6))
    observed.clock.advance(by: .seconds(6))
    try await eventually { observed.counts == [0, 1] }
  }

  /// Once its consumer stops, it fetches no more.
  @Test
  func stopsWithItsConsumer() async throws {
    let observed = try Observed()
    observed.start()
    try await eventually { observed.counts == [0] }
    observed.stop()
    observed.clock.advance(by: .seconds(5))
    try observed.writeSample()
    try await Task.sleep(for: .milliseconds(100))
    #expect(observed.fetches.value == 1)
  }
}
