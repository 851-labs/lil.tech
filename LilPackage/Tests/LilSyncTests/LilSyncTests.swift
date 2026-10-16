import CryptoKit
import Dependencies
import DependenciesTestSupport
import Foundation
import GzipFiles
import HTTPTypes
import LilAPI
import OpenAPIRuntime
import SQLiteData
import Testing

@testable import LilSync

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
  },
  clear: { db in
    try Note.delete().execute(db)
  }
)

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
    /// The store's latest snapshot: its manifest and each part's bytes by URL.
    var snapshot: Components.Schemas.SnapshotManifest?
    var partBytes: [String: Data] = [:]
    /// URLs that answer as expired; `GET /v1/sync/snapshots/{id}` hands out fresh ones.
    var expiredURLs: Set<String> = []
    /// URLs whose next download fails as a dropped connection.
    var interrupted: Set<String> = []
    var downloads: [String] = []
    var snapshotRequests = 0
  }
  let state = LockIsolated(State())

  /// Publishes a snapshot of `notes` as of `seq`, `perPart` records per part.
  func publishSnapshot(id: String = "snp_1", seq: Int, notes: [Note], perPart: Int = 2) throws {
    var parts: [Components.Schemas.SnapshotPart] = []
    var bytes: [String: Data] = [:]
    for (index, start) in stride(from: 0, to: notes.count, by: perPart).enumerated() {
      let lines = notes[start..<min(start + perPart, notes.count)]
        .map { #"{"id":"\#($0.id)","title":"\#($0.title)"}"# }
        .joined(separator: "\n")
      let gzip = try Gzip.compress(Data(lines.utf8))
      let url = "https://api.test/v1/sync/parts?token=\(id)-\(index)"
      bytes[url] = gzip
      let sha = SHA256.hash(data: gzip).map { String(format: "%02x", $0) }.joined()
      parts.append(
        .init(url: url, records: lines.split(separator: "\n").count, bytes: gzip.count, sha256: sha)
      )
    }
    let (finalParts, finalBytes) = (parts, bytes)
    state.withValue {
      $0.snapshot = .init(
        id: id, seq: seq, epoch: $0.epoch, createdAt: 0,
        entities: [
          .init(entity: "note", parts: finalParts), .init(entity: "unknown_entity", parts: []),
        ])
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
    .mock { [self] request, _ in
      let path = request.path ?? ""
      if path.hasPrefix("/v1/sync/snapshot") {
        return try state.withValue { state in
          state.snapshotRequests += 1
          if path == "/v1/sync/snapshot" {
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
      let after =
        Int(
          URLComponents(string: request.path ?? "")?.queryItems?
            .first { $0.name == "after" }?.value ?? "0") ?? 0
      return try state.withValue { state in
        state.requests.append(after)
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

  private func engine(entities: [SyncEntity] = [notes], syncSchema: Int = 1) -> LilSyncEngine {
    withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.snapshotDownloader = server.downloader
      $0.continuousClock = ImmediateClock()
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
  func aNewEntityBootstrapsAgainForWhatWasSkipped() async throws {
    server.append(upsert("n1", "One"))
    // An older release that didn't store notes moves its cursor past them.
    let older = engine(entities: [])
    try await older.bootstrap()
    try await older.pull()
    #expect(try storedNotes().isEmpty)

    // One that stores them starts over from the store by itself, so the skipped note arrives.
    let newer = engine()
    await #expect(throws: SyncError.needsBootstrap) { try await newer.pull() }
    try await newer.bootstrap()
    try await newer.pull()
    #expect(try storedNotes() == [Note(id: "n1", title: "One")])
    // Recorded, so it doesn't bootstrap again.
    server.append(upsert("n2", "Two"))
    try await newer.pull()
    #expect(try storedNotes().count == 2)
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
    let clock = SleepRecordingClock(immediateSleeps: 1)
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
    try await clock.waitUntilAsleep(dueWithin: .seconds(1))
    #expect(server.state.requests.count == 1)
    clock.advance(by: .seconds(1))
    try await clock.waitUntilAsleep(dueWithin: .seconds(2))
    #expect(server.state.requests.count == 2)
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
    #expect(statuses.value.contains(.failed("unexpectedStatus(500)")))
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

  private func engine(database: any DatabaseWriter) -> LilSyncEngine {
    withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.snapshotDownloader = server.downloader
      // Sleeps last until cancelled: `run()` idles after a pull rather than pulling in a loop.
      $0.continuousClock = ManualClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 0))
      $0.date.now = syncedAt
    } operation: {
      LilSyncEngine(entities: [notes], syncSchema: 1, partsDirectory: partsDirectory)
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
    // The first part came from disk the second time.
    #expect(server.state.downloads == [urls[0], urls[1], urls[1], urls[2]])
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
    // One refresh serves every remaining part.
    #expect(
      server.state.value.downloads == [urls[0], urls[0] + "&fresh", urls[1] + "&fresh"])
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
  func runBootstrapsANewDeviceAndReportsProgress() async throws {
    let all = (1...4).map { Note(id: "n\($0)", title: "\($0)") }
    for note in all { server.append(upsert(note.id, note.title)) }
    try server.publishSnapshot(seq: 4, notes: all)
    let database = try makeDatabase(bootstrapped: false)
    let engine = engine(database: database)
    let statuses = LockIsolated<[SyncStatus]>([])
    let updates = await engine.statusUpdates()
    let observing = Task {
      for await status in updates { statuses.withValue { $0.append(status) } }
    }
    let running = Task { await engine.run() }
    try await eventually { try storedNotes(database).count == 4 }
    try await eventually { statuses.value.last == .upToDate(at: syncedAt) }
    running.cancel()
    await running.value
    observing.cancel()
    #expect(statuses.value.contains(.bootstrapping(downloadedParts: 2, totalParts: 2)))
  }
}

/// A clock that records how long each sleep was for. The first `immediateSleeps` return at once;
/// later ones suspend until cancelled. Not `ImmediateClock` underneath: its sleeps wait on
/// background-priority tasks, which other tests running alongside can starve.
private final class SleepRecordingClock: Clock, Sendable {
  typealias Instant = ImmediateClock<Duration>.Instant

  private let current = LockIsolated(Instant())
  private let immediateSleeps: Int
  let sleeps = LockIsolated<[Duration]>([])

  init(immediateSleeps: Int) {
    self.immediateSleeps = immediateSleeps
  }

  var now: Instant { current.value }
  var minimumResolution: Duration { .zero }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    try Task.checkCancellation()
    let count = sleeps.withValue {
      $0.append(now.duration(to: deadline))
      return $0.count
    }
    if count > immediateSleeps {
      try await Task.sleep(for: .seconds(3600))
    }
    current.withValue { $0 = max($0, deadline) }
  }
}

/// A clock that tests move on by hand, like `TestClock`, but that can wait until the code under
/// test is asleep: advancing a `TestClock` before then is missed, and the sleep never ends.
/// Unlike `TestClock`, an advance goes straight to its end, so a sleep started by a task it wakes
/// counts from there.
private final class ManualClock: Clock, Sendable {
  typealias Instant = ImmediateClock<Duration>.Instant

  private struct Sleeper {
    let id: UUID
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant()
    var sleepers: [Sleeper] = []
    /// Sleeps cancelled while not waiting: before they started (then they end at once), or after
    /// they ended (harmless).
    var cancelled: Set<UUID> = []
  }

  private let state = LockIsolated(State())

  var now: Instant { state.value.now }
  var minimumResolution: Duration { .zero }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result: Result<Void, any Error>? = state.withValue { state in
          if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
          if deadline <= state.now { return .success(()) }
          state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      let sleeper = state.withValue { state -> Sleeper? in
        guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
          state.cancelled.insert(id)
          return nil
        }
        return state.sleepers.remove(at: index)
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Whether a sleep that ends within `duration` from now is in progress.
  func isAsleep(dueWithin duration: Duration) -> Bool {
    let state = state.value
    return state.sleepers.contains { $0.deadline <= state.now.advanced(by: duration) }
  }

  struct NeverAsleep: Error {}

  /// Waits until a sleep that ends within `duration` from now is in progress. Throws if none
  /// starts, so the test stops there rather than going on in the wrong state.
  func waitUntilAsleep(
    dueWithin duration: Duration, sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    try await eventually({ isAsleep(dueWithin: duration) }, sourceLocation: sourceLocation)
    guard isAsleep(dueWithin: duration) else { throw NeverAsleep() }
  }

  /// Moves time on by `duration`, ending the sleeps that are due.
  func advance(by duration: Duration) {
    let due = state.withValue { state in
      state.now = state.now.advanced(by: duration)
      let now = state.now
      let due = state.sleepers.filter { $0.deadline <= now }
      state.sleepers.removeAll { $0.deadline <= now }
      return due
    }
    for sleeper in due { sleeper.continuation.resume() }
  }
}

/// Waits for `condition`, which other tasks make true, yielding in between. Bounded by time
/// rather than a number of yields, so a busy machine (e.g. the pre-commit hook building the apps
/// alongside) doesn't make it give up early.
private func eventually(
  _ condition: () throws -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(30))
  while ContinuousClock.now < deadline {
    if try condition() { return }
    await Task.yield()
    if try condition() { return }
    // A pause rather than spinning, which would take the CPU from the tasks being waited on.
    try await Task.sleep(for: .milliseconds(1))
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
    let listening = Task { await engine.listen { "token-1" } }
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
  func reconnectsRightAwayWithAFreshTokenWhenAWorkingConnectionsTokenExpires() async throws {
    let engine = engine()
    let issued = LockIsolated(0)
    let listening = Task {
      await engine.listen {
        issued.withValue { $0 += 1 }
        return "token-\(issued.value)"
      }
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
    let listening = Task { await engine.listen { "token" } }
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
    let listening = Task { await engine.listen { "token" } }
    try await eventually { live.connections.value.count == 1 }
    listening.cancel()
    live.latest()?.finish()
    await listening.value
    #expect(live.connections.value.count == 1)
  }
}
