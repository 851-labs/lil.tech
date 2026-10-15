public import Dependencies
import IssueReporting

extension DependencyValues {
  /// The app's sync engine. Apps set it once at launch with
  /// ``SyncClient/live(entities:syncSchema:)``.
  public var sync: SyncClient {
    get { self[SyncClient.self] }
    set { self[SyncClient.self] = newValue }
  }
}

/// Sync as features use it.
public struct SyncClient: Sendable {
  /// Runs sync until cancelled. See ``LilSyncEngine/run()``.
  public var run: @Sendable () async -> Void
  /// Keeps a live notice connection open until cancelled. See ``LilSyncEngine/listen(accessToken:)``.
  public var listen:
    @Sendable (_ accessToken: @escaping @Sendable () async throws -> String) async -> Void
  /// Pulls now instead of at the next interval.
  public var syncNow: @Sendable () async -> Void
  /// The current status, then every change to it.
  public var status: @Sendable () async -> AsyncStream<SyncStatus>

  public init(
    run: @escaping @Sendable () async -> Void,
    listen:
      @escaping @Sendable (_ accessToken: @escaping @Sendable () async throws -> String) async ->
      Void,
    syncNow: @escaping @Sendable () async -> Void,
    status: @escaping @Sendable () async -> AsyncStream<SyncStatus>
  ) {
    self.run = run
    self.listen = listen
    self.syncNow = syncNow
    self.status = status
  }

  /// A client backed by a ``LilSyncEngine`` for the app's entities. The engine is made on first
  /// use, so it picks up the `defaultDatabase` and `api` that `prepareDependencies` sets
  /// alongside this client.
  public static func live(entities: [SyncEntity], syncSchema: Int) -> Self {
    let engine = LockIsolated<LilSyncEngine?>(nil)
    let resolve: @Sendable () -> LilSyncEngine = {
      engine.withValue { engine in
        if let engine { return engine }
        let made = LilSyncEngine(entities: entities, syncSchema: syncSchema)
        engine = made
        return made
      }
    }
    return Self(
      run: { await resolve().run() },
      listen: { accessToken in await resolve().listen(accessToken: accessToken) },
      syncNow: { await resolve().syncNow() },
      status: { await resolve().statusUpdates() }
    )
  }

  /// A client that does nothing and reports `status`, for previews.
  public static func constant(_ status: SyncStatus) -> Self {
    Self(
      run: {},
      listen: { _ in },
      syncNow: {},
      status: { AsyncStream { $0.yield(status) } }
    )
  }
}

extension SyncClient: DependencyKey {
  public static var liveValue: Self {
    Self(
      run: {
        reportIssue("Set @Dependency(\\.sync) to SyncClient.live(entities:syncSchema:) at launch.")
      },
      listen: { _ in
        reportIssue("Set @Dependency(\\.sync) to SyncClient.live(entities:syncSchema:) at launch.")
      },
      syncNow: {},
      status: { AsyncStream { $0.yield(.idle) } }
    )
  }
  public static let previewValue = Self.constant(.idle)
  public static var testValue: Self {
    Self(
      run: { reportIssue("Unimplemented: @Dependency(\\.sync).run") },
      listen: { _ in reportIssue("Unimplemented: @Dependency(\\.sync).listen") },
      syncNow: { reportIssue("Unimplemented: @Dependency(\\.sync).syncNow") },
      status: {
        reportIssue("Unimplemented: @Dependency(\\.sync).status")
        return AsyncStream { $0.finish() }
      }
    )
  }
}
