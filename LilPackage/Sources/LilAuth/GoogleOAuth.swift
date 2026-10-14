import CryptoKit
public import Dependencies
public import Foundation

/// One Google sign-in through the browser: OAuth's authorization code flow with PKCE, as Google
/// documents for iOS and macOS apps, without Google's SDK.
public struct GoogleAuthorizationRequest: Equatable, Sendable {
  /// The app's OAuth client ID (an iOS client, which macOS apps use too).
  public let clientID: String
  /// PKCE's secret: Google gets its SHA-256 now and the verifier itself with the code.
  public let codeVerifier: String
  /// The raw nonce. Google puts its SHA-256 in the ID token, and the server gets the nonce.
  public let nonce: String
  /// Ties the browser's answer to this request.
  public let state: String

  public init(clientID: String, codeVerifier: String, nonce: String, state: String) {
    self.clientID = clientID
    self.codeVerifier = codeVerifier
    self.nonce = nonce
    self.state = state
  }

  /// The client ID reversed, e.g. `com.googleusercontent.apps.123-abc`. Google redirects to it.
  public var callbackScheme: String {
    clientID.split(separator: ".").reversed().joined(separator: ".")
  }

  public var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

  /// Google's sign-in page for this request.
  public var url: URL {
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: "openid email profile"),
      URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "nonce", value: Nonce.sha256Hex(nonce)),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "prompt", value: "select_account"),
    ]
    return components.url!
  }

  /// The authorization code in Google's redirect.
  public func code(from callback: URL) throws(GoogleAuthorizationError) -> String {
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let value = { (name: String) in items.first { $0.name == name }?.value }
    if let error = value("error") {
      throw error == "access_denied" ? .canceled : .failed("Google answered \(error)")
    }
    guard value("state") == state else { throw .failed("Google's answer didn't match") }
    guard let code = value("code"), !code.isEmpty else {
      throw .failed("Google didn't return a code")
    }
    return code
  }

  /// Redeems `code` at Google's token endpoint. iOS clients have no secret: PKCE stands in.
  public func tokenRequest(code: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let form = [
      ("grant_type", "authorization_code"),
      ("code", code),
      ("client_id", clientID),
      ("redirect_uri", redirectURI),
      ("code_verifier", codeVerifier),
    ]
    request.httpBody = Data(
      form.map { "\($0)=\(Self.formEncoded($1))" }.joined(separator: "&").utf8)
    return request
  }

  /// A request with fresh random secrets.
  public static func make(
    clientID: String, using generator: inout some RandomNumberGenerator
  ) -> Self {
    let verifier = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Self(
      clientID: clientID,
      codeVerifier: base64URL(Data(verifier)),
      nonce: Nonce.randomHex(bytes: 32, using: &generator),
      state: Nonce.randomHex(bytes: 16, using: &generator)
    )
  }

  static func codeChallenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// Percent-encodes everything but OAuth's unreserved characters (ASCII only).
  private static func formEncoded(_ value: String) -> String {
    let unreserved = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
  }
}

/// Why the browser part of Google sign-in didn't finish.
public enum GoogleAuthorizationError: Error, Equatable, Sendable {
  /// The person closed the sheet or declined.
  case canceled
  case failed(String)
}

extension DependencyValues {
  /// The app's Google OAuth client and Google's token endpoint.
  public var googleOAuth: GoogleOAuth {
    get { self[GoogleOAuth.self] }
    set { self[GoogleOAuth.self] = newValue }
  }
}

/// Google's side of Google sign-in.
public struct GoogleOAuth: Sendable {
  /// The app's OAuth client ID, or `nil` if it has none (Google sign-in is then unavailable).
  public var clientID: String?
  /// Shows Google's sign-in page for `request` until Google redirects back with the result.
  public var authorize:
    @Sendable (_ request: GoogleAuthorizationRequest) async -> Result<URL, GoogleAuthorizationError>
  /// Redeems an authorization code for Google's ID token.
  public var redeem:
    @Sendable (_ code: String, _ request: GoogleAuthorizationRequest) async throws -> String

  public init(
    clientID: String?,
    authorize:
      @escaping @Sendable (_ request: GoogleAuthorizationRequest) async -> Result<
        URL, GoogleAuthorizationError
      >,
    redeem:
      @escaping @Sendable (_ code: String, _ request: GoogleAuthorizationRequest) async throws
      -> String
  ) {
    self.clientID = clientID
    self.authorize = authorize
    self.redeem = redeem
  }

  /// Google's token endpoint didn't redeem the code.
  struct RedeemFailed: LocalizedError {
    let statusCode: Int
    /// Google's `error` and `error_description`, e.g. `invalid_grant`.
    let error: String?
    let errorDescription: String?

    init(statusCode: Int, body: Data) {
      struct Body: Decodable {
        let error: String?
        let error_description: String?
      }
      let decoded = try? JSONDecoder().decode(Body.self, from: body)
      self.statusCode = statusCode
      self.error = decoded?.error
      self.errorDescription =
        "Google answered HTTP \(statusCode)"
        + [decoded?.error, decoded?.error_description].compactMap { $0 }.map { ": \($0)" }
        .joined()
    }
  }
}

extension GoogleOAuth: DependencyKey {
  /// The client ID from the app's Info.plist (`GIDClientID`, as Google's SDK names it).
  public static var liveValue: Self {
    Self(
      clientID: Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
      authorize: { request in await authorizeInBrowser(request) },
      redeem: { code, request in
        let (data, response) = try await URLSession.shared.data(
          for: request.tokenRequest(code: code))
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else { throw RedeemFailed(statusCode: statusCode, body: data) }
        struct Tokens: Decodable { let id_token: String }
        return try JSONDecoder().decode(Tokens.self, from: data).id_token
      }
    )
  }

  public static var testValue: Self {
    Self(
      clientID: nil,
      authorize: { _ in
        reportIssue("Unimplemented: @Dependency(\\.googleOAuth).authorize")
        return .failure(.canceled)
      },
      redeem: { _, _ in
        reportIssue("Unimplemented: @Dependency(\\.googleOAuth).redeem")
        return ""
      }
    )
  }

  /// Google's page stays "open": previews show the state without opening a browser.
  public static var previewValue: Self {
    Self(
      clientID: "preview.apps.googleusercontent.com",
      authorize: { _ in
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
        return .failure(.canceled)
      },
      redeem: { _, _ in "" }
    )
  }
}
