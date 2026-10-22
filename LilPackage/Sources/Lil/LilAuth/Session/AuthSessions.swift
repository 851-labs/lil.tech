import ComposableArchitecture
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

  /// Keeps the app's settings (`@Shared(.appStorage(…))`) with this build's server, as its
  /// session is (851-2977): a Release build keeps `UserDefaults.standard`, and a dev build a
  /// suite per server (`APIEnvironment.localDefaults`), so signing out of one, which clears the
  /// account's settings, leaves the Release app's and other servers'. Apps call it once, in
  /// `prepareDependencies`, before anything reads a setting.
  public mutating func keepSettingsPerServer() {
    defaultAppStorage = APIEnvironment.current().localDefaults()
  }
}

private enum AuthSessionsKey: DependencyKey {
  static var liveValue: AuthSessions { AuthSessions() }
  // A real one: it only talks to `sessionStore` and `api`, which tests control.
  static var testValue: AuthSessions { AuthSessions() }
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
  /// Whether `session` reflects the store. A failed read (e.g. the Keychain before the first
  /// unlock after a restart) is tried again next time.
  private var loaded = false
  private var refreshing: (refreshToken: String, task: Task<Void, any Error>)?
  private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]
  private let clock: any Clock<Duration>
  /// Reads the store again until it can, while someone's waiting to know if the app is signed in.
  private var rereading: Task<Void, Never>?

  /// How long to wait before reading a store that couldn't be read again.
  static let rereadInterval: Duration = .seconds(2)

  public init() {
    @Dependency(\.sessionStore) var store
    @Dependency(\.api) var api
    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var clock
    self.store = store
    self.api = api
    self.now = { date.now }
    self.clock = clock
  }

  /// Whether the app is signed in, now and after every change. Nothing is yielded until the
  /// session store can be read (e.g. the Keychain before the first unlock after a restart).
  public func signedInUpdates() -> AsyncStream<Bool> {
    let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    observers[id] = continuation
    let session = current()
    if loaded {
      continuation.yield(session != nil)
    } else {
      rereadUntilLoaded()
    }
    continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    return stream
  }

  private func rereadUntilLoaded() {
    guard rereading == nil else { return }
    rereading = Task {
      while !loaded, !Task.isCancelled {
        try? await clock.sleep(for: Self.rereadInterval)
        _ = current()
      }
      rereading = nil
    }
  }

  /// A current access token, refreshed first if it's about to expire, or `nil` when signed out.
  /// Throws if the session can't be read or refreshed for a reason worth retrying (e.g. no
  /// network), unless the token it has hasn't quite expired yet.
  public func accessToken() async throws -> String? {
    guard let session = current() else {
      if loaded { return nil }
      throw SessionUnavailable()
    }
    if session.accessTokenExpiresAt.timeIntervalSince(now()) > Self.refreshMargin {
      return session.accessToken
    }
    do {
      return try await refresh(from: session)?.accessToken
    } catch {
      guard session.accessTokenExpiresAt > now() else { throw error }
      return session.accessToken
    }
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

  /// Ends the session: forgets the tokens, then tells the server (best effort) so it can revoke
  /// them.
  public func signOut() async {
    let token = current()?.accessToken
    let expiresAt = current()?.accessTokenExpiresAt
    set(nil)
    // An expired token can't sign out; the forgotten refresh token then just expires unused.
    guard let token, let expiresAt, expiresAt > now() else { return }
    await withDependencies {
      $0.apiAuthentication = APIAuthentication(accessToken: { token }, rejected: { _ in })
    } operation: { [api] in
      _ = try? await api.authSignOut()
    }
  }

  /// Forgets the session without telling the server, e.g. once the account is deleted and its
  /// sessions with it.
  public func forget() {
    set(nil)
  }

  /// For `@Dependency(\.apiAuthentication)`, so API requests use this session.
  public nonisolated var apiAuthentication: APIAuthentication {
    APIAuthentication(
      accessToken: { try await self.accessToken() },
      rejected: { await self.rejected($0) }
    )
  }

  /// Refreshes `stale`, or waits for the refresh already in flight for it, and returns the
  /// session as it then is. A sign-in or sign-out meanwhile wins over the refresh.
  private func refresh(from stale: AuthSession) async throws -> AuthSession? {
    while let refreshing, refreshing.refreshToken != stale.refreshToken {
      // A refresh for an earlier session (before a sign-in): let it settle first.
      _ = try? await refreshing.task.value
    }
    let task: Task<Void, any Error>
    if let refreshing {
      task = refreshing.task
    } else {
      guard current()?.refreshToken == stale.refreshToken else { return current() }
      // Isolated to this actor, so it can't start before `refreshing` is set, and it settles
      // the session before anyone waiting on it resumes.
      task = Task {
        defer { refreshing = nil }
        let refreshed = try await exchange(stale.refreshToken)
        guard current()?.refreshToken == stale.refreshToken else { return }
        set(refreshed)
      }
      refreshing = (stale.refreshToken, task)
    }
    try await task.value
    return current()
  }

  /// A new session for `refreshToken`, or `nil` if the server won't refresh it.
  private func exchange(_ refreshToken: String) async throws -> AuthSession? {
    let output = try await api.authRefresh(body: .json(.init(refreshToken: refreshToken)))
    switch output {
    case .ok(let ok):
      return AuthSession(try ok.body.json, receivedAt: now())
    case .unauthorized:
      // Expired, revoked or already used: the user signs in again.
      return nil
    case .tooManyRequests:
      // Rate limited: the session is still good, so it's kept for a later try.
      throw RefreshFailed(statusCode: 429)
    case .undocumented(let statusCode, _):
      throw RefreshFailed(statusCode: statusCode)
    }
  }

  struct RefreshFailed: Error {
    let statusCode: Int
  }

  /// The session store couldn't be read.
  struct SessionUnavailable: Error {}

  private func current() -> AuthSession? {
    if !loaded {
      let stored: AuthSession?
      do {
        stored = try store.load()
      } catch {
        reportIssue(error)
        return nil
      }
      loaded = true
      session = stored
      // Observers subscribed while the store couldn't be read are waiting for an answer.
      for observer in observers.values { observer.yield(stored != nil) }
    }
    return session
  }

  private func set(_ session: AuthSession?) {
    let wasSignedIn = current() != nil
    self.session = session
    loaded = true
    withErrorReporting { try store.save(session) }
    if wasSignedIn != (session != nil) {
      for observer in observers.values { observer.yield(session != nil) }
    }
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }
}
