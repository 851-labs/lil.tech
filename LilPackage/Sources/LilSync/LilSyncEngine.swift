import Dependencies
import Foundation
import IssueReporting
import LilAPI
import SQLiteData

/// What the UI shows about sync.
public enum SyncStatus: Equatable, Sendable {
  case idle
  /// Pulling. `cursor` and `head` give progress.
  case syncing(cursor: Int, head: Int)
  /// The last pull failed. Sync retries with backoff.
  case failed(String)
  /// The local data is from another epoch (or the server went back in time, or the changes after
  /// the cursor were compacted), so it must start over from a snapshot.
  case needsBootstrap
}

/// Pulls a user's change log into the local database (`docs/SYNC.md`): each page is applied
/// together with the new cursor in one transaction, so the cursor never runs ahead of the data.
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

  private var status = SyncStatus.idle
  private var observers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
  private var wait: Task<Void, any Error>?

  public init(entities: [SyncEntity]) {
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.api) var api
    @Dependency(\.continuousClock) var clock
    @Dependency(\.withRandomNumberGenerator) var random
    self.entities = Dictionary(
      entities.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
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

  /// Pulls until caught up, then every ``idleInterval`` or when ``syncNow()`` is called, until
  /// cancelled. The app runs it only while signed in. Failures are retried with exponential
  /// backoff and jitter, from 1 second up to 5 minutes.
  public func run() async {
    var failures = 0
    while !Task.isCancelled {
      let delay: Duration
      do {
        try await pull()
        failures = 0
        delay = Self.idleInterval
      } catch is CancellationError {
        return
      } catch SyncError.needsBootstrap {
        setStatus(.needsBootstrap)
        delay = Self.idleInterval
      } catch {
        failures += 1
        setStatus(.failed(String(describing: error)))
        delay = backoff(afterFailures: failures)
      }
      await sleep(for: delay)
    }
  }

  /// Ends the current wait in ``run()``, e.g. after a live notice that new changes exist.
  public func syncNow() {
    wait?.cancel()
  }

  /// Pulls pages until caught up. Throws ``SyncError/needsBootstrap`` when the local data must be
  /// replaced from a snapshot, and other errors for failures worth retrying.
  public func pull() async throws {
    while true {
      try Task.checkCancellation()
      let state = try await database.read { try SyncState.fetch($0) }
      let page = try await fetchPage(after: state.cursor)
      if let epoch = state.epoch, epoch != page.epoch { throw SyncError.needsBootstrap }
      if state.cursor > page.head { throw SyncError.needsBootstrap }
      setStatus(.syncing(cursor: state.cursor, head: page.head))
      try await database.write { [entities] db in
        for change in page.changes {
          guard let entity = entities[change.entity] else { continue }
          switch change.op {
          case "upsert":
            guard let row = change.row else { throw SyncError.missingRow(seq: change.seq) }
            try entity.upsert(change.id, row, db)
          case "delete":
            try entity.delete(change.id, db)
          default:
            continue
          }
        }
        try SyncState(id: SyncState.singletonID, cursor: page.next, epoch: page.epoch).save(db)
      }
      if !page.hasMore {
        setStatus(.idle)
        return
      }
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
    case .undocumented(let statusCode, _):
      throw SyncError.unexpectedStatus(statusCode)
    }
  }

  private func backoff(afterFailures failures: Int) -> Duration {
    let seconds = min(300, pow(2, Double(min(failures, 10) - 1)))
    let jitter = random { Double.random(in: 0.5...1, using: &$0) }
    return .seconds(seconds * jitter)
  }

  private func sleep(for duration: Duration) async {
    let clock = clock
    let task = Task { try await clock.sleep(for: duration) }
    wait = task
    _ = await task.result
    wait = nil
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
  case unexpectedStatus(Int)
  case missingRow(seq: Int)
}
