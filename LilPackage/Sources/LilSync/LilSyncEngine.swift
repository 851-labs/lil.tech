import CryptoKit
import Dependencies
public import Foundation
import GzipFiles
import IssueReporting
import LilAPI
import SQLiteData

/// What the UI shows about sync.
public enum SyncStatus: Equatable, Sendable {
  case idle
  /// Catching up. `cursor` and `head` give progress.
  case syncing(cursor: Int, head: Int)
  /// Starting over from a snapshot (`docs/SYNC.md`), as a new device does, or one whose local
  /// data is from another epoch or behind compacted changes: parts downloaded so far, of how many.
  case bootstrapping(downloadedParts: Int, totalParts: Int)
  /// The last pull failed. Sync retries with backoff.
  case failed(String)
}

/// Pulls a user's change log into the local database (`docs/SYNC.md`): each page is applied
/// together with the new cursor in one transaction, so the cursor never runs ahead of the data.
///
/// Named so it doesn't clash with SQLiteData's CloudKit `SyncEngine`.
public actor LilSyncEngine {
  /// Changes per pull.
  static let pageSize = 1000
  /// How long to wait between pulls with nothing new, unless ``syncNow()`` is called.
  static let idleInterval = Duration.seconds(60)

  private let entities: [String: SyncEntity]
  private let database: any DatabaseWriter
  private let api: any APIProtocol
  private let clock: any Clock<Duration>
  private let random: WithRandomNumberGenerator
  private let downloader: SnapshotDownloader
  private let liveConnection: LiveConnection
  /// Where downloaded snapshot parts are kept until they're loaded, by SHA-256, so an
  /// interrupted bootstrap doesn't download them again.
  private let partsDirectory: URL
  private let syncSchema: Int

  private var status = SyncStatus.idle
  private var observers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
  /// Set by ``syncNow()``, so the next wait in ``run()`` is skipped.
  private var syncRequested = false
  private var wake: CheckedContinuation<Void, Never>?

  /// - Parameters:
  ///   - syncSchema: The app's sync schema number (`docs/SYNC.md`). Bump it in a release that
  ///     starts storing a new entity or field: local data synced with a lower number is
  ///     bootstrapped again, so what was skipped before arrives.
  ///   - partsDirectory: Where to keep downloaded snapshot parts until they're loaded. Defaults
  ///     to a folder in the app's caches.
  public init(entities: [SyncEntity], syncSchema: Int = 1, partsDirectory: URL? = nil) {
    self.syncSchema = syncSchema
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.api) var api
    @Dependency(\.continuousClock) var clock
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
            setStatus(.failed(String(describing: error)))
            delay = backoff(afterFailures: failures, error: error)
          }
        } else {
          failures += 1
          justBootstrapped = false
          setStatus(.failed(String(describing: error)))
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

  private func exclusively(_ body: @escaping @Sendable () async throws -> Void) async throws {
    let previous = operation
    let task = Task<Result<Void, any Error>, Never> {
      await previous?.value
      return await Result { try await body() }
    }
    operation = Task { _ = await task.value }
    try await task.value.get()
  }

  /// Pulls pages until caught up. Throws ``SyncError/needsBootstrap`` when the local data must be
  /// replaced from a snapshot, and other errors for failures worth retrying.
  public func pull() async throws {
    try await exclusively { try await self.pullPages() }
  }

  private func pullPages() async throws {
    while true {
      try Task.checkCancellation()
      let state = try await database.read { try SyncState.fetch($0) }
      // A new device starts from a snapshot rather than replaying the whole log.
      if state.epoch == nil, state.cursor == 0 { throw SyncError.needsBootstrap }
      // Synced before this release stored some entity or field: start over to get it.
      if state.epoch != nil, (state.syncSchema ?? 1) < syncSchema { throw SyncError.needsBootstrap }
      let page = try await fetchPage(after: state.cursor)
      if let epoch = state.epoch, epoch != page.epoch { throw SyncError.needsBootstrap }
      if state.cursor > page.head { throw SyncError.needsBootstrap }
      try Self.check(page, after: state.cursor)
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
          syncSchema: state.syncSchema
        )
        .save(db)
      }
      guard page.hasMore else {
        setStatus(.idle)
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
    let latest = try await fetchLatestSnapshot()
    guard var manifest = latest.snapshot else {
      try await database.write { [entities] db in
        for entity in entities.values { try entity.clear(db) }
        try SyncState(
          id: SyncState.singletonID, cursor: 0, epoch: latest.epoch, syncSchema: syncSchema
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
    let totalParts = hashes.count
    var downloaded = 0
    var files: [(entity: String, file: URL)] = []
    for entity in wanted {
      for original in entity.parts {
        let file = partsDirectory.appending(path: "\(original.sha256).ndjson.gz")
        if !isVerified(file, sha256: original.sha256) {
          // Use the latest manifest's URL for the part, refreshing it once if it expired.
          func currentURL() -> String {
            manifest.entities.first { $0.entity == entity.entity }?
              .parts.first { $0.sha256 == original.sha256 }?.url ?? original.url
          }
          let data: Data
          do {
            data = try await download(url: currentURL(), sha256: original.sha256)
          } catch is SnapshotDownloader.Expired {
            manifest = try await fetchSnapshot(id: manifest.id)
            data = try await download(url: currentURL(), sha256: original.sha256)
          }
          try FileManager.default.createDirectory(
            at: partsDirectory, withIntermediateDirectories: true)
          try data.write(to: file, options: .atomic)
        }
        files.append((entity.entity, file))
        downloaded += 1
        setStatus(.bootstrapping(downloadedParts: downloaded, totalParts: totalParts))
      }
    }

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
        syncSchema: syncSchema
      )
      .save(db)
    }
    removeDownloadedParts(keeping: [])
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

  private static func sha256Hex(_ data: Data) -> String {
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
