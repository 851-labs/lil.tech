import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import LilAPI
import OpenAPIRuntime
import Testing

@testable import LilAuth

struct AuthClientTests {
  @Test
  func signingInWithAppleStartsASession() async throws {
    let (auth, store) = makeAuth { request, body in
      #expect(request.path == "/v1/auth/apple")
      let sent = try JSONDecoder().decode(
        Components.Schemas.AppleSignInRequest.self, from: Data(try await string(body).utf8))
      #expect(sent.identityToken == "apple-token")
      #expect(sent.nonce == "raw-nonce")
      #expect(sent.authorizationCode == "apple-code")
      #expect(sent.fullName?.givenName == "Ada")
      #expect(sent.device.app == "test")
      #expect(sent.device.platform == .macos)
      return tokenPair(1)
    }
    try await auth.signInWithApple(
      AppleCredential(
        identityToken: "apple-token", authorizationCode: "apple-code", givenName: "Ada"),
      "raw-nonce")
    #expect(try store.load() == session(1))
  }

  /// An app that opened signed in (a scripted run whose session outlived the last) stays signed
  /// out once it signs out, rather than signing straight back in to the test account (851-3096).
  @Test
  func signingOutSpendsTheScriptedSignIn() async throws {
    let launchSignIn = LaunchSignIn.once(true)
    let (auth, store) = makeAuth(launchSignIn: launchSignIn) { _, _ in
      Issue.record("No session, so the server isn't told")
      return (HTTPResponse(status: .noContent), nil)
    }
    await auth.signOut()
    #expect(try store.load() == nil)
    #expect(!launchSignIn.claim())
  }

  @Test
  func unusableAuthorizationCodesAreLeftOut() {
    #expect(AppleCredential.authorizationCode("c0de") == "c0de")
    #expect(AppleCredential.authorizationCode(Data("c0de".utf8)) == "c0de")
    #expect(AppleCredential.authorizationCode(nil as String?) == nil)
    #expect(AppleCredential.authorizationCode(nil as Data?) == nil)
    #expect(AppleCredential.authorizationCode("") == nil)
    #expect(AppleCredential.authorizationCode(String(repeating: "c", count: 1025)) == nil)
    withKnownIssue {
      #expect(AppleCredential.authorizationCode(Data([0xFF, 0xFE])) == nil)
    }
  }

  @Test
  func signingInWithGoogleStartsASession() async throws {
    let (auth, store) = makeAuth { request, body in
      #expect(request.path == "/v1/auth/google")
      let sent = try JSONDecoder().decode(
        Components.Schemas.GoogleSignInRequest.self, from: Data(try await string(body).utf8))
      #expect(sent.idToken == "google-id-token")
      #expect(sent.nonce == "raw-nonce")
      #expect(sent.device.app == "test")
      return tokenPair(1)
    }
    try await auth.signInWithGoogle("google-id-token", "raw-nonce")
    #expect(try store.load() == session(1))
  }

  @Test
  func googleBeforeItsSetUpSaysTryLater() async throws {
    let (auth, _) = makeAuth { _, _ in
      (
        HTTPResponse(status: .serviceUnavailable, headerFields: [.contentType: "application/json"]),
        HTTPBody(#"{"_tag":"SignInUnavailable","message":"Try again later"}"#)
      )
    }
    await #expect(throws: SignInError.unavailable) {
      try await auth.signInWithGoogle("google-id-token", "raw-nonce")
    }
  }

  @Test
  func aRejectedAppleTokenFails() async throws {
    let (auth, store) = makeAuth { _, _ in
      (
        HTTPResponse(status: .unauthorized, headerFields: [.contentType: "application/json"]),
        HTTPBody(#"{"_tag":"InvalidIdentityToken","message":"Invalid identity token"}"#)
      )
    }
    await #expect(throws: SignInError.rejected) {
      try await auth.signInWithApple(AppleCredential(identityToken: "apple-token"), "raw-nonce")
    }
    #expect(try store.load() == nil)
  }

  @Test
  func aNewAccountFromMainlandChinaIsRefused() async throws {
    let (auth, store) = makeAuth { _, _ in
      (
        HTTPResponse(
          status: .init(code: 451), headerFields: [.contentType: "application/json"]),
        HTTPBody(
          #"{"_tag":"SignUpUnavailableInRegion","message":"New accounts can't be created in your country or region"}"#
        )
      )
    }
    await #expect(throws: SignInError.signUpUnavailableInRegion) {
      try await auth.signInWithApple(AppleCredential(identityToken: "apple-token"), "raw-nonce")
    }
    await #expect(throws: SignInError.signUpUnavailableInRegion) {
      try await auth.signInWithGoogle("google-id-token", "raw-nonce")
    }
    #expect(try store.load() == nil)
  }

  @Test
  func anOutageSaysTryLater() async throws {
    let (auth, _) = makeAuth { _, _ in
      (
        HTTPResponse(status: .serviceUnavailable, headerFields: [.contentType: "application/json"]),
        HTTPBody(#"{"_tag":"SignInUnavailable","message":"Try again later"}"#)
      )
    }
    await #expect(throws: SignInError.unavailable) {
      try await auth.signInWithApple(AppleCredential(identityToken: "apple-token"), "raw-nonce")
    }
  }

  @Test
  func deletingTheAccountForgetsTheSession() async throws {
    let (auth, store) = makeAuth(stored: session(1)) { request, _ in
      #expect(request.method == .delete)
      #expect(request.path == "/v1/me")
      return (HTTPResponse(status: .noContent), nil)
    }
    try await auth.deleteAccount()
    #expect(try store.load() == nil)
  }

  @Test
  func aRejectedSessionIsntTakenForADeletion() async throws {
    let (auth, store) = makeAuth(stored: session(1)) { _, _ in
      (
        HTTPResponse(status: .unauthorized, headerFields: [.contentType: "application/json"]),
        HTTPBody(#"{"_tag":"Unauthorized","message":"Invalid access token"}"#)
      )
    }
    await #expect(throws: AccountDeletionError.signedOut) { try await auth.deleteAccount() }
    // Not forgotten here: the session's own refresh decides whether it's still good.
    #expect(try store.load() == session(1))
  }

  @Test
  func anUnavailableDeletionKeepsTheSession() async throws {
    let (auth, store) = makeAuth(stored: session(1)) { _, _ in
      (
        HTTPResponse(status: .serviceUnavailable, headerFields: [.contentType: "application/json"]),
        HTTPBody(#"{"_tag":"UserStoreUnavailable","message":"Try again"}"#)
      )
    }
    await #expect(throws: AccountDeletionError.unavailable) { try await auth.deleteAccount() }
    #expect(try store.load() == session(1))
  }

  /// A server too slow to answer isn't the device being offline.
  @Test
  func aTimedOutDeletionIsntOffline() async throws {
    let (auth, _) = makeAuth(stored: session(1)) { _, _ in throw URLError(.timedOut) }
    await #expect(throws: AccountDeletionError.unavailable) { try await auth.deleteAccount() }
    let (offline, _) = makeAuth(stored: session(1)) { _, _ in
      throw URLError(.notConnectedToInternet)
    }
    await #expect(throws: AccountDeletionError.offline) { try await offline.deleteAccount() }
    let (cancelled, _) = makeAuth(stored: session(1)) { _, _ in throw URLError(.cancelled) }
    await #expect(throws: AccountDeletionError.failed) { try await cancelled.deleteAccount() }
  }
}

/// The live client, signed in as `stored` (or signed out), talking to a server that answers
/// with `respond`.
private func makeAuth(
  stored: AuthSession? = nil,
  launchSignIn: LaunchSignIn = .testValue,
  respond: @escaping @Sendable (HTTPRequest, HTTPBody?) async throws -> (HTTPResponse, HTTPBody?)
) -> (AuthClient, SessionStore) {
  let store = SessionStore.inMemory(stored)
  let auth = withDependencies {
    $0.sessionStore = store
    $0.api = Client.mock(respond)
    $0.date.now = now
    $0.launchSignIn = launchSignIn
  } operation: {
    withDependencies {
      $0.authSessions = AuthSessions()
    } operation: {
      AuthClient.liveValue
    }
  }
  return (auth, store)
}
