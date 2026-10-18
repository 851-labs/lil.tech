public import Dependencies
import IssueReporting
public import LilAPI

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
  /// Keeps a live notice connection open until cancelled. See
  /// ``LilSyncEngine/listen(authentication:)``.
  public var listen: @Sendable (_ authentication: APIAuthentication) async -> Void
  /// Pulls now instead of at the next interval.
  public var syncNow: @Sendable () async -> Void
  /// Writes mutations locally and queues them for the server. See ``LilSyncEngine/push(_:)``.
  public var push: @Sendable (_ mutations: [SyncMutation]) async throws -> Void
  /// The current status, then every change to it.
  public var status: @Sendable () async -> AsyncStream<SyncStatus>
  /// Deletes the local copy, e.g. when signing out. See ``LilSyncEngine/removeLocalData()``.
  public var removeLocalData: @Sendable () async throws -> Void

  public init(
    run: @escaping @Sendable () async -> Void,
    listen: @escaping @Sendable (_ authentication: APIAuthentication) async -> Void,
    syncNow: @escaping @Sendable () async -> Void,
    push: @escaping @Sendable (_ mutations: [SyncMutation]) async throws -> Void,
    status: @escaping @Sendable () async -> AsyncStream<SyncStatus>,
    removeLocalData: @escaping @Sendable () async throws -> Void
  ) {
    self.run = run
    self.listen = listen
    self.syncNow = syncNow
    self.push = push
    self.status = status
    self.removeLocalData = removeLocalData
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
      listen: { authentication in await resolve().listen(authentication: authentication) },
      syncNow: { await resolve().syncNow() },
      push: { try await resolve().push($0) },
      status: { await resolve().statusUpdates() },
      removeLocalData: { try await resolve().removeLocalData() }
    )
  }

  /// A client that does nothing and reports `status`, for previews.
  public static func constant(_ status: SyncStatus) -> Self {
    Self(
      run: {},
      listen: { _ in },
      syncNow: {},
      push: { _ in },
      status: { AsyncStream { $0.yield(status) } },
      removeLocalData: {}
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
      push: { _ in
        reportIssue("Set @Dependency(\\.sync) to SyncClient.live(entities:syncSchema:) at launch.")
      },
      status: { AsyncStream { $0.yield(.idle) } },
      removeLocalData: {
        reportIssue("Set @Dependency(\\.sync) to SyncClient.live(entities:syncSchema:) at launch.")
      }
    )
  }
  public static let previewValue = Self.constant(.idle)
  public static var testValue: Self {
    Self(
      run: { reportIssue("Unimplemented: @Dependency(\\.sync).run") },
      listen: { _ in reportIssue("Unimplemented: @Dependency(\\.sync).listen") },
      syncNow: { reportIssue("Unimplemented: @Dependency(\\.sync).syncNow") },
      push: { _ in reportIssue("Unimplemented: @Dependency(\\.sync).push") },
      status: {
        reportIssue("Unimplemented: @Dependency(\\.sync).status")
        return AsyncStream { $0.finish() }
      },
      removeLocalData: { reportIssue("Unimplemented: @Dependency(\\.sync).removeLocalData") }
    )
  }
}
