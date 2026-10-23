import CryptoKit
import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import LilAPI
import LilGzip
import LilTestSupport
import OpenAPIRuntime
import SQLiteData
import Testing

@testable import LilSync

@Table("note")
struct Note: Equatable {
  let id: String
  var title: String
}

/// A second entity, which an older release doesn't store (851-3222).
@Table("tag")
struct Tag: Equatable {
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
  },
  clear: { db in
    try Note.delete().execute(db)
  }
)

/// Tags, loaded through a staging table as apps' entities are.
private let tags = SyncEntity.decoding(
  "tag", as: NoteRow.self, table: "tag",
  insert: { row, staging, db in try stage(row, in: staging, db) },
  upsert: { row, db in
    try Tag.upsert { Tag(id: row.id, title: row.title) }.execute(db)
  },
  delete: { id, db in
    try Tag.find(id).delete().execute(db)
  },
  clear: { db in
    try Tag.delete().execute(db)
  }
)

/// Notes whose snapshots load through a staging table (851-2859), as apps' entities do.
private let stagedNotes = makeStagedNotes { row, staging, db in try stage(row, in: staging, db) }

private func makeStagedNotes(
  insert: @escaping @Sendable (_ row: NoteRow, _ staging: String, _ db: Database) throws -> Void
) -> SyncEntity {
  SyncEntity.decoding(
    "note", as: NoteRow.self, table: "note",
    insert: insert,
    upsert: { row, db in
      try Note.upsert { Note(id: row.id, title: row.title) }.execute(db)
    },
    delete: { id, db in
      try Note.find(id).delete().execute(db)
    },
    clear: { db in
      try Note.delete().execute(db)
    }
  )
}

private func stage(_ row: NoteRow, title: String?? = nil, in staging: String, _ db: Database)
  throws
{
  try db.execute(
    sql: #"INSERT INTO "\#(staging)" ("id", "title") VALUES (?, ?)"#,
    arguments: [row.id, title ?? row.title])
}

/// The database's schema: its tables and indexes, with their SQL.
private func schema(_ database: any DatabaseWriter) throws -> [String] {
  try database.read { db in
    try String.fetchAll(
      db,
      sql: "SELECT type || ' ' || name || ': ' || ifnull(sql, '') FROM sqlite_master ORDER BY name")
  }
}

/// Tables in the writer's temporary schema, where staging tables are.
private func temporaryTables(_ database: any DatabaseWriter) throws -> [String] {
  try database.write { db in
    try String.fetchAll(db, sql: "SELECT name FROM temp.sqlite_master")
  }
}

/// When the tests' pulls end.
private let syncedAt = Date(timeIntervalSince1970: 1_760_400_000)

/// A database for a client that already started on epoch 1 (`bootstrapped`), or a new one.
private func makeDatabase(bootstrapped: Bool = true, at path: String? = nil) throws
  -> any DatabaseWriter
{
  // In memory, or a file (in WAL mode) for tests about what the files hold.
  let database: any DatabaseWriter = try path.map { try DatabasePool(path: $0) } ?? DatabaseQueue()
  var migrator = DatabaseMigrator()
  LilSyncEngine.registerMigrations(in: &migrator)
  migrator.registerMigration("Create note") { db in
    try #sql(#"CREATE TABLE "note" ("id" TEXT PRIMARY KEY, "title" TEXT NOT NULL) STRICT"#)
      .execute(db)
    // An index besides the primary key's, which loading a snapshot drops and builds again.
    try #sql(#"CREATE INDEX "note_title" ON "note" ("title")"#).execute(db)
  }
  migrator.registerMigration("Create tag") { db in
    try #sql(#"CREATE TABLE "tag" ("id" TEXT PRIMARY KEY, "title" TEXT NOT NULL) STRICT"#)
      .execute(db)
  }
  try migrator.migrate(database)
  if bootstrapped {
    try database.write { db in
      try #sql("INSERT INTO lilSyncState (id, cursor, epoch) VALUES (1, 0, 1)").execute(db)
    }
  }
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
    /// Request numbers (1-based) that fail without a connection.
    var offline: Set<Int> = []
    /// Requests for changes hang until cancelled, like a stalled connection.
    var hanging = false
    /// Request numbers (1-based) that are rate limited for 30 seconds.
    var rateLimited: Set<Int> = []
    /// Answer with an empty page that claims there's more, like a broken server.
    var stuck = false
    var requests: [Int] = []
    /// The `limit` of each request for changes.
    var limits: [Int] = []
    /// The `entities` filter of each request for changes, if any.
    var filters: [String?] = []
    /// Ignore `entities`, like a server from before the filter (851-3221).
    var ignoresEntities = false
    /// Answer with a `next` one past the page's, like a broken server that skips a change.
    var skipping = false
    /// Changes written while a request for changes is answered, by request number (1-based):
    /// they're given the next `seq`s after it.
    var arriving: [Int: [Components.Schemas.Change]] = [:]
    /// The store's latest snapshot: its manifest and each part's bytes by URL.
    var snapshot: Components.Schemas.SnapshotManifest?
    var partBytes: [String: Data] = [:]
    /// URLs that answer as expired; `GET /v1/sync/snapshots/{id}` hands out fresh ones.
    var expiredURLs: Set<String> = []
    /// URLs whose next download fails as a dropped connection.
    var interrupted: Set<String> = []
    var downloads: [String] = []
    var snapshotRequests = 0
    /// Pushed mutation IDs, in order, and each one's `seq` (`POST /v1/sync/mutations`).
    var pushes: [String] = []
    var pushed: [String: Int] = [:]
    /// Pushes are refused as invalid.
    var refusingPushes = false
    /// Pushes fail as unavailable.
    var failingPushes = false
    /// A snapshot that replaces the latest, with its parts' bytes, once the latest was asked for.
    var replacingSnapshot: (Components.Schemas.SnapshotManifest, [String: Data])?
  }
  let state = LockIsolated(State())

  /// Publishes a snapshot of `notes` and `tags` as of `seq`, `perPart` records per part.
  func publishSnapshot(
    id: String = "snp_1", seq: Int, notes: [Note], tags: [Tag] = [], perPart: Int = 2
  ) throws {
    var bytes: [String: Data] = [:]
    func parts(_ records: [(id: String, title: String)], named name: String) throws
      -> [Components.Schemas.SnapshotPart]
    {
      var parts: [Components.Schemas.SnapshotPart] = []
      for (index, start) in stride(from: 0, to: records.count, by: perPart).enumerated() {
        let lines = records[start..<min(start + perPart, records.count)]
          .map { #"{"id":"\#($0.id)","title":"\#($0.title)"}"# }
          .joined(separator: "\n")
        let gzip = try Gzip.compress(Data(lines.utf8))
        let url = "https://api.test/v1/sync/parts?token=\(id)-\(name)\(index)"
        bytes[url] = gzip
        let sha = SHA256.hash(data: gzip).map { String(format: "%02x", $0) }.joined()
        parts.append(
          .init(
            url: url, records: lines.split(separator: "\n").count, bytes: gzip.count, sha256: sha)
        )
      }
      return parts
    }
    let noteParts = try parts(notes.map { ($0.id, $0.title) }, named: "")
    let tagParts = try parts(tags.map { ($0.id, $0.title) }, named: "tag")
    let finalBytes = bytes
    state.withValue {
      $0.snapshot = .init(
        id: id, seq: seq, epoch: $0.epoch, createdAt: 0,
        entities: [
          .init(entity: "note", parts: noteParts), .init(entity: "unknown_entity", parts: []),
        ] + (tags.isEmpty ? [] : [.init(entity: "tag", parts: tagParts)]))
      $0.partBytes = finalBytes
    }
  }

  var downloader: SnapshotDownloader {
    SnapshotDownloader { [self] url in
      try state.withValue { state in
        state.downloads.append(url.absoluteString)
        if state.expiredURLs.contains(url.absoluteString) { throw SnapshotDownloader.Expired() }
        if state.interrupted.remove(url.absoluteString) != nil {
          throw URLError(.networkConnectionLost)
        }
        guard let data = state.partBytes[url.absoluteString] else {
          throw SnapshotDownloader.Failed(statusCode: 404)
        }
        return data
      }
    }
  }
  let pageSize = 2

  func append(_ change: (_ seq: Int) -> Components.Schemas.Change) {
    let seq = state.value.changes.count + 1
    let made = change(seq)
    state.withValue { $0.changes.append(made) }
  }

  var client: Client {
    .mock { [self] request, body in
      let path = request.path ?? ""
      if path == "/v1/sync/mutations" {
        let push = try JSONDecoder().decode(
          Components.Schemas.PushMutations.self,
          from: try await Data(collecting: try #require(body), upTo: 1 << 20))
        return try state.withValue { state in
          state.pushes.append(push.mutationId)
          if state.failingPushes {
            return try json(
              .serviceUnavailable,
              Components.Schemas.UserStoreUnavailable(
                _tag: .userStoreUnavailable, message: "Unavailable"))
          }
          if state.refusingPushes {
            return try json(
              .badRequest,
              Components.Schemas.MutationRejected(
                _tag: .mutationRejected, index: 0, message: "Invalid"))
          }
          if let seq = state.pushed[push.mutationId] {
            return try json(.ok, Components.Schemas.PushedMutations(seq: seq))
          }
          for mutation in push.mutations {
            let seq = state.changes.count + 1
            if let upsert = mutation.value1 {
              var row = upsert.row.value
              row["id"] = upsert.id
              state.changes.append(
                .init(
                  seq: seq, entity: upsert.entity, id: upsert.id, op: "upsert",
                  row: try OpenAPIObjectContainer(unvalidatedValue: row), at: 1_760_400_000_000))
            } else if let delete = mutation.value2 {
              state.changes.append(
                .init(
                  seq: seq, entity: delete.entity, id: delete.id, op: "delete",
                  at: 1_760_400_000_000))
            }
          }
          let seq = state.changes.count
          state.pushed[push.mutationId] = seq
          return try json(.ok, Components.Schemas.PushedMutations(seq: seq))
        }
      }
      if path.hasPrefix("/v1/sync/snapshot") {
        return try state.withValue { state in
          state.snapshotRequests += 1
          if path == "/v1/sync/snapshot" {
            defer {
              if let (snapshot, bytes) = state.replacingSnapshot {
                state.snapshot = snapshot
                state.partBytes.merge(bytes) { _, new in new }
                state.replacingSnapshot = nil
              }
            }
            return try json(
              .ok, Components.Schemas.LatestSnapshot(epoch: state.epoch, snapshot: state.snapshot))
          }
          guard var snapshot = state.snapshot, path.hasSuffix("/\(snapshot.id)") else {
            return try json(.gone, ["_tag": "SnapshotGone", "id": "x"])
          }
          // Fresh URLs for the same parts.
          var fresh: [String: Data] = [:]
          snapshot.entities = snapshot.entities.map { entity in
            var entity = entity
            entity.parts = entity.parts.map { part in
              var part = part
              let url = part.url + "&fresh"
              fresh[url] = state.partBytes[part.url]
              part.url = url
              return part
            }
            return entity
          }
          state.partBytes.merge(fresh) { _, new in new }
          return try json(.ok, snapshot)
        }
      }
      if state.value.hanging {
        state.withValue { $0.requests.append(-1) }
        try await Task.sleep(for: .seconds(3600))
      }
      let query = URLComponents(string: request.path ?? "")?.queryItems ?? []
      let after = Int(query.first { $0.name == "after" }?.value ?? "0") ?? 0
      let limit = Int(query.first { $0.name == "limit" }?.value ?? "1000") ?? 1000
      let filter = query.first { $0.name == "entities" }?.value
      return try state.withValue { state in
        state.requests.append(after)
        state.limits.append(limit)
        state.filters.append(filter)
        defer {
          for change in state.arriving.removeValue(forKey: state.requests.count) ?? [] {
            var change = change
            change.seq = state.changes.count + 1
            state.changes.append(change)
          }
        }
        if state.offline.contains(state.requests.count) {
          throw URLError(.notConnectedToInternet)
        }
        if state.failing.contains(state.requests.count) {
          return (HTTPResponse(status: .internalServerError), nil)
        }
        if state.rateLimited.contains(state.requests.count) {
          return try json(
            .tooManyRequests,
            Components.Schemas.TooManyRequests(_tag: .tooManyRequests, retryAfterSeconds: 30))
        }
        if after < state.horizon {
          return try json(.gone, ["_tag": "ChangesCompacted", "reason": "compacted"])
        }
        // As the server does: only the named entities' changes, and a page of them that isn't
        // full ends at the head.
        let only = state.ignoresEntities ? nil : filter.map { Set($0.split(separator: ",")) }
        let size = min(pageSize, limit)
        let page =
          state.stuck
          ? []
          : Array(
            state.changes.filter { $0.seq > after && only?.contains(Substring($0.entity)) != false }
              .prefix(size))
        let head = state.changes.last?.seq ?? 0
        let next =
          (only != nil && page.count < size ? max(head, after) : page.last?.seq ?? after)
          + (state.skipping ? 1 : 0)
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

private func upsert(_ id: String, _ title: String, entity: String = "note") -> (Int) ->
  Components.Schemas.Change
{
  { seq in
    Components.Schemas.Change(
      seq: seq, entity: entity, id: id, op: "upsert",
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

  private func engine(entities: [SyncEntity] = [notes], syncSchema: Int = 1) -> LilSyncEngine {
    withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.snapshotDownloader = server.downloader
      $0.continuousClock = RecordingClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(
        entities: entities, syncSchema: syncSchema,
        partsDirectory: URL.temporaryDirectory.appending(path: "lilsync-\(UUID().uuidString)"))
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
      delete: { _, _ in },
      clear: { _ in }
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
  func aNewEntityIsCaughtUpForWhatWasSkipped() async throws {
    server.append(upsert("n1", "One"))
    // An older release that didn't store notes moves its cursor past them.
    let older = engine(entities: [])
    try await older.bootstrap()
    try await older.pull()
    #expect(try storedNotes().isEmpty)

    // One that stores them catches them up by itself (851-3222), so the skipped note arrives.
    // The store has no snapshot, so they come from the log.
    let newer = engine()
    try await newer.pull()
    #expect(try storedNotes() == [Note(id: "n1", title: "One")])
    // Recorded, so it doesn't catch up again.
    server.append(upsert("n2", "Two"))
    try await newer.pull()
    #expect(try storedNotes().count == 2)
    #expect(server.state.snapshotRequests == 2)
  }

  @Test
  func aHigherSyncSchemaBootstrapsAgain() async throws {
    server.append(upsert("n1", "One"))
    let older = engine(syncSchema: 1)
    try await older.bootstrap()
    try await older.pull()

    // A release that stores a new field bumps the schema.
    let newer = engine(syncSchema: 2)
    await #expect(throws: SyncError.needsBootstrap) { try await newer.pull() }
    try await newer.bootstrap()
    try await newer.pull()

    // After a downgrade, the older release records its own schema, so coming back to the newer
    // one bootstraps again, for what the older one skipped meanwhile.
    try await older.pull()
    await #expect(throws: SyncError.needsBootstrap) { try await newer.pull() }
  }

  @Test
  func stateFromBeforeSyncSchemaCountsAsOne() async throws {
    server.append(upsert("n1", "One"))
    // The suite's database starts with a row from before syncSchema and entities were recorded.
    // Schema 1 and its current entities: it carries on.
    try await engine(syncSchema: 1).pull()
    #expect(try storedNotes().count == 1)
    // A higher schema starts over.
    await #expect(throws: SyncError.needsBootstrap) { try await engine(syncSchema: 2).pull() }
  }

  @Test
  func aSnapshotBootstrapRecordsTheSchema() async throws {
    server.append(upsert("n1", "One"))
    server.append(upsert("n2", "Two"))
    try server.publishSnapshot(
      seq: 2,
      notes: [
        Note(id: "n1", title: "One"), Note(id: "n2", title: "Two"),
      ])
    let engine = engine(syncSchema: 3)
    try await engine.bootstrap()
    // Recorded with the snapshot, so pulling carries on rather than bootstrapping again.
    server.append(upsert("n3", "Three"))
    try await engine.pull()
    #expect(try storedNotes().count == 3)
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

    let caughtUp = try makeDatabase(bootstrapped: false)
    try await caughtUp.write { db in
      try #sql("INSERT INTO lilSyncState (id, cursor, epoch) VALUES (1, 10, 1)").execute(db)
    }
    let engine = withDependencies {
      $0.defaultDatabase = caughtUp
      $0.api = server.client
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(entities: [notes], syncSchema: 1)
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

  // A hang would block the pre-commit hook: fail instead.
  @Test(.timeLimit(.minutes(1)))
  func aRateLimitIsWaitedOut() async throws {
    server.append(upsert("n1", "One"))
    server.state.withValue { $0.rateLimited = [1] }
    // Records each sleep rather than racing the engine to it with a `TestClock`: advancing one
    // before the engine sleeps would be missed. The first (the rate limit) returns at once; the
    // idle wait after the pull suspends, so the engine doesn't pull again.
    let clock = RecordingClock(immediateSleeps: 1)
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.continuousClock = clock
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(entities: [notes], syncSchema: 1)
    }
    let running = Task { await engine.run() }

    try await eventually { try storedNotes() == [Note(id: "n1", title: "One")] }
    try await eventually { clock.sleeps.value.count == 2 }
    running.cancel()
    await running.value
    // Not the usual 1 second after a first failure: the 30 the server asked for, then the pull.
    #expect(clock.sleeps.value.first == .seconds(30))
    #expect(server.state.requests.count == 2)
  }

  @Test
  func runRetriesWithBackoffAndReportsStatus() async throws {
    server.append(upsert("n1", "One"))
    server.state.withValue { $0.failing = [1, 2] }
    let clock = ManualClock()
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.continuousClock = clock
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(entities: [notes], syncSchema: 1)
    }
    let statuses = LockIsolated<[SyncStatus]>([])
    let updates = await engine.statusUpdates()
    let observing = Task {
      for await status in updates { statuses.withValue { $0.append(status) } }
    }
    let running = Task { await engine.run() }

    // Backoff is at most 1 second after the first failure and 2 after the second.
    let failed = SyncStatus.failed("unexpectedStatus(500)")
    try await clock.waitUntilAsleep(dueWithin: .seconds(1))
    #expect(server.state.requests.count == 1)
    try await eventually { statuses.value.last == failed }
    clock.advance(by: .seconds(1))
    try await clock.waitUntilAsleep(dueWithin: .seconds(2))
    #expect(server.state.requests.count == 2)
    // Failing the same way again is announced again, so whoever asked for the pull hears of it.
    try await eventually { statuses.value.filter { $0 == failed }.count == 2 }
    clock.advance(by: .seconds(2))
    try await eventually { try storedNotes() == [Note(id: "n1", title: "One")] }

    // An idle engine pulls again when asked, without waiting out the interval.
    server.append(upsert("n2", "Two"))
    await engine.syncNow()
    try await eventually { try storedNotes().count == 2 }

    // Cancelling ends the idle wait right away.
    running.cancel()
    await running.value
    try await eventually { statuses.value.last == .upToDate(at: syncedAt) }
    observing.cancel()
    #expect(statuses.value.first == .idle)
  }

  // A hang would block the pre-commit hook: fail instead.
  @Test(.timeLimit(.minutes(1)))
  func aPullWithoutAConnectionIsOfflineUntilOneWorks() async throws {
    server.append(upsert("n1", "One"))
    server.state.withValue { $0.offline = [1] }
    let clock = ManualClock()
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.continuousClock = clock
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(entities: [notes], syncSchema: 1)
    }
    let statuses = LockIsolated<[SyncStatus]>([])
    let updates = await engine.statusUpdates()
    let observing = Task {
      for await status in updates { statuses.withValue { $0.append(status) } }
    }
    let running = Task { await engine.run() }

    try await clock.waitUntilAsleep(dueWithin: .seconds(1))
    try await eventually { statuses.value.last == .offline }
    clock.advance(by: .seconds(1))
    try await eventually { statuses.value.last == .upToDate(at: syncedAt) }
    running.cancel()
    await running.value
    observing.cancel()
    // `.idle` first, unless the one-status buffer already replaced it.
    #expect(statuses.value.suffix(2) == [.offline, .upToDate(at: syncedAt)])
  }

  // A hang would block the pre-commit hook: fail instead.
  @Test(.timeLimit(.minutes(1)))
  func stoppingRunStopsItsPullAndLetsTheLocalDataGo() async throws {
    server.state.withValue { $0.hanging = true }
    let engine = engine()
    let running = Task { await engine.run() }
    try await eventually { server.state.requests.count == 1 }
    running.cancel()
    await running.value
    // Only returns once the hanging pull has stopped.
    try await engine.removeLocalData()
    #expect(try cursor() == nil)
  }

  @Test
  func cancellingRunEndsABackoffRightAway() async throws {
    server.state.withValue { $0.failing = [1] }
    let clock = ManualClock()
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.continuousClock = clock
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(entities: [notes], syncSchema: 1)
    }
    let running = Task { await engine.run() }
    // In the backoff, not still pulling.
    try await clock.waitUntilAsleep(dueWithin: .seconds(1))
    running.cancel()
    // The clock never advances, so this only returns because cancellation ends the wait.
    await running.value
  }
}

@Suite
struct LilSyncBootstrapTests {
  fileprivate let server = FakeServer()
  let partsDirectory = URL.temporaryDirectory.appending(path: "lilsync-\(UUID().uuidString)")

  private func engine(
    database: any DatabaseWriter, entities: [SyncEntity] = [stagedNotes]
  ) -> LilSyncEngine {
    withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.snapshotDownloader = server.downloader
      // Sleeps last until cancelled: `run()` idles after a pull rather than pulling in a loop.
      $0.continuousClock = ManualClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(entities: entities, syncSchema: 1, partsDirectory: partsDirectory)
    }
  }

  private func storedNotes(_ database: any DatabaseWriter) throws -> [Note] {
    try database.read { try Note.order(by: \.id).fetchAll($0) }
  }

  private func state(_ database: any DatabaseWriter) throws -> [Int?] {
    try database.read { db in
      let row = try #sql("SELECT cursor, epoch FROM lilSyncState", as: (Int, Int?).self).fetchOne(
        db)
      return [row?.0, row?.1 ?? nil]
    }
  }

  @Test
  func removingTheLocalDataStartsOverAsANewDevice() async throws {
    let all = [Note(id: "n1", title: "Synthetic note")]
    server.append(upsert("n1", "Synthetic note"))
    try server.publishSnapshot(seq: 1, notes: all)
    let path = URL.temporaryDirectory.appending(path: "lilsync-\(UUID().uuidString).sqlite")
      .path(percentEncoded: false)
    let database = try makeDatabase(bootstrapped: false, at: path)
    let engine = engine(database: database)
    try await engine.bootstrap()
    #expect(try storedNotes(database) == all)
    // A part left by an interrupted bootstrap.
    try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
    try Data("part".utf8).write(to: partsDirectory.appending(path: "left.ndjson.gz"))

    try await engine.removeLocalData()
    #expect(try storedNotes(database).isEmpty)
    #expect(try state(database) == [nil, nil])
    // Gone from the files too, not just unlinked.
    for file in [path, path + "-wal"] {
      let bytes = (try? Data(contentsOf: URL(filePath: file))) ?? Data()
      #expect(bytes.range(of: Data("Synthetic note".utf8)) == nil, "\(file)")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: partsDirectory.path()).isEmpty)
    await #expect(throws: SyncError.needsBootstrap) { try await engine.pull() }
  }

  @Test
  func aNewDeviceStartsFromTheSnapshotThenPullsTheChangesAfterIt() async throws {
    let notesAtSnapshot = ["a", "b", "c", "d", "e"].map { Note(id: $0, title: "Note \($0)") }
    for note in notesAtSnapshot { server.append(upsert(note.id, note.title)) }
    try server.publishSnapshot(seq: 5, notes: notesAtSnapshot)
    server.append(upsert("f", "Note f"))
    server.append(delete("a"))
    let database = try makeDatabase(bootstrapped: false)

    let engine = engine(database: database)
    await #expect(throws: SyncError.needsBootstrap) { try await engine.pull() }
    try await engine.bootstrap()
    #expect(try state(database) == [5, 1])
    try await engine.pull()

    #expect(try storedNotes(database).map(\.id) == ["b", "c", "d", "e", "f"])
    #expect(try state(database) == [7, 1])
    // The log before the snapshot was never pulled, and parts aren't kept after loading.
    #expect(server.state.requests == [5])
    #expect(server.state.downloads.count == 3)
    #expect(
      (try? FileManager.default.contentsOfDirectory(atPath: partsDirectory.path()))?.isEmpty ?? true
    )
  }

  @Test
  func anInterruptedBootstrapResumesWithoutDownloadingPartsAgain() async throws {
    let all = (1...6).map { Note(id: "n\($0)", title: "Note \($0)") }
    try server.publishSnapshot(seq: 6, notes: all)
    let urls = server.state.value.snapshot?.entities[0].parts.map(\.url) ?? []
    server.state.withValue { $0.interrupted = [urls[1]] }
    let database = try makeDatabase(bootstrapped: false)
    let engine = engine(database: database)

    await #expect(throws: URLError.self) { try await engine.bootstrap() }
    // Nothing was loaded: the local data and cursor change together, at the end.
    #expect(try storedNotes(database).isEmpty)
    #expect(try state(database) == [nil, nil])

    try await engine.bootstrap()
    #expect(try storedNotes(database).count == 6)
    // The first part came from disk the second time; parts download a few at a time, so in no
    // particular order.
    let downloads = server.state.downloads
    #expect(downloads.filter { $0 == urls[0] }.count == 1)
    #expect(downloads.filter { $0 == urls[1] }.count == 2)
    #expect(Set(downloads) == Set(urls))
  }

  @Test
  func expiredPartURLsAreRefreshedForTheSameSnapshot() async throws {
    let all = (1...4).map { Note(id: "n\($0)", title: "Note \($0)") }
    try server.publishSnapshot(seq: 4, notes: all)
    let urls = server.state.value.snapshot?.entities[0].parts.map(\.url) ?? []
    server.state.withValue { $0.expiredURLs = Set(urls) }
    let database = try makeDatabase(bootstrapped: false)

    try await engine(database: database).bootstrap()
    #expect(try storedNotes(database).count == 4)
    // Parts downloading together share one refresh, and each part is tried again once.
    let downloads = server.state.value.downloads
    #expect(downloads.count == urls.count * 2)
    #expect(Set(downloads) == Set(urls + urls.map { $0 + "&fresh" }))
    #expect(server.state.value.snapshotRequests == 2)
  }

  @Test
  func skipsSnapshotRecordsItCannotRead() async throws {
    try server.publishSnapshot(seq: 0, notes: [Note(id: "a", title: "A")])
    // Swap in a part with a record whose title isn't a string, and one that's fine.
    let gzip = try Gzip.compress(Data(#"{"id":"x","title":7}\#n{"id":"b","title":"B"}"#.utf8))
    server.state.withValue { state in
      guard var snapshot = state.snapshot else { return }
      let url = "https://api.test/v1/sync/parts?token=odd"
      let sha = SHA256.hash(data: gzip).map { String(format: "%02x", $0) }.joined()
      snapshot.entities[0].parts = [.init(url: url, records: 2, bytes: gzip.count, sha256: sha)]
      state.snapshot = snapshot
      state.partBytes = [url: gzip]
    }
    let database = try makeDatabase(bootstrapped: false)
    let engine = engine(database: database)
    try await withKnownIssue {
      try await engine.bootstrap()
    } matching: {
      $0.description.contains("Skipped a note record")
    }
    #expect(try storedNotes(database).map(\.id) == ["b"])
  }

  @Test
  func downloadsADamagedCachedPartAgain() async throws {
    try server.publishSnapshot(seq: 0, notes: [Note(id: "a", title: "A")])
    let part = try #require(server.state.value.snapshot?.entities[0].parts[0])
    try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
    try Data("damaged".utf8).write(to: partsDirectory.appending(path: "\(part.sha256).ndjson.gz"))
    let database = try makeDatabase(bootstrapped: false)
    try await engine(database: database).bootstrap()
    #expect(try storedNotes(database).map(\.id) == ["a"])
    #expect(server.state.value.downloads == [part.url])
  }

  @Test
  func removesPartsLeftByAnOlderBootstrap() async throws {
    try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
    let stale = partsDirectory.appending(path: "0123.ndjson.gz")
    try Data("old".utf8).write(to: stale)
    try server.publishSnapshot(seq: 0, notes: [Note(id: "a", title: "A")])
    try await engine(database: try makeDatabase(bootstrapped: false)).bootstrap()
    #expect(!FileManager.default.fileExists(atPath: stale.path()))
  }

  @Test
  func aCorruptPartIsntLoaded() async throws {
    try server.publishSnapshot(
      seq: 2, notes: [Note(id: "a", title: "A"), Note(id: "b", title: "B")])
    server.state.withValue { state in
      for key in state.partBytes.keys { state.partBytes[key] = try! Gzip.compress(Data("{}".utf8)) }
    }
    let database = try makeDatabase(bootstrapped: false)
    await #expect(throws: SyncError.corruptPart) {
      try await engine(database: database).bootstrap()
    }
    #expect(try storedNotes(database).isEmpty)
  }

  @Test
  func aNewEpochReplacesTheLocalData() async throws {
    server.append(upsert("old", "From epoch 1"))
    let database = try makeDatabase(bootstrapped: false)
    let engine = engine(database: database)
    // No snapshot yet: the whole log is pulled.
    try await engine.bootstrap()
    try await engine.pull()
    #expect(try storedNotes(database).map(\.id) == ["old"])

    server.state.withValue { $0.epoch = 2 }
    try server.publishSnapshot(id: "snp_2", seq: 1, notes: [Note(id: "new", title: "From epoch 2")])
    await #expect(throws: SyncError.needsBootstrap) { try await engine.pull() }
    try await engine.bootstrap()
    #expect(try storedNotes(database).map(\.id) == ["new"])
    #expect(try state(database) == [1, 2])
  }

  @Test
  func aBootstrapReplacesTheLocalDataAndKeepsTheIndexes() async throws {
    let database = try makeDatabase()
    try await database.write { db in
      try Note.insert { [Note(id: "a", title: "Old a"), Note(id: "z", title: "Gone")] }
        .execute(db)
    }
    let before = try schema(database)
    try server.publishSnapshot(
      seq: 3,
      notes: [Note(id: "c", title: "C"), Note(id: "a", title: "A"), Note(id: "b", title: "B")])

    try await engine(database: database).bootstrap()
    #expect(
      try storedNotes(database) == [
        Note(id: "a", title: "A"), Note(id: "b", title: "B"), Note(id: "c", title: "C"),
      ])
    #expect(try state(database) == [3, 1])
    #expect(try schema(database) == before)
    #expect(try temporaryTables(database).isEmpty)
    // The indexes hold every row.
    #expect(
      try await database.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") } == ["ok"])
  }

  @Test
  func aRecordInTheSnapshotTwiceIsStoredOnceAsItWasLast() async throws {
    try server.publishSnapshot(
      seq: 3,
      notes: [
        Note(id: "a", title: "First"), Note(id: "b", title: "B"), Note(id: "a", title: "Last"),
      ])
    let database = try makeDatabase(bootstrapped: false)
    try await engine(database: database).bootstrap()
    #expect(
      try storedNotes(database) == [Note(id: "a", title: "Last"), Note(id: "b", title: "B")])
  }

  @Test
  func aBootstrapInterruptedWhileStagingKeepsTheIndexesAndStartsOver() async throws {
    struct Interrupted: Error {}
    let interrupting = LockIsolated(true)
    let notes = makeStagedNotes { row, staging, db in
      // In the third part, after two parts were staged.
      if row.id == "n5", interrupting.value { throw Interrupted() }
      try stage(row, in: staging, db)
    }
    let all = (1...6).map { Note(id: "n\($0)", title: "Note \($0)") }
    try server.publishSnapshot(seq: 6, notes: all)
    let database = try makeDatabase()
    try await database.write { db in
      try Note.insert { Note(id: "n1", title: "Old") }.execute(db)
    }
    let before = try schema(database)
    let engine = engine(database: database, entities: [notes])

    await #expect(throws: Interrupted.self) { try await engine.bootstrap() }
    #expect(try storedNotes(database).isEmpty)
    #expect(try state(database) == [nil, nil])
    #expect(try schema(database) == before)
    #expect(try temporaryTables(database).isEmpty)

    interrupting.setValue(false)
    try await engine.bootstrap()
    #expect(try storedNotes(database) == all)
    #expect(try schema(database) == before)
    #expect(try temporaryTables(database).isEmpty)
  }

  @Test
  func aBootstrapThatCantStoreAStagedRecordRollsBackWithTheIndexes() async throws {
    // Staging tables have no constraints, so a record the table refuses fails at the end, when
    // the staged records move into it: here, one without a title.
    let notes = makeStagedNotes { row, staging, db in
      try stage(row, title: row.id == "b" ? .some(nil) : nil, in: staging, db)
    }
    try server.publishSnapshot(
      seq: 2, notes: [Note(id: "a", title: "A"), Note(id: "b", title: "B")])
    let database = try makeDatabase()
    let before = try schema(database)

    await #expect(throws: DatabaseError.self) {
      try await engine(database: database, entities: [notes]).bootstrap()
    }
    #expect(try storedNotes(database).isEmpty)
    #expect(try state(database) == [nil, nil])
    #expect(try schema(database) == before)
    #expect(try temporaryTables(database).isEmpty)
  }

  @Test
  func anEntityWithoutATableLoadsStraightIntoIt() async throws {
    let all = (1...3).map { Note(id: "n\($0)", title: "Note \($0)") }
    try server.publishSnapshot(seq: 3, notes: all)
    let database = try makeDatabase(bootstrapped: false)
    try await engine(database: database, entities: [notes]).bootstrap()
    #expect(try storedNotes(database) == all)
    #expect(try temporaryTables(database).isEmpty)
  }

  @Test
  func signingOutDropsStagingTablesLeftBehind() async throws {
    let database = try makeDatabase()
    try await database.write { db in
      try db.execute(sql: #"CREATE TEMP TABLE "lilSyncStaging_note" ("id", "title")"#)
      try db.execute(sql: #"INSERT INTO "lilSyncStaging_note" VALUES ('a', 'Synthetic')"#)
    }
    try await engine(database: database).removeLocalData()
    #expect(try temporaryTables(database).isEmpty)
  }

  @Test
  func runBootstrapsANewDeviceAndReportsProgress() async throws {
    let all = (1...4).map { Note(id: "n\($0)", title: "\($0)") }
    for note in all { server.append(upsert(note.id, note.title)) }
    try server.publishSnapshot(seq: 4, notes: all)
    let database = try makeDatabase(bootstrapped: false)
    let engine = engine(database: database)
    let statuses = LockIsolated<[SyncStatus]>([])
    let updates = await engine.statusUpdates(bufferingPolicy: .unbounded)
    let observing = Task {
      for await status in updates { statuses.withValue { $0.append(status) } }
    }
    let running = Task { await engine.run() }
    try await eventually { try storedNotes(database).count == 4 }
    try await eventually { statuses.value.last == .upToDate(at: syncedAt) }
    running.cancel()
    await running.value
    observing.cancel()
    // Each status as it was set, so none is missed.
    #expect(statuses.value.contains(.bootstrapping(.finishing(4))))
  }

  @Test
  func aBootstrapCountsRecordsDownloadedThenLoadedThenFinishes() async throws {
    // Parts of 2, 2 and 1 records (851-2946).
    let all = (1...5).map { Note(id: "n\($0)", title: "\($0)") }
    try server.publishSnapshot(seq: 5, notes: all)
    let database = try makeDatabase(bootstrapped: false)
    let engine = engine(database: database)
    let statuses = LockIsolated<[SyncStatus]>([])
    let updates = await engine.statusUpdates(bufferingPolicy: .unbounded)
    let observing = Task {
      for await status in updates { statuses.withValue { $0.append(status) } }
    }
    try await engine.bootstrap()
    try await eventually { statuses.value.last == .bootstrapping(.finishing(5)) }
    observing.cancel()

    let progress = statuses.value.compactMap { status -> BootstrapProgress? in
      if case .bootstrapping(let progress) = status { progress } else { nil }
    }
    // Parts download four at a time, so they're counted in the order they finish.
    let downloads = progress.filter { $0.stage == .downloading }
    #expect(downloads.prefix(2) == [.downloading(0, of: 0), .downloading(0, of: 5)])
    #expect(downloads.last == .downloading(5, of: 5))
    #expect(downloads.count == 5)
    let counted = downloads.dropFirst()
    #expect(zip(counted, counted.dropFirst()).allSatisfy { $0.records < $1.records })
    // Then loaded in order, from the top, and finished.
    #expect(
      progress.drop { $0.stage == .downloading } == [
        .loading(0, of: 5), .loading(2, of: 5), .loading(4, of: 5), .loading(5, of: 5),
        .finishing(5),
      ])
    #expect(try storedNotes(database) == all)
  }

  @Test
  func bootstrapProgressCountsRecordsLeft() {
    #expect(BootstrapProgress.downloading(0, of: 0).recordsLeft == 0)
    #expect(BootstrapProgress.downloading(25_000, of: 1_000_000).recordsLeft == 975_000)
    #expect(BootstrapProgress.loading(1_000_000, of: 1_000_000).recordsLeft == 0)
    // A part with more records than its manifest said.
    #expect(BootstrapProgress.loading(1_000_001, of: 1_000_000).recordsLeft == 0)
    #expect(BootstrapProgress.finishing(1_000_000).recordsLeft == 0)
  }
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

@Suite
struct GzipTests {
  @Test
  func readsFilesFromTheSystemGzip() throws {
    // `gzip` writes a header with the file's name, which snapshot parts don't have.
    let directory = URL.temporaryDirectory.appending(path: "gzip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "records.ndjson")
    let text = (1...500).map { #"{"id":"n\#($0)","title":"Note \#($0)"}"# }.joined(separator: "\n")
    try Data(text.utf8).write(to: file)
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/gzip")
    process.arguments = ["-N", file.path()]
    try process.run()
    process.waitUntilExit()

    let compressed = try Data(contentsOf: directory.appending(path: "records.ndjson.gz"))
    #expect(try Gzip.decompress(compressed) == Data(text.utf8))
    #expect(try Gzip.decompress(Gzip.compress(Data(text.utf8))) == Data(text.utf8))
  }

  @Test
  func rejectsDamagedFiles() throws {
    var compressed = try Gzip.compress(Data("hello".utf8))
    // The size in the trailer. (Its CRC isn't checked: parts are checked with SHA-256.)
    compressed[compressed.count - 1] ^= 0xff
    #expect(throws: Gzip.InvalidData.self) { try Gzip.decompress(compressed) }
    #expect(throws: Gzip.InvalidData.self) { try Gzip.decompress(Data("plain".utf8)) }
  }
}

/// Live connections the test drives: each `connect` hands the test a continuation to send
/// messages through, or to close with.
private final class FakeLive: Sendable {
  let connections = LockIsolated<[AsyncThrowingStream<String, any Error>.Continuation]>([])
  let tokens = LockIsolated<[String]>([])

  var connection: LiveConnection {
    LiveConnection { [self] token in
      tokens.withValue { $0.append(token) }
      let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
      connections.withValue { $0.append(continuation) }
      return stream
    }
  }

  func latest() -> AsyncThrowingStream<String, any Error>.Continuation? {
    connections.value.last
  }
}

@Suite
struct LilSyncLiveTests {
  fileprivate let server = FakeServer()
  fileprivate let live = FakeLive()
  let database: any DatabaseWriter
  fileprivate let clock = ManualClock()

  init() throws {
    database = try makeDatabase()
  }

  private func engine() -> LilSyncEngine {
    withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.liveConnection = live.connection
      $0.continuousClock = clock
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(entities: [notes], syncSchema: 1)
    }
  }

  private func storedNotes() throws -> [Note] {
    try database.read { try Note.order(by: \.id).fetchAll($0) }
  }

  @Test
  func aNoticeOfNewChangesPullsRightAway() async throws {
    let engine = engine()
    let running = Task { await engine.run() }
    let listening = Task {
      await engine.listen(
        authentication: APIAuthentication(accessToken: { "token-1" }, rejected: { _ in }))
    }
    try await eventually { live.connections.value.count == 1 }
    try await eventually { server.state.requests.count == 1 }

    // The greeting matches the local cursor, and other messages aren't notices: no pulls.
    live.latest()?.yield(#"{"type":"head","seq":0}"#)
    live.latest()?.yield(#"{"type":"something-new"}"#)
    live.latest()?.yield("not json")
    // A notice of a newer head pulls without waiting out the idle interval.
    server.append(upsert("n1", "One"))
    live.latest()?.yield(#"{"type":"head","seq":1}"#)
    try await eventually { try storedNotes().map(\.id) == ["n1"] }
    #expect(server.state.requests == [0, 0])

    listening.cancel()
    running.cancel()
    live.latest()?.finish()
    await listening.value
    await running.value
  }

  @Test
  func liveNoticesDontCutAFailuresBackoffShort() async throws {
    server.state.withValue { $0.failing = [1] }
    let engine = engine()
    let running = Task { await engine.run() }
    try await clock.waitUntilAsleep(dueWithin: .seconds(1))
    await engine.syncNow()
    // Time for the engine to act on it, if it wrongly would.
    try await Task.sleep(for: .milliseconds(50))
    #expect(server.state.requests.count == 1)
    #expect(clock.isAsleep(dueWithin: .seconds(1)))
    clock.advance(by: .seconds(1))
    try await eventually { server.state.requests.count == 2 }
    running.cancel()
    await running.value
  }

  @Test
  func aTokenTheServerNoLongerAcceptsIsRejectedSoTheNextOneIsRefreshed() async throws {
    let engine = engine()
    let rejected = LockIsolated<[String]>([])
    let listening = Task {
      await engine.listen(
        authentication: APIAuthentication(
          accessToken: { "token-1" },
          rejected: { token in rejected.withValue { $0.append(token) } }
        )
      )
    }
    try await eventually { live.connections.value.count == 1 }
    // E.g. the account was deleted: the server closes with 4001 at once.
    live.latest()?.finish(throwing: LiveConnection.TokenExpired())
    try await eventually { rejected.value == ["token-1"] }
    // Anything else isn't the token's fault.
    try await clock.waitUntilAsleep(dueWithin: .seconds(1))
    clock.advance(by: .seconds(1))
    try await eventually { live.connections.value.count == 2 }
    live.latest()?.finish(throwing: LiveConnection.Closed(code: 1011))
    try await clock.waitUntilAsleep(dueWithin: .seconds(4))
    #expect(rejected.value == ["token-1"])

    listening.cancel()
    await listening.value
  }

  @Test
  func reconnectsRightAwayWithAFreshTokenWhenAWorkingConnectionsTokenExpires() async throws {
    let engine = engine()
    let issued = LockIsolated(0)
    let listening = Task {
      await engine.listen(
        authentication: APIAuthentication(
          accessToken: {
            issued.withValue { $0 += 1 }
            return "token-\(issued.value)"
          },
          rejected: { _ in }
        )
      )
    }
    try await eventually { live.connections.value.count == 1 }
    // Lasts long enough to count as working.
    try await clock.waitUntilAsleep(dueWithin: .seconds(60))
    clock.advance(by: .seconds(60))
    live.latest()?.finish(throwing: LiveConnection.TokenExpired())
    try await eventually { live.connections.value.count == 2 }
    #expect(live.tokens.value == ["token-1", "token-2"])

    // A token that expires right away (e.g. a skewed clock) backs off instead of looping.
    live.latest()?.yield(#"{"type":"head","seq":0}"#)
    live.latest()?.finish(throwing: LiveConnection.TokenExpired())
    try await clock.waitUntilAsleep(dueWithin: .seconds(1))
    #expect(live.connections.value.count == 2)
    clock.advance(by: .seconds(1))
    try await eventually { live.connections.value.count == 3 }

    listening.cancel()
    live.latest()?.finish()
    await listening.value
  }

  @Test
  func reconnectsWithGrowingBackoffEvenIfEachConnectionWasGreeted() async throws {
    let engine = engine()
    let listening = Task {
      await engine.listen(
        authentication: APIAuthentication(accessToken: { "token" }, rejected: { _ in }))
    }
    try await eventually { live.connections.value.count == 1 }
    live.latest()?.yield(#"{"type":"head","seq":0}"#)
    live.latest()?.finish(throwing: URLError(.networkConnectionLost))
    // It waits (at most a second after the first failure) before reconnecting.
    try await clock.waitUntilAsleep(dueWithin: .seconds(1))
    #expect(live.connections.value.count == 1)
    clock.advance(by: .seconds(1))
    try await eventually { live.connections.value.count == 2 }

    // A second drop backs off longer, greeting or not.
    live.latest()?.yield(#"{"type":"head","seq":0}"#)
    live.latest()?.finish(throwing: URLError(.networkConnectionLost))
    // Between 1 and 2 seconds, with jitter.
    try await clock.waitUntilAsleep(dueWithin: .seconds(2))
    #expect(!clock.isAsleep(dueWithin: .seconds(0.99)))
    clock.advance(by: .seconds(0.9))
    try await Task.sleep(for: .milliseconds(50))
    #expect(live.connections.value.count == 2)
    clock.advance(by: .seconds(1.2))
    try await eventually { live.connections.value.count == 3 }

    listening.cancel()
    live.latest()?.finish()
    await listening.value
  }

  @Test
  func stopsWhenCancelled() async throws {
    let engine = engine()
    let listening = Task {
      await engine.listen(
        authentication: APIAuthentication(accessToken: { "token" }, rejected: { _ in }))
    }
    try await eventually { live.connections.value.count == 1 }
    listening.cancel()
    live.latest()?.finish()
    await listening.value
    #expect(live.connections.value.count == 1)
  }
}

@Suite
struct LilSyncPushTests {
  fileprivate let server = FakeServer()
  let database: any DatabaseWriter

  init() throws {
    database = try makeDatabase()
  }

  private func engine() -> LilSyncEngine {
    withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.snapshotDownloader = server.downloader
      $0.continuousClock = RecordingClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(
        entities: [stagedNotes], syncSchema: 1,
        partsDirectory: URL.temporaryDirectory.appending(path: "lilsync-\(UUID().uuidString)"))
    }
  }

  private func mine(_ id: String = "p", _ title: String = "Mine") -> SyncMutation {
    .upsert("note", id: id, row: try! OpenAPIObjectContainer(unvalidatedValue: ["title": title]))
  }

  private func storedNotes() throws -> [Note] {
    try database.read { db in try Note.order(by: \.id).fetchAll(db) }
  }

  private func pending() throws -> [PendingMutation] {
    try database.read { db in try PendingMutation.fetchAll(db) }
  }

  @Test
  func aPushIsWrittenAtOnceAndSentBeforeTheNextPull() async throws {
    let engine = engine()
    try await engine.push([mine()])
    #expect(try storedNotes() == [Note(id: "p", title: "Mine")])
    #expect(try pending().map(\.seq) == [nil])

    try await engine.pull()
    #expect(server.state.value.pushes.count == 1)
    #expect(try storedNotes() == [Note(id: "p", title: "Mine")])
    // The cursor passed the push's change, so it's done.
    #expect(try pending().isEmpty)
  }

  @Test
  func pulledChangesDontUndoAPushUntilTheCursorPassesIt() async throws {
    server.append(upsert("p", "Theirs"))
    server.append(upsert("q", "Other"))
    server.append(upsert("r", "Other"))
    let engine = engine()
    try await engine.push([mine()])
    // The push becomes change 4; the pull stops after the first page (changes 1 and 2).
    server.state.withValue { $0.failing = [2] }
    await #expect(throws: (any Error).self) { try await engine.pull() }
    #expect(try storedNotes().first { $0.id == "p" }?.title == "Mine")
    #expect(try pending().map(\.seq) == [4])

    server.state.withValue { $0.failing = [] }
    try await engine.pull()
    #expect(try storedNotes().first { $0.id == "p" }?.title == "Mine")
    #expect(try pending().isEmpty)
    // Sent once: the second pull didn't push it again.
    #expect(server.state.value.pushes.count == 1)
  }

  @Test
  func aPushTheServerRefusesIsDroppedAndTheDataStartsOver() async throws {
    server.state.withValue { $0.refusingPushes = true }
    let engine = engine()
    await withKnownIssue {
      try await engine.push([mine()])
      await #expect(throws: SyncError.needsBootstrap) { try await engine.pull() }
    }
    #expect(try pending().isEmpty)
    try await engine.bootstrap()
    #expect(try storedNotes().isEmpty)
  }

  @Test
  func aPushThatKeepsFailingDoesntStopPulls() async throws {
    server.append(upsert("a", "Note a"))
    server.state.withValue { $0.failingPushes = true }
    let engine = engine()
    try await engine.push([mine()])
    await #expect(throws: SyncError.unavailable) { try await engine.pull() }
    // Pulled anyway, with the unsent write still over it, and still queued.
    #expect(try storedNotes() == [Note(id: "a", title: "Note a"), Note(id: "p", title: "Mine")])
    #expect(try pending().map(\.seq) == [nil])
  }

  @Test
  func unsentWritesSurviveABootstrap() async throws {
    try server.publishSnapshot(
      seq: 0, notes: [Note(id: "a", title: "Note a"), Note(id: "q", title: "Theirs")])
    let engine = engine()
    try await engine.push([mine(), mine("q")])
    try await engine.bootstrap()
    #expect(
      try storedNotes() == [
        Note(id: "a", title: "Note a"), Note(id: "p", title: "Mine"), Note(id: "q", title: "Mine"),
      ])
    #expect(try pending().count == 1)
  }

  @Test
  func signingOutDropsUnsentWrites() async throws {
    let engine = engine()
    try await engine.push([mine()])
    try await engine.removeLocalData()
    #expect(try pending().isEmpty)
    #expect(try storedNotes().isEmpty)
  }
}

/// A client upgrades to a release that stores a new entity, tags, and catches it up alone
/// (851-3222): its records from the latest snapshot, then its changes after the snapshot up to
/// the cursor, without bootstrapping the entities it already had.
@Suite
struct LilSyncCatchUpTests {
  fileprivate let server = FakeServer()
  let database: any DatabaseWriter
  let partsDirectory = URL.temporaryDirectory.appending(path: "lilsync-\(UUID().uuidString)")

  init() throws {
    database = try makeDatabase(bootstrapped: false)
  }

  private func engine(
    entities: [SyncEntity] = [stagedNotes, tags], syncSchema: Int = 1
  ) -> LilSyncEngine {
    withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.snapshotDownloader = server.downloader
      $0.continuousClock = RecordingClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(entities: entities, syncSchema: syncSchema, partsDirectory: partsDirectory)
    }
  }

  /// The release before tags.
  private var older: LilSyncEngine { engine(entities: [stagedNotes]) }

  private func storedNotes() throws -> [Note] {
    try database.read { try Note.order(by: \.id).fetchAll($0) }
  }

  private func storedTags() throws -> [Tag] {
    try database.read { try Tag.order(by: \.id).fetchAll($0) }
  }

  private func state() throws -> SyncState? {
    try database.read { try SyncState.find(SyncState.singletonID).fetchOne($0) }
  }

  private func tag(_ id: String, _ title: String) -> (Int) -> Components.Schemas.Change {
    upsert(id, title, entity: "tag")
  }

  /// Changes 1 to 4, a snapshot of them at 4, then changes 5 to 8, which the older release
  /// pulled: its cursor is at 8, holding only notes.
  private func olderReleaseSyncedTo8() async throws {
    server.append(upsert("n1", "Note 1"))
    server.append(tag("t1", "Tag 1"))
    server.append(upsert("n2", "Note 2"))
    server.append(tag("t2", "Tag 2"))
    try server.publishSnapshot(
      seq: 4, notes: [Note(id: "n1", title: "Note 1"), Note(id: "n2", title: "Note 2")],
      tags: [Tag(id: "t1", title: "Tag 1"), Tag(id: "t2", title: "Tag 2")])
    server.append(tag("t1", "Tag 1, renamed"))
    server.append(upsert("n3", "Note 3"))
    server.append(delete("t2", entity: "tag"))
    server.append(tag("t3", "Tag 3"))
    let older = older
    try await older.bootstrap()
    try await older.pull()
    #expect(try state()?.cursor == 8)
    #expect(try state()?.entities == "note")
    #expect(try storedTags().isEmpty)
    server.state.withValue {
      $0.requests = []
      $0.limits = []
      $0.filters = []
      $0.downloads = []
      $0.snapshotRequests = 0
    }
  }

  private var notesAt8: [Note] {
    [
      Note(id: "n1", title: "Note 1"), Note(id: "n2", title: "Note 2"),
      Note(id: "n3", title: "Note 3"),
    ]
  }

  private var tagsAt8: [Tag] {
    [Tag(id: "t1", title: "Tag 1, renamed"), Tag(id: "t3", title: "Tag 3")]
  }

  private var tagParts: [String] {
    server.state.value.snapshot?.entities.first { $0.entity == "tag" }?.parts.map(\.url) ?? []
  }

  @Test
  func aNewEntityIsCaughtUpWithoutBootstrappingAgain() async throws {
    try await olderReleaseSyncedTo8()
    server.append(tag("t4", "Tag 4"))
    server.append(upsert("n4", "Note 4"))

    try await engine().pull()

    #expect(try storedTags() == tagsAt8 + [Tag(id: "t4", title: "Tag 4")])
    #expect(try storedNotes() == notesAt8 + [Note(id: "n4", title: "Note 4")])
    // Only the tags' parts were downloaded, then the tags' changes from the snapshot to the
    // cursor (5 and 7, then 8), never past it, then the pull carried on from the cursor.
    #expect(server.state.downloads.sorted() == tagParts.sorted())
    #expect(server.state.requests == [4, 7, 8])
    #expect(server.state.limits == [4, 1, LilSyncEngine.pageSize])
    #expect(server.state.filters == ["tag", "tag", nil])
    let state = try #require(try state())
    #expect(state.cursor == 10)
    #expect(state.entities == "note,tag")
    #expect(state.catchUpEntities == nil)
    #expect(try temporaryTables(database).isEmpty)

    // Caught up for good: the next pull asks for no snapshot.
    try await engine().pull()
    #expect(server.state.snapshotRequests == 1)
  }

  @Test
  func aServerWithoutTheEntitiesFilterSendsEveryChangeAndTheCatchUpSkipsTheRest() async throws {
    try await olderReleaseSyncedTo8()
    server.state.withValue { $0.ignoresEntities = true }

    try await engine().pull()

    #expect(try storedTags() == tagsAt8)
    #expect(try storedNotes() == notesAt8)
    // Pages without gaps, of every entity, as before 851-3221.
    #expect(server.state.requests == [4, 6, 8])
    #expect(server.state.limits == [4, 2, LilSyncEngine.pageSize])
    #expect(try state()?.entities == "note,tag")
  }

  @Test
  func aFilteredPageThatIsntFullEndsTheCatchUpAtTheCursor() async throws {
    // A tag among notes: the cursor is at 5, and a note arrives at 6.
    server.append(upsert("n1", "Note 1"))
    server.append(tag("t1", "Tag 1"))
    for n in 2...4 { server.append(upsert("n\(n)", "Note \(n)")) }
    let older = older
    try await older.bootstrap()
    try await older.pull()
    server.append(upsert("n5", "Note 5"))
    server.state.withValue {
      $0.requests = []
      $0.filters = []
    }

    try await engine().pull()

    #expect(try storedTags() == [Tag(id: "t1", title: "Tag 1")])
    #expect(try storedNotes().map(\.id) == ["n1", "n2", "n3", "n4", "n5"])
    // The tags' one page skipped to the head, 6, past the cursor, 5: the catch-up stopped there,
    // and the pull went on from 5.
    #expect(server.state.requests == [0, 5])
    #expect(server.state.filters == ["tag", nil])
    #expect(try state()?.cursor == 6)
  }

  @Test
  func refusesAFilteredPageThatMakesNoProgress() async throws {
    try await olderReleaseSyncedTo8()
    server.state.withValue { $0.stuck = true }
    await #expect(throws: SyncError.unexpectedPage) { try await engine().pull() }
    #expect(server.state.filters == ["tag"])
    #expect(try state()?.entities == "note")
  }

  @Test
  func refusesAFilteredPageWhoseNextSkipsAChange() async throws {
    try await olderReleaseSyncedTo8()
    server.append(tag("t4", "Tag 4"))
    server.append(upsert("n4", "Note 4"))
    // The first page, 5 and 7, says to go on after 8, skipping it.
    server.state.withValue { $0.skipping = true }
    await #expect(throws: SyncError.unexpectedPage) { try await engine().pull() }
    // The snapshot's tags were loaded, but none of the page's changes, and the catch-up didn't
    // move past them.
    #expect(try storedTags() == [Tag(id: "t1", title: "Tag 1"), Tag(id: "t2", title: "Tag 2")])
    let state = try #require(try state())
    #expect([state.catchUpAfter, state.cursor] == [4, 8])
    #expect(state.entities == "note")
  }

  @Test
  func theCatchUpsProgressShows() async throws {
    try await olderReleaseSyncedTo8()
    let engine = engine()
    let statuses = LockIsolated<[SyncStatus]>([])
    let updates = await engine.statusUpdates(bufferingPolicy: .unbounded)
    let observing = Task {
      for await status in updates { statuses.withValue { $0.append(status) } }
    }
    try await engine.pull()
    try await eventually { statuses.value.last == .upToDate(at: syncedAt) }
    observing.cancel()
    #expect(statuses.value.contains(.bootstrapping(.finishing(2))))
    #expect(
      statuses.value.drop { $0 != .syncing(cursor: 4, head: 8) } == [
        .syncing(cursor: 4, head: 8), .syncing(cursor: 7, head: 8), .upToDate(at: syncedAt),
      ])
  }

  @Test
  func aCatchUpInterruptedWhileLoadingTheSnapshotStartsOverWithoutDownloadingAgain() async throws {
    try await olderReleaseSyncedTo8()
    // Tags in two parts.
    try server.publishSnapshot(
      seq: 4, notes: [Note(id: "n1", title: "Note 1")],
      tags: [1, 2, 3].map { Tag(id: "s\($0)", title: "Snapshot \($0)") })
    let threeParts = tagParts
    server.state.withValue { $0.interrupted = [threeParts[1]] }
    let engine = engine()

    await #expect(throws: URLError.self) { try await engine.pull() }
    // Nothing changed: the tags aren't held yet, and the notes and cursor are as they were.
    #expect(try storedTags().isEmpty)
    #expect(try storedNotes() == notesAt8)
    #expect(try state()?.entities == "note")
    #expect(try state()?.catchUpEntities == nil)

    try await engine.pull()
    #expect(
      try storedTags() == [
        Tag(id: "s1", title: "Snapshot 1"), Tag(id: "s2", title: "Snapshot 2"),
        Tag(id: "s3", title: "Snapshot 3"), Tag(id: "t1", title: "Tag 1, renamed"),
        Tag(id: "t3", title: "Tag 3"),
      ])
    #expect(try storedNotes() == notesAt8)
    // The part that downloaded the first time came from disk the second time.
    let downloads = server.state.downloads
    #expect(downloads.filter { $0 == threeParts[0] }.count == 1)
    #expect(downloads.filter { $0 == threeParts[1] }.count == 2)
    #expect(try state()?.entities == "note,tag")
  }

  @Test
  func aCatchUpInterruptedWhilePullingResumesWhereItStopped() async throws {
    try await olderReleaseSyncedTo8()
    // The second page of the catch-up fails.
    server.state.withValue { $0.failing = [2] }
    let engine = engine()

    await #expect(throws: SyncError.unexpectedStatus(500)) { try await engine.pull() }
    // The snapshot and the first page (changes 5 and 7) are kept, with how far the catch-up got.
    #expect(try storedTags() == [Tag(id: "t1", title: "Tag 1, renamed")])
    var state = try #require(try state())
    #expect(state.cursor == 8)
    #expect(state.entities == "note")
    #expect([state.catchUpAfter, state.catchUpUntil] == [7, 8])
    #expect(state.catchUpEntities == "tag")

    server.state.withValue { $0.failing = [] }
    try await engine.pull()
    #expect(try storedTags() == tagsAt8)
    #expect(try storedNotes() == notesAt8)
    // Resumed after 7, without the snapshot again.
    #expect(server.state.requests == [4, 7, 7, 8])
    #expect(server.state.snapshotRequests == 1)
    #expect(server.state.downloads.count == tagParts.count)
    state = try #require(try self.state())
    #expect(state.entities == "note,tag")
    #expect(state.catchUpAfter == nil)
  }

  @Test
  func changesWrittenDuringTheCatchUpArriveWithThePullAfterIt() async throws {
    try await olderReleaseSyncedTo8()
    // While the catch-up asks for its first page: t1 changes again, t3 goes and a note comes.
    server.state.withValue {
      $0.arriving[1] = [
        tag("t1", "Tag 1, during")(0), delete("t3", entity: "tag")(0), upsert("n5", "Note 5")(0),
      ]
    }

    try await engine().pull()

    #expect(try storedTags() == [Tag(id: "t1", title: "Tag 1, during")])
    #expect(try storedNotes() == notesAt8 + [Note(id: "n5", title: "Note 5")])
    #expect(try state()?.cursor == 11)
    // The catch-up stopped at the cursor it started at, 8, though the store had more.
    #expect(server.state.requests == [4, 7, 8, 10])
  }

  @Test
  func changesWrittenWhileACatchUpWasInterruptedArriveToo() async throws {
    try await olderReleaseSyncedTo8()
    server.state.withValue { $0.failing = [2] }
    let engine = engine()
    await #expect(throws: (any Error).self) { try await engine.pull() }

    server.state.withValue { $0.failing = [] }
    server.append(delete("t1", entity: "tag"))
    server.append(tag("t5", "Tag 5"))
    try await engine.pull()

    #expect(try storedTags() == [Tag(id: "t3", title: "Tag 3"), Tag(id: "t5", title: "Tag 5")])
    #expect(try state()?.cursor == 10)
  }

  @Test
  func anOlderReleasePullingMeanwhileStartsTheCatchUpOver() async throws {
    try await olderReleaseSyncedTo8()
    server.state.withValue { $0.failing = [2] }
    await #expect(throws: (any Error).self) { try await engine().pull() }
    #expect(try state()?.catchUpUntil == 8)

    // A downgrade: the older release moves the cursor, not knowing the catch-up's state.
    server.state.withValue { $0.failing = [] }
    server.append(delete("t1", entity: "tag"))
    server.append(upsert("n6", "Note 6"))
    try await older.pull()
    #expect(try state()?.cursor == 10)

    // Back on the newer release, the catch-up starts over, from the snapshot to 10.
    try await engine().pull()
    #expect(try storedTags() == [Tag(id: "t3", title: "Tag 3")])
    #expect(try storedNotes() == notesAt8 + [Note(id: "n6", title: "Note 6")])
    #expect(server.state.snapshotRequests == 2)
    #expect(try state()?.entities == "note,tag")
  }

  @Test
  func staleTagsFromAnEarlierReleaseAreReplaced() async throws {
    try await olderReleaseSyncedTo8()
    // Left by a release that stored tags before a downgrade: the catch-up replaces them.
    try await database.write { db in
      try Tag.insert { Tag(id: "gone", title: "Deleted while downgraded") }.execute(db)
      try Tag.insert { Tag(id: "t3", title: "Stale") }.execute(db)
    }
    try await engine().pull()
    #expect(try storedTags() == tagsAt8)
  }

  @Test
  func aSnapshotNewerThanTheCursorNeedsNoChangesBeforeIt() async throws {
    try await olderReleaseSyncedTo8()
    server.append(tag("t3", "Tag 3, renamed"))
    server.append(delete("t1", entity: "tag"))
    try server.publishSnapshot(
      id: "snp_2", seq: 10, notes: notesAt8, tags: [Tag(id: "t3", title: "Tag 3, renamed")])

    try await engine().pull()

    #expect(try storedTags() == [Tag(id: "t3", title: "Tag 3, renamed")])
    #expect(try state()?.cursor == 10)
    // Nothing to pull for the catch-up: the pull went on from the cursor, 8.
    #expect(server.state.requests == [8])
  }

  @Test
  func aStoreWithoutASnapshotCatchesUpFromTheStartOfTheLog() async throws {
    server.append(upsert("n1", "Note 1"))
    server.append(tag("t1", "Tag 1"))
    server.append(tag("t2", "Tag 2"))
    let older = older
    try await older.bootstrap()
    try await older.pull()
    server.state.withValue { $0.requests = [] }

    try await engine().pull()

    #expect(try storedTags() == [Tag(id: "t1", title: "Tag 1"), Tag(id: "t2", title: "Tag 2")])
    #expect(try storedNotes() == [Note(id: "n1", title: "Note 1")])
    #expect(server.state.requests == [0, 3])
  }

  @Test
  func aSnapshotReplacedWhileItDownloadsStartsTheCatchUpOverFromTheLatest() async throws {
    try await olderReleaseSyncedTo8()
    // snp_2, at 6, replaces snp_1 (and snp_1 is deleted) once snp_1 was handed out, whose
    // tags' URLs have expired by the time they're downloaded.
    try server.publishSnapshot(
      id: "snp_2", seq: 6, notes: notesAt8,
      tags: [Tag(id: "t1", title: "Tag 1, renamed"), Tag(id: "t2", title: "Tag 2")])
    let replacing = server.state.withValue { ($0.snapshot!, $0.partBytes) }
    try server.publishSnapshot(
      seq: 4, notes: notesAt8,
      tags: [Tag(id: "t1", title: "Tag 1"), Tag(id: "t2", title: "Tag 2")])
    let expired = Set(tagParts)
    server.state.withValue {
      $0.replacingSnapshot = replacing
      $0.expiredURLs = expired
    }

    try await engine().pull()

    #expect(try storedTags() == tagsAt8)
    // snp_1, its refresh (gone), then snp_2, whose changes after 6 were pulled.
    #expect(server.state.snapshotRequests == 3)
    #expect(server.state.requests == [6, 8])
    #expect(try state()?.entities == "note,tag")
  }

  @Test
  func changesCompactedWhileACatchUpWasInterruptedStartItOver() async throws {
    try await olderReleaseSyncedTo8()
    server.state.withValue { $0.failing = [2] }
    let engine = engine()
    await #expect(throws: (any Error).self) { try await engine.pull() }
    #expect(try state()?.catchUpAfter == 7)

    // Meanwhile a snapshot at 8 is published, and the changes it covers are compacted.
    try server.publishSnapshot(id: "snp_2", seq: 8, notes: notesAt8, tags: tagsAt8)
    server.state.withValue {
      $0.failing = []
      $0.horizon = 8
      $0.requests = []
    }
    try await engine.pull()

    #expect(try storedTags() == tagsAt8)
    #expect(try storedNotes() == notesAt8)
    // After 7 was gone, so it started over from snp_2, which needs no changes before the cursor.
    #expect(server.state.requests == [7, 8])
    #expect(server.state.snapshotRequests == 2)
    #expect(try state()?.entities == "note,tag")
  }

  @Test
  func aNewEpochStillBootstraps() async throws {
    try await olderReleaseSyncedTo8()
    server.state.withValue { $0.epoch = 2 }
    await #expect(throws: SyncError.needsBootstrap) { try await engine().pull() }
    #expect(try state()?.entities == "note")
  }

  @Test
  func changesCompactedDuringTheCatchUpBootstrap() async throws {
    try await olderReleaseSyncedTo8()
    server.state.withValue { $0.horizon = 6 }
    let engine = engine()
    await #expect(throws: SyncError.needsBootstrap) { try await engine.pull() }

    // The fallback: a bootstrap, which takes everything from the snapshot, then the log.
    server.state.withValue { $0.horizon = 0 }
    try await engine.bootstrap()
    try await engine.pull()
    #expect(try storedTags() == tagsAt8)
    #expect(try storedNotes() == notesAt8)
    #expect(try state()?.entities == "note,tag")
  }

  @Test
  func aSchemaBumpBootstrapsRatherThanCatchingUp() async throws {
    try await olderReleaseSyncedTo8()
    await #expect(throws: SyncError.needsBootstrap) { try await engine(syncSchema: 2).pull() }
    #expect(server.state.snapshotRequests == 0)
  }

  @Test
  func unsentWritesStayOverTheCaughtUpRecords() async throws {
    try await olderReleaseSyncedTo8()
    let engine = engine()
    // Written before the first pull: the pull sends it (change 9), then catches tags up.
    try await engine.push([
      .upsert("tag", id: "t1", row: try OpenAPIObjectContainer(unvalidatedValue: ["title": "Mine"]))
    ])
    server.state.withValue { $0.failing = [2] }
    await #expect(throws: (any Error).self) { try await engine.pull() }
    // Loading the snapshot and the first page didn't undo it.
    #expect(try storedTags().first { $0.id == "t1" }?.title == "Mine")

    server.state.withValue { $0.failing = [] }
    try await engine.pull()
    #expect(try storedTags() == [Tag(id: "t1", title: "Mine"), Tag(id: "t3", title: "Tag 3")])
    #expect(try await database.read { db in try PendingMutation.fetchAll(db) }.isEmpty)
  }

  @Test
  func signingOutDuringACatchUpForgetsIt() async throws {
    try await olderReleaseSyncedTo8()
    server.state.withValue { $0.failing = [2] }
    let engine = engine()
    await #expect(throws: (any Error).self) { try await engine.pull() }
    try await engine.removeLocalData()
    #expect(try state() == nil)
    #expect(try storedTags().isEmpty)
  }
}
