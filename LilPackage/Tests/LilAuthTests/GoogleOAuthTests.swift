import Foundation
import Testing

@testable import LilAuth

struct GoogleOAuthTests {
  let request = GoogleAuthorizationRequest(
    clientID: "123-abc.apps.googleusercontent.com",
    codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
    nonce: "raw-nonce",
    state: "state-1"
  )

  @Test
  func codeChallengeMatchesRFC7636() {
    #expect(
      GoogleAuthorizationRequest.codeChallenge(for: request.codeVerifier)
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test
  func redirectsToTheReversedClientID() {
    #expect(request.callbackScheme == "com.googleusercontent.apps.123-abc")
    #expect(request.redirectURI == "com.googleusercontent.apps.123-abc:/oauth2redirect")
  }

  @Test
  func authorizationURL() throws {
    let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
    #expect(components.host == "accounts.google.com")
    #expect(components.path == "/o/oauth2/v2/auth")
    let items = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(
      items == [
        "client_id": "123-abc.apps.googleusercontent.com",
        "redirect_uri": "com.googleusercontent.apps.123-abc:/oauth2redirect",
        "response_type": "code",
        "scope": "openid email profile",
        "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "code_challenge_method": "S256",
        // Google gets the nonce's SHA-256, like Apple.
        "nonce": GoogleAuthorizationRequest.sha256Hex("raw-nonce"),
        "state": "state-1",
        "prompt": "select_account",
      ])
  }

  @Test
  func readsTheCodeFromTheRedirect() throws {
    let callback = URL(
      string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=state-1&code=4%2Fabc")!
    #expect(try request.code(from: callback) == "4/abc")
  }

  @Test
  func rejectsARedirectForAnotherRequest() {
    let callback = URL(
      string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=state-2&code=abc")!
    #expect(throws: GoogleAuthorizationError.failed("Google's answer didn't match")) {
      try request.code(from: callback)
    }
  }

  @Test
  func decliningIsCanceling() {
    let callback = URL(
      string: "com.googleusercontent.apps.123-abc:/oauth2redirect?error=access_denied&state=state-1"
    )!
    #expect(throws: GoogleAuthorizationError.canceled) { try request.code(from: callback) }
  }

  @Test
  func tokenRequest() throws {
    let tokenRequest = request.tokenRequest(code: "4/abc")
    #expect(tokenRequest.url?.absoluteString == "https://oauth2.googleapis.com/token")
    #expect(tokenRequest.httpMethod == "POST")
    #expect(
      tokenRequest.value(forHTTPHeaderField: "Content-Type")
        == "application/x-www-form-urlencoded")
    let body = String(decoding: try #require(tokenRequest.httpBody), as: UTF8.self)
    #expect(
      body
        == "grant_type=authorization_code&code=4%2Fabc"
        + "&client_id=123-abc.apps.googleusercontent.com"
        + "&redirect_uri=com.googleusercontent.apps.123-abc%3A%2Foauth2redirect"
        + "&code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  }

  @Test
  func freshRequestsUseTheGenerator() {
    var generator = Zeros()
    let request = GoogleAuthorizationRequest.make(clientID: "id", using: &generator)
    #expect(request.codeVerifier == String(repeating: "A", count: 43))
    #expect(request.nonce == String(repeating: "0", count: 64))
    #expect(request.state == String(repeating: "0", count: 32))
  }
}

/// Always zero, so random values are predictable.
struct Zeros: RandomNumberGenerator {
  mutating func next() -> UInt64 { 0 }
}
