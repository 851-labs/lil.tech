import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import LilAPI
import OpenAPIRuntime
import Security
import Testing

@testable import LilAuth

struct AuthSessionsTests {
  @Test
  func handsOutAFreshTokenAsIs() async throws {
    let (sessions, _) = makeSessions(stored: session(1)) { _, _ in
      Issue.record("Unexpected request")
      return (HTTPResponse(status: .internalServerError), nil)
    }
    #expect(try await sessions.accessToken() == "access-1")
  }

  @Test
  func signedOutHasNoToken() async throws {
    let (sessions, _) = makeSessions(stored: nil) { _, _ in
      Issue.record("Unexpected request")
      return (HTTPResponse(status: .internalServerError), nil)
    }
    #expect(try await sessions.accessToken() == nil)
  }

  @Test
  func refreshesShortlyBeforeExpiry() async throws {
    let (sessions, store) = makeSessions(stored: session(1, expiresIn: 30)) { request, body in
      #expect(request.path == "/v1/auth/refresh")
      let sent = try JSONDecoder().decode(
        Components.Schemas.RefreshRequest.self, from: Data(try await string(body).utf8))
      #expect(sent.refreshToken == "refresh-1")
      return tokenPair(2)
    }
    #expect(try await sessions.accessToken() == "access-2")
    #expect(try store.load() == session(2))
  }

  @Test
  func refreshesOnceForConcurrentRequests() async throws {
    let refreshes = LockIsolated(0)
    let (sessions, _) = makeSessions(stored: session(1, expiresIn: 0)) { _, _ in
      refreshes.withValue { $0 += 1 }
      try await Task.sleep(for: .milliseconds(50))
      return tokenPair(2)
    }
    async let first = sessions.accessToken()
    async let second = sessions.accessToken()
    async let third = sessions.accessToken()
    #expect(try await [first, second, third] == ["access-2", "access-2", "access-2"])
    #expect(refreshes.value == 1)
  }

  @Test
  func refreshesARejectedToken() async throws {
    let (sessions, _) = makeSessions(stored: session(1)) { _, _ in tokenPair(2) }
    await sessions.rejected("access-0")
    #expect(try await sessions.accessToken() == "access-1")
    await sessions.rejected("access-1")
    #expect(try await sessions.accessToken() == "access-2")
  }

  @Test
  func aRejectedRefreshTokenSignsOut() async throws {
    let (sessions, store) = makeSessions(stored: session(1, expiresIn: 0)) { _, _ in
      (
        HTTPResponse(status: .unauthorized, headerFields: [.contentType: "application/json"]),
        HTTPBody(#"{"_tag":"InvalidRefreshToken","message":"Sign in again"}"#)
      )
    }
    var updates = await sessions.signedInUpdates().makeAsyncIterator()
    #expect(await updates.next() == true)
    #expect(try await sessions.accessToken() == nil)
    #expect(await updates.next() == false)
    #expect(try store.load() == nil)
  }

  @Test
  func keepsTheSessionWhenARefreshFailsForAnotherReason() async throws {
    let (sessions, store) = makeSessions(stored: session(1, expiresIn: 0)) { _, _ in
      (HTTPResponse(status: .serviceUnavailable), nil)
    }
    await #expect(throws: AuthSessions.RefreshFailed.self) { try await sessions.accessToken() }
    #expect(try store.load() == session(1, expiresIn: 0))
  }

  @Test
  func signingInDuringARefreshWins() async throws {
    let (started, didStart) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let (sessions, store) = makeSessions(stored: session(1, expiresIn: 0)) { _, _ in
      didStart.yield()
      for await _ in release {}
      return tokenPair(2)
    }
    async let token = sessions.accessToken()
    for await _ in started { break }
    await sessions.signedIn(session(3))
    finish.finish()
    #expect(try await token == "access-3")
    #expect(try store.load() == session(3))
  }

  @Test
  func signingOutForgetsTheSessionThenTellsTheServer() async throws {
    let store = SessionStore.inMemory(session(1))
    let calls = LockIsolated<[String?]>([])
    let sessions = withDependencies {
      $0.sessionStore = store
      $0.date.now = now
      $0.api = Client.authenticatedMock { request, _ in
        // Sent with the session's token, though the session is already gone.
        #expect(request.headerFields[.authorization] == "Bearer access-1")
        let stored = try store.load()
        #expect(stored == nil)
        calls.withValue { $0.append(request.path) }
        return (HTTPResponse(status: .internalServerError), nil)
      }
    } operation: {
      AuthSessions()
    }
    var updates = await sessions.signedInUpdates().makeAsyncIterator()
    #expect(await updates.next() == true)
    await sessions.signOut()
    #expect(await updates.next() == false)
    #expect(calls.value == ["/v1/auth/sign-out"])
    #expect(try await sessions.accessToken() == nil)
  }

  @Test
  func signingOutWithAnExpiredTokenDoesntAskTheServer() async throws {
    let (sessions, store) = makeSessions(stored: session(1, expiresIn: -1)) { _, _ in
      Issue.record("Unexpected request")
      return (HTTPResponse(status: .internalServerError), nil)
    }
    await sessions.signOut()
    #expect(try store.load() == nil)
  }

  @Test
  func aFailedRefreshFallsBackToATokenThatHasntExpired() async throws {
    let (sessions, store) = makeSessions(stored: session(1, expiresIn: 30)) { _, _ in
      (HTTPResponse(status: .serviceUnavailable), nil)
    }
    #expect(try await sessions.accessToken() == "access-1")
    #expect(try store.load() == session(1, expiresIn: 30))
  }

  @Test
  func aStoreThatCouldntBeReadIsReadAgain() async throws {
    // The first two reads fail, like the Keychain before the first unlock after a restart.
    let reads = LockIsolated(0)
    let sessions = withDependencies {
      $0.sessionStore = failingFirst(2, reads: reads)
      $0.date.now = now
      $0.continuousClock = TestClock()
    } operation: {
      AuthSessions()
    }
    await withKnownIssue {
      await #expect(throws: AuthSessions.SessionUnavailable.self) {
        try await sessions.accessToken()
      }
      await #expect(throws: AuthSessions.SessionUnavailable.self) {
        try await sessions.accessToken()
      }
    }
    #expect(try await sessions.accessToken() == "access-1")
    #expect(reads.value == 3)
  }

  @Test
  func signedInIsntKnownUntilTheStoreCanBeRead() async throws {
    let reads = LockIsolated(0)
    let clock = TestClock()
    let sessions = withDependencies {
      $0.sessionStore = failingFirst(1, reads: reads)
      $0.date.now = now
      $0.continuousClock = clock
    } operation: {
      AuthSessions()
    }
    let stream = LockIsolated<AsyncStream<Bool>?>(nil)
    await withKnownIssue {
      let updates = await sessions.signedInUpdates()
      stream.setValue(updates)
    }
    var updates = try #require(stream.value).makeAsyncIterator()
    // Not "signed out": the store is read again a little later.
    await clock.advance(by: AuthSessions.rereadInterval)
    #expect(await updates.next() == true)
    #expect(reads.value == 2)
  }

  @Test
  func aRefreshForAnEarlierSessionDoesntAnswerALaterOne() async throws {
    let (started, didStart) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let (sessions, store) = makeSessions(stored: session(1, expiresIn: 0)) { _, body in
      let sent = try JSONDecoder().decode(
        Components.Schemas.RefreshRequest.self, from: Data(try await string(body).utf8))
      if sent.refreshToken == "refresh-1" {
        didStart.yield()
        for await _ in release {}
        return tokenPair(2)
      }
      #expect(sent.refreshToken == "refresh-3")
      return tokenPair(4)
    }
    async let first = sessions.accessToken()
    for await _ in started { break }
    // Signed in again, and that session's token was rejected.
    await sessions.signedIn(session(3))
    await sessions.rejected("access-3")
    async let second = sessions.accessToken()
    finish.finish()
    _ = try await first
    #expect(try await second == "access-4")
    #expect(try store.load() == session(4))
  }
}

struct AuthSessionTests {
  @Test
  func expiryFollowsTheDevicesClock() throws {
    // The device's clock is 20 minutes ahead of the server's.
    let serverNow = now.addingTimeInterval(-1200)
    let claims = #"{"iat":\#(Int(serverNow.timeIntervalSince1970)),"exp":0}"#
    let payload = Data(claims.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let milliseconds = { (date: Date) in Int(date.timeIntervalSince1970 * 1000) }
    let pair = Components.Schemas.TokenPair(
      accessToken: "e30.\(payload).signature",
      accessTokenExpiresAt: milliseconds(serverNow.addingTimeInterval(900)),
      refreshToken: "refresh",
      refreshTokenExpiresAt: milliseconds(serverNow.addingTimeInterval(86_400))
    )
    let session = AuthSession(pair, receivedAt: now)
    #expect(session.accessTokenExpiresAt == now.addingTimeInterval(900))
    #expect(session.refreshTokenExpiresAt == now.addingTimeInterval(86_400))
  }

  @Test
  func expiryWithoutAReadableTokenIsTheServers() {
    let pair = Components.Schemas.TokenPair(
      accessToken: "opaque", accessTokenExpiresAt: 1_800_000_900_000,
      refreshToken: "refresh", refreshTokenExpiresAt: 1_800_086_400_000)
    let session = AuthSession(pair, receivedAt: now)
    #expect(session.accessTokenExpiresAt == Date(timeIntervalSince1970: 1_800_000_900))
  }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)

/// Session `n`, whose access token expires `expiresIn` seconds from `now`.
func session(_ n: Int, expiresIn: TimeInterval = 900) -> AuthSession {
  AuthSession(
    accessToken: "access-\(n)",
    accessTokenExpiresAt: now.addingTimeInterval(expiresIn),
    refreshToken: "refresh-\(n)",
    refreshTokenExpiresAt: now.addingTimeInterval(30 * 86_400)
  )
}

/// The server's response with session `n`.
func tokenPair(_ n: Int) -> (HTTPResponse, HTTPBody?) {
  let milliseconds = { (date: Date) in Int(date.timeIntervalSince1970 * 1000) }
  let session = session(n)
  return (
    HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
    HTTPBody(
      """
      {"accessToken":"\(session.accessToken)",\
      "accessTokenExpiresAt":\(milliseconds(session.accessTokenExpiresAt)),\
      "refreshToken":"\(session.refreshToken)",\
      "refreshTokenExpiresAt":\(milliseconds(session.refreshTokenExpiresAt))}
      """
    )
  )
}

func string(_ body: HTTPBody?) async throws -> String {
  guard let body else { return "" }
  return try await String(collecting: body, upTo: 1 << 20)
}

/// A store holding session 1 whose first `failures` reads fail.
func failingFirst(_ failures: Int, reads: LockIsolated<Int>) -> SessionStore {
  SessionStore(
    load: {
      reads.withValue { $0 += 1 }
      if reads.value <= failures {
        throw SessionStore.KeychainError(status: errSecInteractionNotAllowed)
      }
      return session(1)
    },
    save: { _ in })
}

/// Sessions starting from `stored`, talking to a server that answers with `respond`.
func makeSessions(
  stored: AuthSession?,
  respond: @escaping @Sendable (HTTPRequest, HTTPBody?) async throws -> (HTTPResponse, HTTPBody?)
) -> (AuthSessions, SessionStore) {
  let store = SessionStore.inMemory(stored)
  let sessions = withDependencies {
    $0.sessionStore = store
    $0.api = Client.mock(respond)
    $0.date.now = now
  } operation: {
    AuthSessions()
  }
  return (sessions, store)
}
