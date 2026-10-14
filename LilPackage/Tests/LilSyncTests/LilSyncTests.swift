import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import LilAPI
import LilSync
import OpenAPIRuntime
import SQLiteData
import Testing

@Table("note")
struct Note: Equatable {
  let id: String
  var title: String
}

private struct NoteRow: Decodable {
  let id: String
  let title: String
}

private let notes = SyncEntity.decoding(
  "note",
  as: NoteRow.self,
  upsert: { row, db in
    try Note.upsert { Note(id: row.id, title: row.title) }.execute(db)
  },
  delete: { id, db in
    try Note.find(id).delete().execute(db)
  }
)

private func makeDatabase() throws -> any DatabaseWriter {
  let database = try DatabaseQueue()
  var migrator = DatabaseMigrator()
  LilSyncEngine.registerMigrations(in: &migrator)
  migrator.registerMigration("Create note") { db in
    try #sql(#"CREATE TABLE "note" ("id" TEXT PRIMARY KEY, "title" TEXT NOT NULL) STRICT"#)
      .execute(db)
  }
  try migrator.migrate(database)
  return database
}

/// A change log served two changes per page, like `GET /v1/sync/changes`.
private final class FakeServer: Sendable {
  struct State {
    var changes: [Components.Schemas.Change] = []
    var epoch = 1
    var horizon = 0
    /// Request numbers (1-based) that fail with a 500.
    var failing: Set<Int> = []
    /// Answer with an empty page that claims there's more, like a broken server.
    var stuck = false
    var requests: [Int] = []
  }
  let state = LockIsolated(State())
  let pageSize = 2

  func append(_ change: (_ seq: Int) -> Components.Schemas.Change) {
    let seq = state.value.changes.count + 1
    let made = change(seq)
    state.withValue { $0.changes.append(made) }
  }

  var client: Client {
    .mock { [self] request, _ in
      let after =
        Int(
          URLComponents(string: request.path ?? "")?.queryItems?
            .first { $0.name == "after" }?.value ?? "0") ?? 0
      return try state.withValue { state in
        state.requests.append(after)
        if state.failing.contains(state.requests.count) {
          return (HTTPResponse(status: .internalServerError), nil)
        }
        if after < state.horizon {
          return try json(.gone, ["_tag": "ChangesCompacted", "reason": "compacted"])
        }
        let page =
          state.stuck ? [] : Array(state.changes.filter { $0.seq > after }.prefix(pageSize))
        let next = page.last?.seq ?? after
        let head = state.changes.last?.seq ?? 0
        if state.stuck {
          return try json(
            .ok,
            Components.Schemas.ChangesPage(
              epoch: state.epoch, changes: [], next: after, head: head, hasMore: true))
        }
        return try json(
          .ok,
          Components.Schemas.ChangesPage(
            epoch: state.epoch, changes: page, next: next, head: head, hasMore: next < head))
      }
    }
  }

  private func json(_ status: HTTPResponse.Status, _ body: some Encodable) throws -> (
    HTTPResponse, HTTPBody?
  ) {
    (
      HTTPResponse(status: status, headerFields: [.contentType: "application/json"]),
      HTTPBody(try JSONEncoder().encode(body))
    )
  }
}

private func upsert(_ id: String, _ title: String) -> (Int) -> Components.Schemas.Change {
  { seq in
    Components.Schemas.Change(
      seq: seq, entity: "note", id: id, op: "upsert",
      row: try! OpenAPIObjectContainer(unvalidatedValue: ["id": id, "title": title]),
      at: 1_760_400_000_000)
  }
}

private func delete(_ id: String, entity: String = "note") -> (Int) -> Components.Schemas.Change {
  { seq in
    Components.Schemas.Change(seq: seq, entity: entity, id: id, op: "delete", at: 1_760_400_000_000)
  }
}

@Suite
struct LilSyncEngineTests {
  fileprivate let server = FakeServer()
  let database: any DatabaseWriter

  init() throws {
    database = try makeDatabase()
  }

  private func engine(entities: [SyncEntity] = [notes]) -> LilSyncEngine {
    withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.continuousClock = ImmediateClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
    } operation: {
      LilSyncEngine(entities: entities)
    }
  }

  private func storedNotes() throws -> [Note] {
    try database.read { try Note.order(by: \.id).fetchAll($0) }
  }

  private func cursor() throws -> Int? {
    try database.read { db in
      try #sql("SELECT cursor FROM lilSyncState", as: Int.self).fetchOne(db)
    }
  }

  @Test
  func appliesEveryPageAndItsCursor() async throws {
    server.append(upsert("n1", "One"))
    server.append(upsert("n2", "Two"))
    server.append(upsert("n1", "One, renamed"))
    server.append(delete("n2"))
    server.append(upsert("n3", "Three"))

    try await engine().pull()

    #expect(
      try storedNotes() == [Note(id: "n1", title: "One, renamed"), Note(id: "n3", title: "Three")])
    #expect(try cursor() == 5)
    #expect(server.state.requests == [0, 2, 4])
  }

  @Test
  func resumesAfterAFailureMidSync() async throws {
    for n in 1...5 { server.append(upsert("n\(n)", "Note \(n)")) }
    server.state.withValue { $0.failing = [2] }
    let engine = engine()

    await #expect(throws: SyncError.unexpectedStatus(500)) { try await engine.pull() }
    #expect(try cursor() == 2)
    #expect(try storedNotes().count == 2)

    try await engine.pull()
    #expect(try storedNotes().count == 5)
    #expect(server.state.requests == [0, 2, 2, 4])
  }

  @Test
  func neverMovesTheCursorPastChangesItCouldNotApply() async throws {
    server.append(upsert("n1", "One"))
    server.append(upsert("n2", "Two"))
    server.append(upsert("n3", "Three"))
    server.append(upsert("n4", "Four"))
    struct Broken: Error {}
    let failing = SyncEntity(
      name: "note",
      upsert: { id, row, db in
        if id == "n4" { throw Broken() }
        try notes.upsertForTesting(id, row, db)
      },
      delete: { _, _ in }
    )

    let engine = engine(entities: [failing])
    await #expect(throws: Broken.self) { try await engine.pull() }
    // The second page rolled back whole: n3 was applied before n4 failed, but isn't kept.
    #expect(try storedNotes().map(\.id) == ["n1", "n2"])
    #expect(try cursor() == 2)
  }

  @Test
  func skipsEntitiesAndOpsItDoesNotKnowButMovesPastThem() async throws {
    server.append(delete("x", entity: "health_sample"))
    server.append { seq in
      Components.Schemas.Change(seq: seq, entity: "note", id: "n1", op: "touch", at: 0)
    }
    server.append(upsert("n1", "One"))

    try await engine().pull()
    #expect(try storedNotes() == [Note(id: "n1", title: "One")])
    #expect(try cursor() == 3)
  }

  @Test
  func needsABootstrapWhenTheEpochChanges() async throws {
    server.append(upsert("n1", "One"))
    let engine = engine()
    try await engine.pull()

    server.state.withValue { $0.epoch = 2 }
    await #expect(throws: SyncError.needsBootstrap) { try await engine.pull() }
    #expect(try storedNotes().count == 1)
  }

  @Test
  func needsABootstrapWhenTheChangesWereCompactedOrTheServerWentBack() async throws {
    for n in 1...3 { server.append(upsert("n\(n)", "Note \(n)")) }
    server.state.withValue { $0.horizon = 1 }
    await #expect(throws: SyncError.needsBootstrap) { try await engine().pull() }

    let caughtUp = try makeDatabase()
    try await caughtUp.write { db in
      try #sql("INSERT INTO lilSyncState (id, cursor, epoch) VALUES (1, 10, 1)").execute(db)
    }
    let engine = withDependencies {
      $0.defaultDatabase = caughtUp
      $0.api = server.client
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
    } operation: {
      LilSyncEngine(entities: [notes])
    }
    await #expect(throws: SyncError.needsBootstrap) { try await engine.pull() }
  }

  @Test
  func skipsRowsItCannotReadInsteadOfStopping() async throws {
    server.append { seq in
      Components.Schemas.Change(
        seq: seq, entity: "note", id: "n1", op: "upsert",
        row: try! OpenAPIObjectContainer(unvalidatedValue: ["id": "n1", "title": 7]), at: 0)
    }
    server.append(upsert("n2", "Two"))
    let engine = engine()

    try await withKnownIssue {
      try await engine.pull()
    } matching: {
      $0.description.contains("Skipped note change 1")
    }
    #expect(try storedNotes() == [Note(id: "n2", title: "Two")])
    #expect(try cursor() == 2)
  }

  @Test
  func needsABootstrapWhenAPageHasAGap() async throws {
    for n in 1...3 { server.append(upsert("n\(n)", "Note \(n)")) }
    server.state.withValue { _ = $0.changes.remove(at: 1) }
    await #expect(throws: SyncError.needsBootstrap) { try await engine().pull() }
    #expect(try storedNotes().isEmpty)
  }

  @Test
  func refusesAPageThatMakesNoProgress() async throws {
    server.append(upsert("n1", "One"))
    server.state.withValue { $0.stuck = true }
    await #expect(throws: SyncError.unexpectedPage) { try await engine().pull() }
    #expect(server.state.requests.count == 1)
  }

  @Test
  func reportsEntitiesRegisteredTwice() {
    withKnownIssue {
      _ = engine(entities: [notes, notes])
    } matching: {
      $0.description.contains("registered more than once")
    }
  }

  @Test
  func runRetriesWithBackoffAndReportsStatus() async throws {
    server.append(upsert("n1", "One"))
    server.state.withValue { $0.failing = [1, 2] }
    let clock = TestClock()
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.continuousClock = clock
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
    } operation: {
      LilSyncEngine(entities: [notes])
    }
    let statuses = LockIsolated<[SyncStatus]>([])
    let updates = await engine.statusUpdates()
    let observing = Task {
      for await status in updates { statuses.withValue { $0.append(status) } }
    }
    let running = Task { await engine.run() }

    // Backoff is at most 1 second after the first failure and 2 after the second.
    try await eventually { server.state.requests.count == 1 }
    await clock.advance(by: .seconds(1))
    try await eventually { server.state.requests.count == 2 }
    await clock.advance(by: .seconds(2))
    try await eventually { try storedNotes() == [Note(id: "n1", title: "One")] }

    // An idle engine pulls again when asked, without waiting out the interval.
    server.append(upsert("n2", "Two"))
    await engine.syncNow()
    try await eventually { try storedNotes().count == 2 }

    // Cancelling ends the idle wait right away.
    running.cancel()
    await running.value
    try await eventually { statuses.value.last == .idle }
    observing.cancel()
    #expect(statuses.value.first == .idle)
    #expect(statuses.value.contains(.failed("unexpectedStatus(500)")))
  }

  @Test
  func cancellingRunEndsABackoffRightAway() async throws {
    server.state.withValue { $0.failing = [1] }
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.continuousClock = TestClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
    } operation: {
      LilSyncEngine(entities: [notes])
    }
    let running = Task { await engine.run() }
    try await eventually { server.state.requests.count == 1 }
    running.cancel()
    // The test clock never advances, so this only returns because cancellation ends the wait.
    await running.value
  }
}

/// Waits for `condition`, which other tasks make true, yielding in between.
private func eventually(
  _ condition: () throws -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  for _ in 0..<10_000 {
    if try condition() { return }
    await Task.yield()
  }
  Issue.record("Condition never became true", sourceLocation: sourceLocation)
}

extension SyncEntity {
  fileprivate func upsertForTesting(_ id: String, _ row: OpenAPIObjectContainer, _ db: Database)
    throws
  {
    try Note.upsert {
      Note(id: id, title: row.value["title"] as? String ?? "")
    }
    .execute(db)
  }
}

/// A seeded generator, so backoff jitter is the same every run.
private struct LCRNG: RandomNumberGenerator {
  var seed: UInt64
  mutating func next() -> UInt64 {
    seed = 2_862_933_555_777_941_757 &* seed &+ 3_037_000_493
    return seed
  }
}
