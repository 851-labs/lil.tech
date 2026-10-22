import CryptoKit
import Dependencies
public import Foundation
import IssueReporting
public import LilAPI
import LilGzip
import SQLiteData

/// What the UI shows about sync.
public enum SyncStatus: Equatable, Sendable {
  /// Not run yet.
  case idle
  /// Catching up, a page at a time. `cursor` and `head` give progress: `head - cursor` changes
  /// are left.
  case syncing(cursor: Int, head: Int)
  /// Starting over from a snapshot (`docs/sync/protocol.md`), as a new device does, or one whose
  /// local data is from another epoch or behind compacted changes.
  case bootstrapping(BootstrapProgress)
  /// Caught up with the server as of `at`, the end of the last pull.
  case upToDate(at: Date)
  /// The last pull failed because there's no connection. Sync retries with backoff.
  case offline
  /// The last pull failed. Sync retries with backoff.
  case failed(String)
}

/// How far a bootstrap has got, in records, so it can say how many are left (851-2946).
public struct BootstrapProgress: Equatable, Sendable {
  public enum Stage: Equatable, Sendable {
    /// Asking for the snapshot, then downloading its parts.
    case downloading
    /// Loading the downloaded records, into staging tables or straight into their tables.
    case loading
    /// Moving staged records into their tables, in one transaction that can't report progress
    /// (about 7 s per million records, 851-2859).
    case finishing
  }

  public var stage: Stage
  /// Records done in this stage: in the parts downloaded so far, or loaded so far.
  public var records: Int
  /// The snapshot's records, from its manifest's parts. 0 until the manifest has arrived, and
  /// for a snapshot without records.
  public var totalRecords: Int

  public init(stage: Stage, records: Int, totalRecords: Int) {
    self.stage = stage
    self.records = records
    self.totalRecords = totalRecords
  }

  /// Records this stage still has to do. A manifest's counts are the server's, so it never goes
  /// below zero if a part holds more.
  public var recordsLeft: Int { max(totalRecords - records, 0) }

  public static func downloading(_ records: Int, of totalRecords: Int) -> Self {
    Self(stage: .downloading, records: records, totalRecords: totalRecords)
  }

  public static func loading(_ records: Int, of totalRecords: Int) -> Self {
    Self(stage: .loading, records: records, totalRecords: totalRecords)
  }

  public static func finishing(_ totalRecords: Int) -> Self {
    Self(stage: .finishing, records: totalRecords, totalRecords: totalRecords)
  }
}

/// Pulls a user's change log into the local database (`docs/sync/protocol.md`): each page is
/// applied together with the new cursor in one transaction, so the cursor never runs ahead of the
/// data.
///
/// Named so it doesn't clash with SQLiteData's CloudKit `SyncEngine`.
public actor LilSyncEngine {
  /// Changes per pull, the most the server sends. The next page downloads while one is written,
  /// so a big catch-up runs at about the speed of decoding pages (851-2649).
  static let pageSize = 5000
  /// How long to wait between pulls with nothing new, unless ``syncNow()`` is called.
  static let idleInterval = Duration.seconds(60)

  private let entities: [String: SyncEntity]
  private let database: any DatabaseWriter
  private let api: any APIProtocol
  private let clock: any Clock<Duration>
  private let date: DateGenerator
  private let random: WithRandomNumberGenerator
  private let downloader: SnapshotDownloader
  private let liveConnection: LiveConnection
  /// Where downloaded snapshot parts are kept until they're loaded, by SHA-256, so an
  /// interrupted bootstrap doesn't download them again.
  private let partsDirectory: URL
  private let syncSchema: Int
  /// Entity names as `SyncState.entities` records them.
  private static func recorded(_ names: some Sequence<String>) -> String {
    names.sorted().joined(separator: ",")
  }

  private var status = SyncStatus.idle
  private var observers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
  /// Set by ``syncNow()``, so the next wait in ``run()`` is skipped.
  private var syncRequested = false
  private var wake: CheckedContinuation<Void, Never>?

  /// - Parameters:
  ///   - syncSchema: The app's sync schema number (`docs/sync/protocol.md`). Bump it in a release
  ///     that starts storing a new field of an entity it already had: local data synced with a
  ///     lower number is bootstrapped again, so what was skipped before arrives. New entities don't
  ///     need a bump: the engine bootstraps again by itself when `entities` gains one.
  ///   - partsDirectory: Where to keep downloaded snapshot parts until they're loaded. Defaults
  ///     to a folder in the app's caches, the server's own (``cachesDirectory(for:allowsOverride:caches:bundleIdentifier:)``).
  public init(entities: [SyncEntity], syncSchema: Int, partsDirectory: URL? = nil) {
    self.syncSchema = syncSchema
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.api) var api
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    @Dependency(\.withRandomNumberGenerator) var random
    @Dependency(\.snapshotDownloader) var downloader
    @Dependency(\.liveConnection) var liveConnection
    self.downloader = downloader
    self.liveConnection = liveConnection
    self.partsDirectory =
      partsDirectory
      ?? Self.cachesDirectory(for: .current())
      .appending(path: "SnapshotParts", directoryHint: .isDirectory)
    self.entities = Dictionary(
      entities.map { ($0.name, $0) },
      uniquingKeysWith: { first, _ in
        reportIssue("SyncEntity \(first.name) is registered more than once; the first one is used.")
        return first
      }
    )
    self.database = database
    self.api = api
    self.clock = clock
    self.date = date
    self.random = random
  }

  /// The current status, then every change to it.
  public func statusUpdates() -> AsyncStream<SyncStatus> {
    statusUpdates(bufferingPolicy: .bufferingNewest(1))
  }

  /// Every status, for tests that check a bootstrap's progress step by step.
  func statusUpdates(
    bufferingPolicy: AsyncStream<SyncStatus>.Continuation.BufferingPolicy
  ) -> AsyncStream<SyncStatus> {
    let (stream, continuation) = AsyncStream<SyncStatus>.makeStream(
      bufferingPolicy: bufferingPolicy)
    let id = UUID()
    observers[id] = continuation
    continuation.yield(status)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id) }
    }
    return stream
  }

  /// Pulls until caught up, then every ``idleInterval`` or when ``syncNow()`` is called, until the
  /// task running it is cancelled. The app runs it only while signed in. Failures are retried with
  /// exponential backoff and jitter, from 1 second up to 5 minutes.
  public func run() async {
    var failures = 0
    var justBootstrapped = false
    while !Task.isCancelled {
      let delay: Duration
      do {
        syncRequested = false
        try await pull()
        failures = 0
        justBootstrapped = false
        delay = Self.idleInterval
      } catch {
        // Cancellation can come back wrapped, e.g. as a client error around `URLError.cancelled`.
        if Task.isCancelled { return }
        // Needing another bootstrap right after one is a failure, so it backs off.
        if error as? SyncError == .needsBootstrap, !justBootstrapped {
          // Start over from a snapshot, then pull right away.
          do {
            try await bootstrap()
            justBootstrapped = true
            continue
          } catch {
            if Task.isCancelled { return }
            failures += 1
            setStatus(Self.status(for: error))
            delay = backoff(afterFailures: failures, error: error)
          }
        } else {
          failures += 1
          justBootstrapped = false
          setStatus(Self.status(for: error))
          delay = backoff(afterFailures: failures, error: error)
        }
      }
      if failures == 0 {
        await wait(for: delay)
      } else {
        // A failure's backoff isn't cut short by sync requests, e.g. from live notices.
        try? await clock.sleep(for: delay)
      }
    }
  }

  /// How long a live connection must last to count as working: it resets the reconnect backoff,
  /// and its token expiring reconnects right away. The server greets every connection, so a
  /// greeting alone doesn't count.
  static let stableConnection = Duration.seconds(60)

  /// Keeps a live notice connection open until the task running it is cancelled
  /// (`docs/sync/protocol.md`): a notice of a `head` past the local cursor runs a pull
  /// (``syncNow()``). The app runs it alongside ``run()`` while it's active.
  ///
  /// Each connection gets its token from `authentication` (refreshed if needed; `nil` means signed
  /// out, which is retried like any failure). When the server closes a connection because its
  /// token is no longer good (code 4001: it expired, or the account was deleted), the token goes to
  /// `authentication.rejected`, so the next one is refreshed instead of reused; a deleted account's
  /// refresh fails, which signs the app out. A working connection closed that way reconnects right
  /// away; anything else reconnects with exponential backoff and jitter, from 1 second to 5
  /// minutes.
  public func listen(authentication: APIAuthentication) async {
    var failures = 0
    while !Task.isCancelled {
      var error: any Error = LiveConnection.Closed(code: 1000)
      // Finishes only if the connection lasts `stableConnection`.
      let stableTimer = Task { [clock] in
        (try? await clock.sleep(for: Self.stableConnection)) != nil
      }
      var token: String?
      do {
        guard let current = try await authentication.accessToken() else { throw SignedOut() }
        token = current
        let messages = try await liveConnection.connect(current)
        for try await message in messages { await receive(message) }
      } catch let caught {
        error = caught
      }
      stableTimer.cancel()
      let stable = await stableTimer.value
      if Task.isCancelled { return }
      if error is LiveConnection.TokenExpired, let token { await authentication.rejected(token) }
      if stable { failures = 0 }
      if stable, error is LiveConnection.TokenExpired { continue }
      failures += 1
      try? await clock.sleep(for: backoff(afterFailures: failures))
    }
  }

  /// There's no session to connect with.
  struct SignedOut: Error {}

  /// Handles one live message: `{ "type": "head", "seq": n }`. Others are ignored, so the server
  /// can add kinds. Failing to read the cursor is reported, but doesn't drop the connection.
  private func receive(_ message: String) async {
    struct Notice: Decodable {
      let type: String
      let seq: Int?
    }
    guard
      let notice = try? JSONDecoder().decode(Notice.self, from: Data(message.utf8)),
      notice.type == "head", let seq = notice.seq
    else { return }
    do {
      let cursor = try await database.read { try SyncState.fetch($0).cursor }
      if seq > cursor { syncNow() }
    } catch {
      reportIssue(error)
    }
  }

  /// Pulls again as soon as possible: ends the current wait in ``run()``, or skips the next one if
  /// a pull is in progress. Called e.g. after a live notice that new changes exist.
  public func syncNow() {
    syncRequested = true
    endWait()
  }

  /// Writes `mutations` to the local tables, and queues them for the server, which gets them
  /// before the next pull, started now (`docs/sync/protocol.md`). Only for entities apps may write
  /// (none since pins were retired, 851-2990). Until the server has them and the cursor passes
  /// them, pulled changes don't undo them. Waits for a pull or bootstrap in progress, so it lands
  /// after it, and before signing out deletes the local data. A push the server refuses as invalid
  /// is dropped, and the local data is replaced from a snapshot, so it matches the server again.
  public func push(_ mutations: [SyncMutation]) async throws {
    guard !mutations.isEmpty else { return }
    let pending = PendingMutation(
      id: UUID().uuidString.lowercased(),
      mutations: String(decoding: try JSONEncoder().encode(mutations), as: UTF8.self))
    try await exclusively { [database, entities] in
      try await database.write { db in
        try PendingMutation.apply(mutations, entities: entities, db)
        try PendingMutation.insert { pending }.execute(db)
      }
    }
    syncNow()
  }

  /// Sends queued mutations the server doesn't have yet, oldest first, and records the `seq` of
  /// each. Throws ``SyncError/needsBootstrap`` after dropping one the server refused for good.
  private func pushPending() async throws {
    let unsent = try await database.read { db in
      try PendingMutation.oldestFirst.where { $0.seq.is(nil) }.fetchAll(db)
    }
    for pending in unsent {
      try Task.checkCancellation()
      let seq: Int
      switch try await api.syncPushMutations(body: .json(try pending.body())) {
      case .ok(let ok):
        seq = try ok.body.json.seq
      case .badRequest:
        // Refused for good (e.g. an invalid row): the local write goes.
        reportIssue("The server refused pushed mutations \(pending.id); starting over")
        try await database.write { db in
          try PendingMutation.find(pending.id).delete().execute(db)
        }
        throw SyncError.needsBootstrap
      case .code507:
        // The account is full: kept, for when it has room again.
        throw SyncError.unexpectedStatus(507)
      case .unauthorized:
        throw SyncError.unauthorized
      case .serviceUnavailable:
        throw SyncError.unavailable
      case .tooManyRequests(let response):
        throw SyncError.rateLimited(
          retryAfterSeconds: Components.Schemas.TooManyRequests.retryAfterSeconds {
            try response.body.json
          })
      case .undocumented(let statusCode, _):
        throw SyncError.unexpectedStatus(statusCode)
      }
      try await database.write { db in
        try PendingMutation.find(pending.id).update { $0.seq = #bind(seq) }.execute(db)
      }
    }
  }

  /// The pull or bootstrap in progress. The actor runs other work while they wait, so they take
  /// turns: a pull that read the cursor before a bootstrap committed mustn't write after it.
  private var operation: Task<Void, Never>?

  /// Runs `body` after the operations before it. Cancelling the caller cancels `body`, e.g.
  /// stopping ``run()`` stops its pull's requests and downloads.
  private func exclusively(_ body: @escaping @Sendable () async throws -> Void) async throws {
    let previous = operation
    let task = Task<Result<Void, any Error>, Never> {
      await previous?.value
      return await Result { try await body() }
    }
    operation = Task { _ = await task.value }
    try await withTaskCancellationHandler {
      try await task.value.get()
    } onCancel: {
      task.cancel()
    }
  }

  /// Deletes the local data, where the sync is, and downloaded snapshot parts, e.g. when the
  /// account signs out: the next pull starts over as a new device. Waits for a pull or bootstrap
  /// in progress, so nothing it was writing lands afterwards. The database is vacuumed and its
  /// write-ahead log truncated, so the deleted rows don't linger in the files.
  public func removeLocalData() async throws {
    try await exclusively { try await self.deleteLocalData() }
  }

  private func deleteLocalData() async throws {
    try await database.write { [entities] db in
      for entity in entities.values { try entity.clear(db) }
      // In case discarding them after a failed bootstrap failed too.
      for table in entities.values.compactMap(\.staging?.table) {
        try SnapshotStaging.discard(table, db)
      }
      try SyncState.find(SyncState.singletonID).delete().execute(db)
      // Unsent writes belong to the account signing out.
      try PendingMutation.delete().execute(db)
    }
    try await database.vacuum()
    _ = try await database.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    removeDownloadedParts(keeping: [])
    setStatus(.idle)
  }

  /// Pulls pages until caught up. Throws ``SyncError/needsBootstrap`` when the local data must be
  /// replaced from a snapshot, and other errors for failures worth retrying.
  public func pull() async throws {
    try await exclusively {
      // A push that keeps failing doesn't stop pulls: its writes stay over what's pulled, and
      // its failure is thrown afterwards, so it's retried with backoff.
      var pushFailure: (any Error)?
      do {
        try await self.pushPending()
      } catch let error as SyncError where error == .needsBootstrap || error == .unauthorized {
        throw error
      } catch  where !Task.isCancelled {
        pushFailure = error
      }
      try await self.pullPages()
      if let pushFailure { throw pushFailure }
    }
  }

  private func pullPages() async throws {
    /// The next page, downloading while one is written. Each page is written with the cursor
    /// it ends at, which is where the next one starts.
    var next: Task<Components.Schemas.ChangesPage, any Error>?
    defer { next?.cancel() }
    while true {
      try Task.checkCancellation()
      let state = try await database.read { try SyncState.fetch($0) }
      // A new device starts from a snapshot rather than replaying the whole log.
      if state.epoch == nil, state.cursor == 0 { throw SyncError.needsBootstrap }
      // Synced before this release stored some entity or field: start over to get it.
      if state.epoch != nil, (state.syncSchema ?? 1) < syncSchema { throw SyncError.needsBootstrap }
      if state.epoch != nil, let stored = state.entities,
        !Set(entities.keys).isSubset(of: stored.split(separator: ",").map(String.init))
      {
        throw SyncError.needsBootstrap
      }
      // An older release (after a downgrade) records only what it stores and its own schema, so
      // the newer one bootstraps again when it's back.
      let syncSchema = min(state.syncSchema ?? 1, syncSchema)
      let stored = state.entities.map { recorded in
        Self.recorded(
          Set(recorded.split(separator: ",").map(String.init)).intersection(entities.keys))
      }
      let page: Components.Schemas.ChangesPage
      if let prefetched = next {
        next = nil
        // Cancelling the pull cancels the download too: waiting on a task's value wouldn't.
        page = try await withTaskCancellationHandler {
          try await prefetched.value
        } onCancel: {
          prefetched.cancel()
        }
      } else {
        page = try await fetchPage(after: state.cursor)
      }
      if let epoch = state.epoch, epoch != page.epoch { throw SyncError.needsBootstrap }
      if state.cursor > page.head { throw SyncError.needsBootstrap }
      try Self.check(page, after: state.cursor)
      try Task.checkCancellation()
      if page.hasMore {
        let after = page.next
        next = Task { try await self.fetchPage(after: after) }
      }
      try await database.write { [entities] db in
        for change in page.changes {
          guard let entity = entities[change.entity] else { continue }
          do {
            switch change.op {
            case "upsert":
              guard let row = change.row else { throw SyncError.missingRow(seq: change.seq) }
              try entity.upsert(change.id, row, db)
            case "delete":
              try entity.delete(change.id, db)
            default:
              continue
            }
          } catch let error as DecodingError {
            // A row this app can't read would otherwise block every later change. It's skipped;
            // an app version that understands it bootstraps again (`docs/sync/protocol.md`).
            reportIssue("Skipped \(change.entity) change \(change.seq): \(error)")
          } catch SyncError.missingRow(let seq) {
            reportIssue("Skipped \(change.entity) change \(seq): an upsert without a row")
          }
        }
        try SyncState(
          id: SyncState.singletonID, cursor: page.next, epoch: page.epoch,
          syncSchema: syncSchema, entities: stored
        )
        .save(db)
        try PendingMutation.reapply(after: page.next, entities: entities, db)
      }
      guard page.hasMore else {
        setStatus(.upToDate(at: date.now))
        return
      }
      setStatus(.syncing(cursor: page.next, head: page.head))
    }
  }

  /// Replaces the local data with the latest snapshot (`docs/sync/protocol.md`):
  ///
  /// 1. Downloads every part of the registered entities and checks its SHA-256. Verified parts are
  ///    kept on disk until loaded, so an interrupted bootstrap only downloads what's missing.
  ///    Expired URLs are refreshed for the same snapshot.
  /// 2. Resets the client to a new device's state and clears the entities' tables, so a load
  ///    that's interrupted starts over.
  /// 3. Loads the parts in batches, into staging tables for entities that have them, then, in
  ///    one transaction, moves those into their tables (`SnapshotStaging`) and sets the cursor
  ///    and epoch to the snapshot's.
  ///
  /// If the store has no snapshot yet, the tables are cleared and the whole log is pulled.
  public func bootstrap() async throws {
    try await exclusively { try await self.replaceFromSnapshot() }
  }

  /// Records per write transaction while loading or staging, so other writes aren't held up for
  /// long.
  static let loadBatchSize = 5_000

  private func replaceFromSnapshot() async throws {
    setProgress(.downloading(0, of: 0))
    let (syncSchema, recordedEntities) = (syncSchema, Self.recorded(entities.keys))
    let latest = try await fetchLatestSnapshot()
    guard var manifest = latest.snapshot else {
      try await database.write { [entities] db in
        for entity in entities.values { try entity.clear(db) }
        try SyncState(
          id: SyncState.singletonID, cursor: 0, epoch: latest.epoch, syncSchema: syncSchema,
          entities: recordedEntities
        )
        .save(db)
        try PendingMutation.reapply(after: 0, entities: entities, db)
      }
      removeDownloadedParts(keeping: [])
      return
    }

    let wanted = manifest.entities.filter { entities[$0.entity] != nil }
    let hashes = Set(wanted.flatMap { $0.parts.map(\.sha256) })
    // Parts left by an older bootstrap aren't needed any more.
    removeDownloadedParts(keeping: hashes)
    let parts = wanted.flatMap { entity in entity.parts.map { (entity: entity.entity, part: $0) } }
    let files = parts.map { (entity: $0.entity, file: partFile($0.part.sha256)) }
    // Each file once, even if two parts have the same contents.
    var seen = Set<String>()
    let downloads = parts.filter { seen.insert($0.part.sha256).inserted }
    // Progress counts records, from the manifest, as the footer shows them (851-2946).
    let downloadRecords = downloads.reduce(0) { $0 + max($1.part.records, 0) }
    let loadRecords = parts.reduce(0) { $0 + max($1.part.records, 0) }
    try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
    bootstrapManifest = manifest
    defer { bootstrapManifest = nil }
    setProgress(.downloading(0, of: downloadRecords))
    // A few at a time: one download at a time left the connection mostly idle.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, part) in downloads.enumerated() {
        if index >= Self.parallelDownloads { try await group.next() }
        group.addTask {
          try await self.downloadPart(part.part, of: part.entity)
        }
      }
      try await group.waitForAll()
    }
    manifest = bootstrapManifest ?? manifest
    // Straight on, so the download's full bar doesn't sit there while the tables are cleared.
    setProgress(.loading(0, of: loadRecords))

    // Tables whose records go through a staging table (`SnapshotStaging`).
    let staged = Set(wanted.compactMap { entities[$0.entity]?.staging?.table }).sorted()
    try await database.write { [entities] db in
      // Until the load finishes, this client is a new device, which bootstraps again.
      try SyncState.find(SyncState.singletonID).delete().execute(db)
      for entity in entities.values { try entity.clear(db) }
      for table in staged { try SnapshotStaging.create(for: table, db) }
    }
    do {
      for (name, file) in files {
        guard let entity = entities[name] else { continue }
        try await load(entity, from: file)
      }
      setProgress(.finishing(loadRecords))
      try await database.write { [manifest, entities] db in
        for table in staged { try SnapshotStaging.finish(table, db) }
        try SyncState(
          id: SyncState.singletonID, cursor: manifest.seq, epoch: manifest.epoch,
          syncSchema: syncSchema, entities: recordedEntities
        )
        .save(db)
        try PendingMutation.reapply(after: manifest.seq, entities: entities, db)
      }
    } catch {
      // The user's records mustn't linger in the staging tables, also when cancelled.
      await Task { [database] in
        try? await database.write { db in
          for table in staged { try SnapshotStaging.discard(table, db) }
        }
      }.value
      throw error
    }
    // The load was one transaction, so the write-ahead log grew as big as the records. Truncated
    // now unless something's reading (GRDB doesn't wait), and otherwise once a later checkpoint
    // resets it, down to `walSizeLimit`.
    _ = try? await database.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA journal_size_limit = \(Self.walSizeLimit)")
      try db.checkpoint(.truncate)
    }
    removeDownloadedParts(keeping: [])
  }

  /// Loads one downloaded part's records, into the entity's staging table if it has one, and
  /// reports them loaded after each batch.
  private func load(_ entity: SyncEntity, from file: URL) async throws {
    let records: Data
    do {
      records = try Gzip.decompress(Data(contentsOf: file))
    } catch {
      // A damaged file is downloaded again next time.
      try? FileManager.default.removeItem(at: file)
      throw error
    }
    let staging = entity.staging.map {
      (insert: $0.insert, table: SnapshotStaging.name(for: $0.table))
    }
    let lines = records.split(separator: UInt8(ascii: "\n"))
    for start in stride(from: 0, to: lines.count, by: Self.loadBatchSize) {
      let batch = lines[start..<min(start + Self.loadBatchSize, lines.count)]
      try await database.write { db in
        for line in batch where !line.isEmpty {
          do {
            if let staging {
              try staging.insert(Data(line), staging.table, db)
            } else {
              try entity.loadRecord(Data(line), db)
            }
          } catch let error as DecodingError {
            // As when pulling: a record this app can't read mustn't block the rest.
            reportIssue("Skipped a \(entity.name) record from the snapshot: \(error)")
          }
        }
      }
      advanceProgress(by: batch.count(where: { !$0.isEmpty }))
    }
  }

  /// The size, in bytes, the write-ahead log shrinks back to after a bootstrap grew it.
  static let walSizeLimit = 64 << 20

  /// Snapshot parts downloaded at once while bootstrapping.
  static let parallelDownloads = 4

  /// The snapshot being bootstrapped from, with its part URLs refreshed if they expired.
  private var bootstrapManifest: Components.Schemas.SnapshotManifest?
  /// How many times its URLs were refreshed, and the refresh in progress: parts downloading
  /// together that all find their URLs expired share one refresh.
  private var manifestRefreshes = 0
  private var refreshing: Task<Components.Schemas.SnapshotManifest, any Error>?
  /// The bootstrap's progress, as its status shows it.
  private var bootstrapProgress = BootstrapProgress.downloading(0, of: 0)

  private func setProgress(_ progress: BootstrapProgress) {
    bootstrapProgress = progress
    setStatus(.bootstrapping(progress))
  }

  /// Counts `records` more done in the current stage.
  private func advanceProgress(by records: Int) {
    bootstrapProgress.records += records
    setStatus(.bootstrapping(bootstrapProgress))
  }

  private func partFile(_ sha256: String) -> URL {
    partsDirectory.appending(path: "\(sha256).ndjson.gz")
  }

  /// Downloads a part unless it's on disk already, refreshing the snapshot's URLs once if they
  /// expired (`bootstrapManifest`).
  private func downloadPart(
    _ original: Components.Schemas.SnapshotPart, of entity: String
  ) async throws {
    let file = partFile(original.sha256)
    if !(await Self.isVerified(file, sha256: original.sha256)) {
      // The latest manifest's URL for the part.
      func currentURL() -> String {
        bootstrapManifest?.entities.first { $0.entity == entity }?
          .parts.first { $0.sha256 == original.sha256 }?.url ?? original.url
      }
      let data: Data
      let refreshes = manifestRefreshes
      do {
        data = try await download(url: currentURL(), sha256: original.sha256)
      } catch is SnapshotDownloader.Expired {
        // Unless another part's refresh already got new URLs.
        if manifestRefreshes == refreshes, let id = bootstrapManifest?.id {
          let refresh = refreshing ?? Task { try await self.fetchSnapshot(id: id) }
          refreshing = refresh
          // Only this refresh: another may have started since.
          defer { if refreshing == refresh { refreshing = nil } }
          let fresh = try await refresh.value
          if manifestRefreshes == refreshes {
            bootstrapManifest = fresh
            manifestRefreshes += 1
          }
        }
        data = try await download(url: currentURL(), sha256: original.sha256)
      }
      try await Self.write(data, to: file)
    }
    advanceProgress(by: max(original.records, 0))
  }

  /// Whether `file` holds a part with this hash, as downloaded. Off the actor, like the other
  /// hashing and file work of downloads, so parallel downloads don't take turns on it.
  @concurrent
  private nonisolated static func isVerified(_ file: URL, sha256: String) async -> Bool {
    guard let data = try? Data(contentsOf: file) else { return false }
    return sha256Hex(data) == sha256
  }

  @concurrent
  private nonisolated static func write(_ data: Data, to file: URL) async throws {
    try data.write(to: file, options: .atomic)
  }

  @concurrent
  private nonisolated static func hashes(_ data: Data, to sha256: String) async -> Bool {
    sha256Hex(data) == sha256
  }

  /// Deletes downloaded parts, except those with the given hashes.
  private func removeDownloadedParts(keeping hashes: Set<String>) {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: partsDirectory, includingPropertiesForKeys: nil)) ?? []
    for file in files
    where !hashes.contains(file.lastPathComponent.replacing(".ndjson.gz", with: "")) {
      try? FileManager.default.removeItem(at: file)
    }
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Downloads a part and checks its hash.
  private func download(url: String, sha256: String) async throws -> Data {
    guard let url = URL(string: url) else { throw SyncError.unexpectedPage }
    let data = try await downloader.download(url)
    guard await Self.hashes(data, to: sha256) else { throw SyncError.corruptPart }
    return data
  }

  private func fetchLatestSnapshot() async throws -> Components.Schemas.LatestSnapshot {
    switch try await api.syncSnapshot() {
    case .ok(let ok):
      return try ok.body.json
    case .unauthorized:
      throw SyncError.unauthorized
    case .serviceUnavailable:
      throw SyncError.unavailable
    case .tooManyRequests(let response):
      throw SyncError.rateLimited(
        retryAfterSeconds: Components.Schemas.TooManyRequests.retryAfterSeconds {
          try response.body.json
        })
    case .undocumented(let statusCode, _):
      throw SyncError.unexpectedStatus(statusCode)
    }
  }

  private func fetchSnapshot(id: String) async throws -> Components.Schemas.SnapshotManifest {
    switch try await api.syncSnapshotById(path: .init(id: id)) {
    case .ok(let ok):
      return try ok.body.json
    case .gone:
      // Replaced and deleted meanwhile: start over with the latest.
      throw SyncError.needsBootstrap
    case .unauthorized:
      throw SyncError.unauthorized
    case .serviceUnavailable:
      throw SyncError.unavailable
    case .tooManyRequests(let response):
      throw SyncError.rateLimited(
        retryAfterSeconds: Components.Schemas.TooManyRequests.retryAfterSeconds {
          try response.body.json
        })
    case .undocumented(let statusCode, _):
      throw SyncError.unexpectedStatus(statusCode)
    }
  }

  private func fetchPage(after cursor: Int) async throws -> Components.Schemas.ChangesPage {
    switch try await api.syncChanges(query: .init(after: cursor, limit: Self.pageSize)) {
    case .ok(let ok):
      return try ok.body.json
    case .gone:
      throw SyncError.needsBootstrap
    case .unauthorized:
      throw SyncError.unauthorized
    case .serviceUnavailable:
      throw SyncError.unavailable
    case .tooManyRequests(let response):
      throw SyncError.rateLimited(
        retryAfterSeconds: Components.Schemas.TooManyRequests.retryAfterSeconds {
          try response.body.json
        })
    case .undocumented(let statusCode, _):
      throw SyncError.unexpectedStatus(statusCode)
    }
  }

  /// A page must continue right after the cursor with no gaps, since a gap would silently lose
  /// changes, and must make progress when there's more.
  private static func check(_ page: Components.Schemas.ChangesPage, after cursor: Int) throws {
    for (offset, change) in page.changes.enumerated() where change.seq != cursor + offset + 1 {
      throw SyncError.needsBootstrap
    }
    if page.next != (page.changes.last?.seq ?? cursor) || (page.hasMore && page.next <= cursor) {
      throw SyncError.unexpectedPage
    }
  }

  /// The wait after `failures` failures in a row, at least as long as a rate limit asks for.
  private func backoff(afterFailures failures: Int, error: (any Error)? = nil) -> Duration {
    let seconds = min(300, pow(2, Double(min(failures, 10) - 1)))
    let jitter = random { Double.random(in: 0.5...1, using: &$0) }
    let backoff = Duration.seconds(seconds * jitter)
    guard case .rateLimited(let retryAfter) = error as? SyncError else { return backoff }
    return max(backoff, .seconds(retryAfter))
  }

  /// Waits for `duration`, until ``syncNow()``, or until the task running ``run()`` is cancelled.
  private func wait(for duration: Duration) async {
    if syncRequested { return }
    let clock = clock
    await withTaskGroup(of: Void.self) { group in
      group.addTask { try? await clock.sleep(for: duration) }
      group.addTask { await self.waitForSyncRequest() }
      await group.next()
      group.cancelAll()
    }
  }

  private func waitForSyncRequest() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if syncRequested || Task.isCancelled {
          continuation.resume()
        } else {
          wake = continuation
        }
      }
    } onCancel: {
      Task { await self.endWait() }
    }
  }

  private func endWait() {
    wake?.resume()
    wake = nil
  }

  /// How a failed pull shows: offline when there's no connection (`isOfflineError`), failed
  /// otherwise.
  static func status(for error: any Error) -> SyncStatus {
    isOfflineError(error) ? .offline : .failed(String(describing: error))
  }

  private func setStatus(_ status: SyncStatus) {
    switch status {
    case .failed, .offline:
      // Announced again when a pull fails as the last one did, so whoever asked for that pull
      // (lil health's Sync intent, 851-2893) hears how it ended.
      break
    default:
      guard status != self.status else { return }
    }
    self.status = status
    for continuation in observers.values { continuation.yield(status) }
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }
}

public enum SyncError: Error, Equatable {
  case needsBootstrap
  case unauthorized
  case unavailable
  /// Too many requests: try again in no less than `retryAfterSeconds`.
  case rateLimited(retryAfterSeconds: Int)
  case unexpectedStatus(Int)
  case missingRow(seq: Int)
  /// The server sent a page that makes no progress or doesn't match its `next`.
  case unexpectedPage
  /// A downloaded snapshot part doesn't match its hash.
  case corruptPart
}

extension LilSyncEngine {
  /// Sync's folder in the app's own caches for `environment` (851-2977), where it keeps
  /// downloaded snapshot parts and blobs (``BlobCache``): `<caches>/<bundle ID>/LilSync`, as
  /// always, for a build that only uses prod, and inside a folder per server for builds that can
  /// use another (`<bundle ID>/Servers/api.staging.lil.tech/LilSync`), so a dev build signing
  /// out of its server leaves the Release app's, and other servers', alone.
  public static func cachesDirectory(
    for environment: APIEnvironment,
    allowsOverride: Bool = APIEnvironment.allowsOverride,
    caches: URL = .cachesDirectory,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) -> URL {
    environment.localDirectory(
      in: caches.appending(path: bundleIdentifier ?? "lil", directoryHint: .isDirectory),
      allowsOverride: allowsOverride
    )
    .appending(path: "LilSync", directoryHint: .isDirectory)
  }
}
