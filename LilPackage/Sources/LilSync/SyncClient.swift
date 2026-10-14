public import Dependencies
import IssueReporting

extension DependencyValues {
  /// The app's sync engine. Apps set it once at launch with ``SyncClient/live(entities:)``.
  public var sync: SyncClient {
    get { self[SyncClient.self] }
    set { self[SyncClient.self] = newValue }
  }
}

/// Sync as features use it.
public struct SyncClient: Sendable {
  /// Runs sync until cancelled. See ``LilSyncEngine/run()``.
  public var run: @Sendable () async -> Void
  /// Pulls now instead of at the next interval.
  public var syncNow: @Sendable () async -> Void
  /// The current status, then every change to it.
  public var status: @Sendable () async -> AsyncStream<SyncStatus>

  public init(
    run: @escaping @Sendable () async -> Void,
    syncNow: @escaping @Sendable () async -> Void,
    status: @escaping @Sendable () async -> AsyncStream<SyncStatus>
  ) {
    self.run = run
    self.syncNow = syncNow
    self.status = status
  }

  /// A client backed by a ``LilSyncEngine`` for the app's entities, using the current
  /// `defaultDatabase`, `api` and clock.
  public static func live(entities: [SyncEntity]) -> Self {
    let engine = LilSyncEngine(entities: entities)
    return Self(
      run: { await engine.run() },
      syncNow: { await engine.syncNow() },
      status: { await engine.statusUpdates() }
    )
  }

  /// A client that does nothing and reports `status`, for previews.
  public static func constant(_ status: SyncStatus) -> Self {
    Self(
      run: {},
      syncNow: {},
      status: { AsyncStream { $0.yield(status) } }
    )
  }
}

extension SyncClient: DependencyKey {
  public static var liveValue: Self {
    Self(
      run: { reportIssue("Set @Dependency(\\.sync) to SyncClient.live(entities:) at launch.") },
      syncNow: {},
      status: { AsyncStream { $0.yield(.idle) } }
    )
  }
  public static let previewValue = Self.constant(.idle)
  public static var testValue: Self {
    Self(
      run: { reportIssue("Unimplemented: @Dependency(\\.sync).run") },
      syncNow: { reportIssue("Unimplemented: @Dependency(\\.sync).syncNow") },
      status: {
        reportIssue("Unimplemented: @Dependency(\\.sync).status")
        return AsyncStream { $0.finish() }
      }
    )
  }
}
