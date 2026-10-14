import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import LilAPI
import OpenAPIRuntime
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
  func signingOutForgetsTheSessionEvenIfTheServerFails() async throws {
    let calls = LockIsolated<[String?]>([])
    let (sessions, store) = makeSessions(stored: session(1)) { request, _ in
      calls.withValue { $0.append(request.path) }
      return (HTTPResponse(status: .internalServerError), nil)
    }
    var updates = await sessions.signedInUpdates().makeAsyncIterator()
    #expect(await updates.next() == true)
    await sessions.signOut()
    #expect(await updates.next() == false)
    #expect(calls.value == ["/v1/auth/sign-out"])
    #expect(try store.load() == nil)
    #expect(try await sessions.accessToken() == nil)
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
