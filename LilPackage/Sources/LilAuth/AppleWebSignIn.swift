public import Dependencies
public import Foundation

/// One Sign in with Apple through Apple's web page, for the Mac: a Developer ID–distributed app
/// can't use the native sheet (`docs/DECISIONS.md`). Apple posts the result to the API's return
/// URL, which redirects to `callbackScheme` with it.
public struct AppleWebAuthorizationRequest: Equatable, Sendable {
  /// The Services ID, grouped under the `tech.lil.health` App ID, so the Apple user ID is the
  /// iPhone's.
  public static let servicesID = "tech.lil.health.web"
  /// Where the API's return URL sends Apple's answer (`tech.lil.health://apple-signin`).
  public static let callbackScheme = "tech.lil.health"

  /// The API's return URL, registered with Apple for the Services ID.
  public let redirectURI: URL
  /// The raw nonce. Apple puts its SHA-256 in the identity token, and the server gets the nonce.
  public let nonce: String
  /// Ties Apple's answer to this request.
  public let state: String

  public init(redirectURI: URL, nonce: String, state: String) {
    self.redirectURI = redirectURI
    self.nonce = nonce
    self.state = state
  }

  /// Apple's sign-in page for this request. Asking for the name and email needs `form_post`.
  public var url: URL {
    var components = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: Self.servicesID),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "response_type", value: "code id_token"),
      URLQueryItem(name: "response_mode", value: "form_post"),
      URLQueryItem(name: "scope", value: "name email"),
      URLQueryItem(name: "nonce", value: Nonce.sha256Hex(nonce)),
      URLQueryItem(name: "state", value: state),
    ]
    return components.url!
  }

  /// The identity token and authorization code, and the name Apple gives with the first sign-in,
  /// from Apple's answer as the API's return URL passes it on.
  public func credential(
    from callback: URL
  ) throws(SignInFeature.AppleAuthorizationError) -> AppleCredential {
    let query = CallbackQuery(callback)
    let value = { (name: String) in query[name] }
    if let error = value("error") {
      throw error == "user_cancelled_authorize" ? .canceled : .failed("Apple answered \(error)")
    }
    guard value("state") == state else { throw .failed("Apple's answer didn't match") }
    guard let token = value("id_token"), !token.isEmpty else {
      throw .failed("Apple didn't return an identity token")
    }
    struct User: Decodable {
      struct Name: Decodable {
        let firstName: String?
        let lastName: String?
      }
      let name: Name?
    }
    // Apple only gives the name once, so one that can't be read is worth hearing about.
    var name: User.Name?
    if let user = value("user") {
      do {
        name = try JSONDecoder().decode(User.self, from: Data(user.utf8)).name
      } catch {
        reportIssue(error, "Apple's name couldn't be read")
      }
    }
    return AppleCredential(
      identityToken: token, authorizationCode: AppleCredential.authorizationCode(value("code")),
      givenName: name?.firstName, familyName: name?.lastName)
  }

  /// A request with fresh random secrets, for the API at `api`.
  public static func make(api: URL, using generator: inout some RandomNumberGenerator) -> Self {
    Self(
      redirectURI: api.appending(path: "v1/auth/apple/web"),
      nonce: Nonce.randomHex(bytes: 32, using: &generator),
      state: Nonce.randomHex(bytes: 16, using: &generator)
    )
  }
}

extension DependencyValues {
  /// Apple's web page for Sign in with Apple, on the Mac.
  public var appleWebSignIn: AppleWebSignIn {
    get { self[AppleWebSignIn.self] }
    set { self[AppleWebSignIn.self] = newValue }
  }
}

/// Shows Apple's sign-in page in a browser sheet until the API's return URL redirects back.
public struct AppleWebSignIn: Sendable {
  public var authorize:
    @Sendable (_ request: AppleWebAuthorizationRequest) async -> Result<
      URL, SignInFeature.AppleAuthorizationError
    >

  public init(
    authorize:
      @escaping @Sendable (_ request: AppleWebAuthorizationRequest) async -> Result<
        URL, SignInFeature.AppleAuthorizationError
      >
  ) {
    self.authorize = authorize
  }
}

extension AppleWebSignIn: DependencyKey {
  public static var liveValue: Self {
    Self { request in
      await openInBrowser(
        request.url, until: AppleWebAuthorizationRequest.callbackScheme, service: "Apple"
      ).mapError {
        switch $0 {
        case .canceled: .canceled
        case .failed(let reason): .failed(reason)
        }
      }
    }
  }

  public static var testValue: Self {
    Self { _ in
      reportIssue("Unimplemented: @Dependency(\\.appleWebSignIn).authorize")
      return .failure(.canceled)
    }
  }

  /// Apple's page stays "open": previews show the state without opening a browser.
  public static var previewValue: Self {
    Self { _ in
      while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
      return .failure(.canceled)
    }
  }
}
