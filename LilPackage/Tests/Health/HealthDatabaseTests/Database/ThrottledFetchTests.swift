import Dependencies
import Foundation
import GRDB
import HealthCardStore
import LilTestSupport
import SQLiteData
import Testing

@testable import HealthDatabase

/// `ThrottledFetch`'s model (851-4045): what a request given shows at once, and what sync's writes
/// change, on a `ManualClock`.
@MainActor
@Suite
struct ThrottledFetchTests {
  let database: any DatabaseWriter
  let clock = ManualClock()
  let fetches = LockIsolated(0)

  init() throws {
    database = try HealthDatabase.make()
  }

  @Test
  func aRequestLoadsItsFirstValue() async throws {
    let model = ThrottledFetchModel<Int?>(value: nil, isLoading: false)
    await model.load(request(SampleCount()))
    #expect(model.value == 0)
    #expect(!model.isLoading)
    #expect(fetches.value == 1)
  }

  /// A write sync makes is fetched again, without loading: the last value stays until it's in.
  @Test
  func writesRefreshWithoutLoading() async throws {
    let model = ThrottledFetchModel<Int?>(value: nil, isLoading: false)
    await model.load(request(SampleCount()))
    clock.advance(by: .seconds(5))
    try writeSample()
    try await eventually { model.value == 1 }
    #expect(!model.isLoading)
  }

  /// Another request loads at once, and stops the last one's observation.
  @Test
  func anotherRequestLoads() async throws {
    let model = ThrottledFetchModel<Int?>(value: nil, isLoading: false)
    await model.load(request(SampleCount(type: "other")))
    try writeSample()
    await model.load(request(SampleCount()))
    #expect(model.value == 1)
    #expect(!model.isLoading)
    clock.advance(by: .seconds(5))
    try await Task.sleep(for: .milliseconds(50))
    #expect(fetches.value == 2)
  }

  /// Loading what's observed, as a page's task does when it appears again, fetches nothing.
  @Test
  func theSameRequestIsntFetchedAgain() async throws {
    let model = ThrottledFetchModel<Int?>(value: nil, isLoading: false)
    await model.load(request(SampleCount()))
    await model.load(request(SampleCount()))
    #expect(fetches.value == 1)
  }

  /// A failure is `loadError`, with the last value kept, until a fetch succeeds.
  @Test
  func failuresKeepTheLastValue() async throws {
    let model = ThrottledFetchModel<Int?>(value: nil, isLoading: false)
    await model.load(request(SampleCount(failsAt: 1)))
    clock.advance(by: .seconds(5))
    try writeSample()
    try await eventually { model.loadError != nil }
    #expect(model.value == 0)
    #expect(!model.isLoading)
    clock.advance(by: .seconds(5))
    try writeSample()
    try await eventually { model.value == 2 }
    #expect(model.loadError == nil)
  }

  /// It follows the request the view was made with, once each time it changes.
  @Test
  func followsTheViewsRequest() async throws {
    let model = ThrottledFetchModel<Int?>(value: nil, isLoading: true)
    model.follow(request(SampleCount()))
    try await eventually { model.value == 0 }
    #expect(!model.isLoading)
    model.follow(request(SampleCount()))
    try await Task.sleep(for: .milliseconds(50))
    #expect(fetches.value == 1)

    model.follow(request(SampleCount(type: "other")))
    #expect(model.isLoading)
    try await eventually { !model.isLoading }
    #expect(fetches.value == 2)
  }

  /// Another request starts without the last one's failure, as `@Fetch`'s did.
  @Test
  func anotherRequestClearsTheLastFailure() async throws {
    let model = ThrottledFetchModel<Int?>(value: nil, isLoading: false)
    await model.load(request(SampleCount(failsAt: 0)))
    #expect(model.loadError != nil)
    model.follow(request(SampleCount()))
    #expect(model.loadError == nil)
    #expect(model.isLoading)
    try await eventually { model.value == 0 }
  }

  /// In a window catalog, the view's request is read at once, a loaded one in the background,
  /// and neither is observed.
  @Test
  func windowCatalogsReadWithoutObserving() async throws {
    let model = ThrottledFetchModel<Int?>(value: nil, isLoading: true)
    let catalog = { (request: SampleCount) in
      withDependencies {
        $0.fetchesFirstValueAtOnce = true
      } operation: {
        self.request(request)
      }
    }
    model.readAtOnce(catalog(SampleCount()))
    #expect(model.value == 0)
    #expect(!model.isLoading)
    model.follow(catalog(SampleCount()))
    #expect(fetches.value == 1)

    await model.load(catalog(SampleCount(type: "other")))
    #expect(fetches.value == 2)
    clock.advance(by: .seconds(5))
    try writeSample()
    try await Task.sleep(for: .milliseconds(50))
    clock.advance(by: .seconds(5))
    try await Task.sleep(for: .milliseconds(50))
    #expect(fetches.value == 2)
  }

  /// `dataTables` is every table but the cards, pins and sync's own, so a table a migration adds
  /// for a new kind of record is followed too.
  @Test
  func dataTablesAreEveryRecordTable() throws {
    try database.read { db in
      let others: Set = [HealthCard.tableName, "healthPins"]
      let records = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            AND name NOT LIKE 'lil%'
          """
      )
      .filter { !others.contains($0) }
      let region = { (tables: [any DatabaseRegionConvertible]) in
        try tables.reduce(DatabaseRegion()) { $0.union(try $1.databaseRegion(db)) }
      }
      #expect(
        try region(HealthDatabase.dataTables) == region(records.map { GRDB.Table<Row>($0) }),
        "\(records.sorted())")
    }
  }

  // MARK: - Helpers

  /// Counts heart rate samples, or another type's, failing when there are `failsAt`.
  struct SampleCount: FetchKeyRequest {
    var type = HealthDatabase.heartRateType
    var failsAt: Int?

    func fetch(_ db: Database) throws -> Int? {
      @Dependency(Fetches.self) var fetches
      fetches.withValue { $0 += 1 }
      let count = try HealthSample.where { $0.type.eq(type) }.fetchCount(db)
      struct Failure: Error {}
      if count == failsAt { throw Failure() }
      return count
    }
  }

  /// `SampleCount`'s fetches, a dependency so the fetch reads where the request was given.
  enum Fetches: TestDependencyKey {
    static var testValue: LockIsolated<Int> { LockIsolated(0) }
  }

  func request(
    _ request: SampleCount,
    tables: [any DatabaseRegionConvertible] = HealthDatabase.dataTables
  ) -> ThrottledFetchModel<Int?>.Request {
    withDependencies {
      $0.defaultDatabase = database
      $0.continuousClock = clock
      $0[Fetches.self] = fetches
    } operation: {
      ThrottledFetchModel<Int?>.Request(request, tables: tables)
    }
  }

  func writeSample() throws {
    try database.write { db in
      try HealthSample.insert {
        HealthSample(
          id: UUID().uuidString.lowercased(), type: HealthDatabase.heartRateType, startDate: 0,
          endDate: 1, value: 60, unit: "count/min", sourceName: "Apple Watch",
          sourceBundleID: "com.apple.health.watch")
      }
      .execute(db)
    }
  }
}
