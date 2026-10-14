import Dependencies
import Foundation
import IssueReporting
import LilAPI
import SQLiteData

/// What the UI shows about sync.
public enum SyncStatus: Equatable, Sendable {
  case idle
  /// Catching up. `cursor` and `head` give progress.
  case syncing(cursor: Int, head: Int)
  /// The last pull failed. Sync retries with backoff.
  case failed(String)
  /// The local data is from another epoch (or the server went back in time, or the changes after
  /// the cursor were compacted), so it must start over from a snapshot.
  case needsBootstrap
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

  private var status = SyncStatus.idle
  private var observers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
  /// Set by ``syncNow()``, so the next wait in ``run()`` is skipped.
  private var syncRequested = false
  private var wake: CheckedContinuation<Void, Never>?

  public init(entities: [SyncEntity]) {
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.api) var api
    @Dependency(\.continuousClock) var clock
    @Dependency(\.withRandomNumberGenerator) var random
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
    while !Task.isCancelled {
      let delay: Duration
      do {
        syncRequested = false
        try await pull()
        failures = 0
        delay = Self.idleInterval
      } catch {
        // Cancellation can come back wrapped, e.g. as a client error around `URLError.cancelled`.
        if Task.isCancelled { return }
        if error as? SyncError == .needsBootstrap {
          setStatus(.needsBootstrap)
          delay = Self.idleInterval
        } else {
          failures += 1
          setStatus(.failed(String(describing: error)))
          delay = backoff(afterFailures: failures)
        }
      }
      await wait(for: delay)
    }
  }

  /// Pulls again as soon as possible: ends the current wait in ``run()``, or skips the next one if
  /// a pull is in progress. Called e.g. after a live notice that new changes exist.
  public func syncNow() {
    syncRequested = true
    endWait()
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
        try SyncState(id: SyncState.singletonID, cursor: page.next, epoch: page.epoch).save(db)
      }
      guard page.hasMore else {
        setStatus(.idle)
        return
      }
      setStatus(.syncing(cursor: page.next, head: page.head))
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

  private func backoff(afterFailures failures: Int) -> Duration {
    let seconds = min(300, pow(2, Double(min(failures, 10) - 1)))
    let jitter = random { Double.random(in: 0.5...1, using: &$0) }
    return .seconds(seconds * jitter)
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
  case unexpectedStatus(Int)
  case missingRow(seq: Int)
  /// The server sent a page that makes no progress or doesn't match its `next`.
  case unexpectedPage
}
