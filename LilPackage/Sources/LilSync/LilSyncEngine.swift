import CryptoKit
import Dependencies
public import Foundation
import GzipFiles
import IssueReporting
import LilAPI
import SQLiteData

/// What the UI shows about sync.
public enum SyncStatus: Equatable, Sendable {
  /// Not run yet.
  case idle
  /// Catching up. `cursor` and `head` give progress.
  case syncing(cursor: Int, head: Int)
  /// Starting over from a snapshot (`docs/SYNC.md`), as a new device does, or one whose local
  /// data is from another epoch or behind compacted changes: parts downloaded so far, of how many.
  case bootstrapping(downloadedParts: Int, totalParts: Int)
  /// Caught up with the server as of `at`, the end of the last pull.
  case upToDate(at: Date)
  /// The last pull failed because there's no connection. Sync retries with backoff.
  case offline
  /// The last pull failed. Sync retries with backoff.
  case failed(String)
}

/// Pulls a user's change log into the local database (`docs/SYNC.md`): each page is applied
/// together with the new cursor in one transaction, so the cursor never runs ahead of the data.
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
  ///   - syncSchema: The app's sync schema number (`docs/SYNC.md`). Bump it in a release that
  ///     starts storing a new field of an entity it already had: local data synced with a lower
  ///     number is bootstrapped again, so what was skipped before arrives. New entities don't
  ///     need a bump: the engine bootstraps again by itself when `entities` gains one.
  ///   - partsDirectory: Where to keep downloaded snapshot parts until they're loaded. Defaults
  ///     to a folder in the app's caches.
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
      ?? URL.cachesDirectory.appending(
        path: "\(Bundle.main.bundleIdentifier ?? "lil")/LilSync/SnapshotParts",
        directoryHint: .isDirectory)
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
    let (stream, continuation) = AsyncStream<SyncStatus>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
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

  /// Keeps a live notice connection open until the task running it is cancelled (`docs/SYNC.md`):
  /// a notice of a `head` past the local cursor runs a pull (``syncNow()``). The app runs it
  /// alongside ``run()`` while it's active.
  ///
  /// Each connection gets its token from `accessToken`, which refreshes it if needed. A working
  /// connection the server closed because its token expired reconnects right away with a fresh
  /// one; anything else reconnects with exponential backoff and jitter, from 1 second to 5 minutes.
  public func listen(accessToken: @escaping @Sendable () async throws -> String) async {
    var failures = 0
    while !Task.isCancelled {
      var error: any Error = LiveConnection.Closed(code: 1000)
      // Finishes only if the connection lasts `stableConnection`.
      let stableTimer = Task { [clock] in
        (try? await clock.sleep(for: Self.stableConnection)) != nil
      }
      do {
        let messages = try await liveConnection.connect(try await accessToken())
        for try await message in messages { await receive(message) }
      } catch let caught {
        error = caught
      }
      stableTimer.cancel()
      let stable = await stableTimer.value
      if Task.isCancelled { return }
      if stable { failures = 0 }
      if stable, error is LiveConnection.TokenExpired { continue }
      failures += 1
      try? await clock.sleep(for: backoff(afterFailures: failures))
    }
  }

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
      try SyncState.find(SyncState.singletonID).delete().execute(db)
    }
    try await database.vacuum()
    _ = try await database.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    removeDownloadedParts(keeping: [])
    setStatus(.idle)
  }

  /// Pulls pages until caught up. Throws ``SyncError/needsBootstrap`` when the local data must be
  /// replaced from a snapshot, and other errors for failures worth retrying.
  public func pull() async throws {
    try await exclusively { try await self.pullPages() }
  }

  private func pullPages() async throws {
    /// The next page, downloading while one is written, and the cursor it follows.
    var next: (after: Int, page: Task<Components.Schemas.ChangesPage, any Error>)?
    defer { next?.page.cancel() }
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
      if let prefetched = next, prefetched.after == state.cursor {
        next = nil
        page = try await prefetched.page.value
      } else {
        next?.page.cancel()
        next = nil
        page = try await fetchPage(after: state.cursor)
      }
      if let epoch = state.epoch, epoch != page.epoch { throw SyncError.needsBootstrap }
      if state.cursor > page.head { throw SyncError.needsBootstrap }
      try Self.check(page, after: state.cursor)
      if page.hasMore {
        let after = page.next
        next = (after, Task { try await self.fetchPage(after: after) })
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
            // an app version that understands it bootstraps again (`docs/SYNC.md`).
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
      }
      guard page.hasMore else {
        setStatus(.upToDate(at: date.now))
        return
      }
      setStatus(.syncing(cursor: page.next, head: page.head))
    }
  }

  /// Replaces the local data with the latest snapshot (`docs/SYNC.md`):
  ///
  /// 1. Downloads every part of the registered entities and checks its SHA-256. Verified parts are
  ///    kept on disk until loaded, so an interrupted bootstrap only downloads what's missing.
  ///    Expired URLs are refreshed for the same snapshot.
  /// 2. Resets the client to a new device's state and clears the entities' tables, so a load
  ///    that's interrupted starts over.
  /// 3. Loads the parts in batches, then sets the cursor and epoch to the snapshot's.
  ///
  /// If the store has no snapshot yet, the tables are cleared and the whole log is pulled.
  public func bootstrap() async throws {
    try await exclusively { try await self.replaceFromSnapshot() }
  }

  /// Records per write transaction while loading, so other writes aren't held up for long.
  static let loadBatchSize = 5_000

  private func replaceFromSnapshot() async throws {
    setStatus(.bootstrapping(downloadedParts: 0, totalParts: 0))
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
    try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
    bootstrapManifest = manifest
    downloadedParts = 0
    defer { bootstrapManifest = nil }
    // A few at a time: one download at a time left the connection mostly idle.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, part) in parts.enumerated() {
        if index >= Self.parallelDownloads { try await group.next() }
        group.addTask {
          try await self.downloadPart(part.part, of: part.entity, totalParts: hashes.count)
        }
      }
      try await group.waitForAll()
    }
    manifest = bootstrapManifest ?? manifest

    try await database.write { [entities] db in
      // Until the load finishes, this client is a new device, which bootstraps again.
      try SyncState.find(SyncState.singletonID).delete().execute(db)
      for entity in entities.values { try entity.clear(db) }
    }
    for (name, file) in files {
      guard let entity = entities[name] else { continue }
      let records: Data
      do {
        records = try Gzip.decompress(Data(contentsOf: file))
      } catch {
        // A damaged file is downloaded again next time.
        try? FileManager.default.removeItem(at: file)
        throw error
      }
      let lines = records.split(separator: UInt8(ascii: "\n"))
      for start in stride(from: 0, to: lines.count, by: Self.loadBatchSize) {
        let batch = lines[start..<min(start + Self.loadBatchSize, lines.count)]
        try await database.write { db in
          for line in batch where !line.isEmpty {
            do {
              try entity.loadRecord(Data(line), db)
            } catch let error as DecodingError {
              // As when pulling: a record this app can't read mustn't block the rest.
              reportIssue("Skipped a \(name) record from the snapshot: \(error)")
            }
          }
        }
      }
    }
    try await database.write { [manifest] db in
      try SyncState(
        id: SyncState.singletonID, cursor: manifest.seq, epoch: manifest.epoch,
        syncSchema: syncSchema, entities: recordedEntities
      )
      .save(db)
    }
    removeDownloadedParts(keeping: [])
  }

  /// Snapshot parts downloaded at once while bootstrapping.
  static let parallelDownloads = 4

  /// The snapshot being bootstrapped from, with its part URLs refreshed if they expired.
  private var bootstrapManifest: Components.Schemas.SnapshotManifest?
  /// How many times its URLs were refreshed, and the refresh in progress: parts downloading
  /// together that all find their URLs expired share one refresh.
  private var manifestRefreshes = 0
  private var refreshing: Task<Components.Schemas.SnapshotManifest, any Error>?
  private var downloadedParts = 0

  private func partFile(_ sha256: String) -> URL {
    partsDirectory.appending(path: "\(sha256).ndjson.gz")
  }

  /// Downloads a part unless it's on disk already, refreshing the snapshot's URLs once if they
  /// expired (`bootstrapManifest`).
  private func downloadPart(
    _ original: Components.Schemas.SnapshotPart, of entity: String, totalParts: Int
  ) async throws {
    let file = partFile(original.sha256)
    if !isVerified(file, sha256: original.sha256) {
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
          defer { refreshing = nil }
          let fresh = try await refresh.value
          if manifestRefreshes == refreshes {
            bootstrapManifest = fresh
            manifestRefreshes += 1
          }
        }
        data = try await download(url: currentURL(), sha256: original.sha256)
      }
      try data.write(to: file, options: .atomic)
    }
    downloadedParts += 1
    setStatus(.bootstrapping(downloadedParts: downloadedParts, totalParts: totalParts))
  }

  /// Whether `file` holds a part with this hash, as downloaded.
  private func isVerified(_ file: URL, sha256: String) -> Bool {
    guard let data = try? Data(contentsOf: file) else { return false }
    return Self.sha256Hex(data) == sha256
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
    guard Self.sha256Hex(data) == sha256 else { throw SyncError.corruptPart }
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
    guard status != self.status else { return }
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
