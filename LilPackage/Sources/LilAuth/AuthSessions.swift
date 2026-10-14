public import Dependencies
import Foundation
import IssueReporting
public import LilAPI

extension DependencyValues {
  /// The app's session: tokens for API requests, refreshed as needed.
  public var authSessions: AuthSessions {
    get { self[AuthSessionsKey.self] }
    set { self[AuthSessionsKey.self] = newValue }
  }

  /// Makes `@Dependency(\.api)` requests use `authSessions`. Apps call it once, in
  /// `prepareDependencies`.
  public mutating func authenticateAPI() {
    apiAuthentication = authSessions.apiAuthentication
  }
}

private enum AuthSessionsKey: DependencyKey {
  static var liveValue: AuthSessions { AuthSessions() }
  static var testValue: AuthSessions { AuthSessions() }
  static var previewValue: AuthSessions { AuthSessions() }
}

/// The signed-in session, kept in the `sessionStore`. Hands out access tokens, refreshing one
/// shortly before it expires (or after the server rejected it), one refresh at a time. A refresh
/// token the server rejects signs the app out.
public actor AuthSessions {
  /// Refresh this long before the access token expires, so requests in flight don't race it.
  static let refreshMargin: TimeInterval = 60

  private let store: SessionStore
  private let api: any APIProtocol
  private let now: @Sendable () -> Date
  private var session: AuthSession?
  private var loaded = false
  private var refreshing: Task<AuthSession?, any Error>?
  private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]

  public init() {
    @Dependency(\.sessionStore) var store
    @Dependency(\.api) var api
    @Dependency(\.date) var date
    self.store = store
    self.api = api
    self.now = { date.now }
  }

  /// Whether the app is signed in, now and after every change.
  public func signedInUpdates() -> AsyncStream<Bool> {
    let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    observers[id] = continuation
    continuation.yield(current() != nil)
    continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    return stream
  }

  /// A current access token, refreshed first if it's about to expire, or `nil` when signed out.
  /// Throws if a refresh fails for a reason worth retrying (e.g. no network).
  public func accessToken() async throws -> String? {
    guard let session = current() else { return nil }
    if session.accessTokenExpiresAt.timeIntervalSince(now()) > Self.refreshMargin {
      return session.accessToken
    }
    return try await refresh(from: session)?.accessToken
  }

  /// The server rejected `token`: the next ``accessToken()`` refreshes, unless it already has.
  public func rejected(_ token: String) {
    guard var session = current(), session.accessToken == token else { return }
    session.accessTokenExpiresAt = .distantPast
    self.session = session
  }

  /// Starts a session after signing in.
  public func signedIn(_ session: AuthSession) {
    set(session)
  }

  /// Ends the session: tells the server, then forgets the tokens even if that fails.
  public func signOut() async {
    if current() != nil {
      _ = try? await api.authSignOut()
    }
    set(nil)
  }

  /// For `@Dependency(\.apiAuthentication)`, so API requests use this session.
  public nonisolated var apiAuthentication: APIAuthentication {
    APIAuthentication(
      accessToken: { try await self.accessToken() },
      rejected: { await self.rejected($0) }
    )
  }

  private func refresh(from stale: AuthSession) async throws -> AuthSession? {
    if let refreshing { return try await refreshing.value }
    // Isolated to this actor, so it can't start before `refreshing` is set, and it settles the
    // session before anyone waiting on it resumes.
    let task = Task { () async throws -> AuthSession? in
      defer { refreshing = nil }
      let refreshed = try await exchange(stale.refreshToken)
      // A sign-in or sign-out meanwhile wins over this refresh.
      guard current()?.refreshToken == stale.refreshToken else { return current() }
      set(refreshed)
      return refreshed
    }
    refreshing = task
    return try await task.value
  }

  /// A new session for `refreshToken`, or `nil` if the server won't refresh it.
  private func exchange(_ refreshToken: String) async throws -> AuthSession? {
    switch try await api.authRefresh(body: .json(.init(refreshToken: refreshToken))) {
    case .ok(let ok):
      return AuthSession(try ok.body.json)
    case .unauthorized:
      // Expired, revoked or already used: the user signs in again.
      return nil
    case .undocumented(let statusCode, _):
      throw RefreshFailed(statusCode: statusCode)
    }
  }

  struct RefreshFailed: Error {
    let statusCode: Int
  }

  private func current() -> AuthSession? {
    if !loaded {
      loaded = true
      session = withErrorReporting { try store.load() } ?? nil
    }
    return session
  }

  private func set(_ session: AuthSession?) {
    let wasSignedIn = current() != nil
    self.session = session
    withErrorReporting { try store.save(session) }
    if wasSignedIn != (session != nil) {
      for observer in observers.values { observer.yield(session != nil) }
    }
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }
}
