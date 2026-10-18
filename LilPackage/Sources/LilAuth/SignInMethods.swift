public import Dependencies
import Foundation
import IssueReporting
public import LilAPI

/// A way to sign in to the account: an Apple or Google account linked to it.
public struct SignInMethod: Equatable, Identifiable, Sendable {
  public enum Provider: String, CaseIterable, Equatable, Sendable {
    case apple, google

    public var name: String {
      switch self {
      case .apple: "Apple"
      case .google: "Google"
      }
    }
  }

  public var id: String
  public var provider: Provider
  /// The provider account's email, if it shared one (Apple's may be a private relay address).
  public var email: String?

  public init(id: String, provider: Provider, email: String?) {
    self.id = id
    self.provider = provider
    self.email = email
  }

  /// `nil` for an identity without an ID, from a server before 851-2554.
  init?(_ identity: Components.Schemas.MeIdentity) {
    guard let id = identity.id else { return nil }
    let provider: Provider =
      switch identity.provider {
      case .apple: .apple
      case .google: .google
      }
    self.init(id: id, provider: provider, email: identity.email)
  }
}

/// Why listing, linking or unlinking a sign-in method didn't work, worded for account settings.
public enum SignInMethodError: Error, Equatable, Sendable {
  /// The provider account already signs in to another lil account. Accounts aren't merged.
  case inUse(SignInMethod.Provider)
  /// It's the account's only sign-in method.
  case lastMethod
  /// The server didn't accept the provider's token. Trying again usually works.
  case rejected
  /// The session ended (e.g. the account was deleted on another device).
  case signedOut
  /// It isn't possible right now; try again later.
  case unavailable
  case failed(String)

  public var message: String {
    switch self {
    case .inUse(let provider):
      "That \(provider.name) account already signs in to another lil account. Sign in with it to use that account, or delete that account first."
    case .lastMethod: "Your only sign-in method can't be removed."
    case .rejected: "Linking didn't work. Please try again."
    case .signedOut: "Your session ended. Sign in again."
    case .unavailable: "It isn't possible right now. Please try again later."
    case .failed(let reason): "Something went wrong: \(reason)"
    }
  }
}

/// The account's sign-in methods, from `GET /v1/me`, and linking and unlinking them
/// (`/v1/me/identities`).
public struct SignInMethodsClient: Sendable {
  /// The account's sign-in methods, oldest first.
  public var list: @Sendable () async throws(SignInMethodError) -> [SignInMethod]
  /// Links the Apple account Sign in with Apple answered with. `nonce` is the raw nonce whose
  /// SHA-256 the app gave Apple.
  public var linkApple:
    @Sendable (_ credential: AppleCredential, _ nonce: String) async throws(SignInMethodError) ->
      SignInMethod
  /// Links the Google account of Google's ID token. `nonce` is the raw nonce whose SHA-256 the app
  /// gave Google.
  public var linkGoogle:
    @Sendable (_ idToken: String, _ nonce: String) async throws(SignInMethodError) -> SignInMethod
  /// Unlinks a sign-in method, unless it's the account's last.
  public var unlink: @Sendable (_ id: SignInMethod.ID) async throws(SignInMethodError) -> Void

  public init(
    list: @escaping @Sendable () async throws(SignInMethodError) -> [SignInMethod],
    linkApple:
      @escaping @Sendable (_ credential: AppleCredential, _ nonce: String)
      async throws(SignInMethodError) -> SignInMethod,
    linkGoogle:
      @escaping @Sendable (_ idToken: String, _ nonce: String) async throws(SignInMethodError) ->
      SignInMethod,
    unlink: @escaping @Sendable (_ id: SignInMethod.ID) async throws(SignInMethodError) -> Void
  ) {
    self.list = list
    self.linkApple = linkApple
    self.linkGoogle = linkGoogle
    self.unlink = unlink
  }
}

extension SignInMethodsClient: DependencyKey {
  public static var liveValue: Self {
    @Dependency(\.api) var api
    /// Calls an endpoint, turning a failed request into ``SignInMethodError``.
    @Sendable func call<Output>(
      _ request: @Sendable () async throws -> Output
    ) async throws(SignInMethodError) -> Output {
      do {
        return try await request()
      } catch {
        throw .failed(error.localizedDescription)
      }
    }
    /// What a link endpoint's answer means.
    @Sendable func linked(
      _ provider: SignInMethod.Provider, _ outcome: LinkOutcome
    ) throws(SignInMethodError) -> SignInMethod {
      switch outcome {
      case .linked(let identity):
        guard let method = identity.flatMap(SignInMethod.init) else {
          throw .failed("Unexpected response")
        }
        return method
      case .rejected: throw .rejected
      case .signedOut: throw .signedOut
      case .inUse: throw .inUse(provider)
      case .unavailable: throw .unavailable
      case .unexpected(let statusCode): throw .failed("HTTP \(statusCode)")
      }
    }
    return Self(
      list: { () throws(SignInMethodError) in
        switch try await call({ try await api.me() }) {
        case .ok(let ok):
          guard let me = try? ok.body.json else { throw .failed("Unexpected response") }
          return me.identities.compactMap(SignInMethod.init)
        case .unauthorized: throw .signedOut
        case .tooManyRequests: throw .unavailable
        case .undocumented(let statusCode, _): throw .failed("HTTP \(statusCode)")
        }
      },
      linkApple: { credential, nonce throws(SignInMethodError) in
        let request = Components.Schemas.LinkAppleRequest(
          identityToken: credential.identityToken, nonce: nonce,
          authorizationCode: credential.authorizationCode)
        let outcome: LinkOutcome =
          switch try await call({ try await api.linkApple(body: .json(request)) }) {
          case .ok(let ok): .linked(try? ok.body.json)
          // The token didn't verify, or the session ended (the middleware's `Unauthorized`).
          case .unauthorized(let response):
            (try? response.body.json)?.value1 != nil ? .rejected : .signedOut
          case .conflict: .inUse
          case .serviceUnavailable, .tooManyRequests: .unavailable
          case .undocumented(let statusCode, _): .unexpected(statusCode)
          }
        return try linked(.apple, outcome)
      },
      linkGoogle: { idToken, nonce throws(SignInMethodError) in
        let request = Components.Schemas.LinkGoogleRequest(idToken: idToken, nonce: nonce)
        let outcome: LinkOutcome =
          switch try await call({ try await api.linkGoogle(body: .json(request)) }) {
          case .ok(let ok): .linked(try? ok.body.json)
          case .unauthorized(let response):
            (try? response.body.json)?.value1 != nil ? .rejected : .signedOut
          case .conflict: .inUse
          case .serviceUnavailable, .tooManyRequests: .unavailable
          case .undocumented(let statusCode, _): .unexpected(statusCode)
          }
        return try linked(.google, outcome)
      },
      unlink: { id throws(SignInMethodError) in
        switch try await call({ try await api.unlinkIdentity(path: .init(id: id)) }) {
        // Already gone counts as done: the list is loaded again either way.
        case .noContent, .notFound: return
        case .conflict: throw .lastMethod
        case .unauthorized: throw .signedOut
        case .tooManyRequests: throw .unavailable
        case .undocumented(let statusCode, _):
          throw statusCode >= 500 ? .unavailable : .failed("HTTP \(statusCode)")
        }
      }
    )
  }

  /// An account with Apple linked, where linking Google works.
  public static let previewValue = Self(
    list: { () throws(SignInMethodError) in
      [SignInMethod(id: "idt_apple", provider: .apple, email: "ada@privaterelay.appleid.com")]
    },
    linkApple: { _, _ throws(SignInMethodError) in
      SignInMethod(id: "idt_apple", provider: .apple, email: "ada@privaterelay.appleid.com")
    },
    linkGoogle: { _, _ throws(SignInMethodError) in
      SignInMethod(id: "idt_google", provider: .google, email: "ada@example.com")
    },
    unlink: { _ throws(SignInMethodError) in }
  )

  public static var testValue: Self {
    Self(
      list: { () throws(SignInMethodError) in
        reportIssue("Unimplemented: @Dependency(\\.signInMethods).list")
        return []
      },
      linkApple: { _, _ throws(SignInMethodError) in
        reportIssue("Unimplemented: @Dependency(\\.signInMethods).linkApple")
        throw .unavailable
      },
      linkGoogle: { _, _ throws(SignInMethodError) in
        reportIssue("Unimplemented: @Dependency(\\.signInMethods).linkGoogle")
        throw .unavailable
      },
      unlink: { _ throws(SignInMethodError) in
        reportIssue("Unimplemented: @Dependency(\\.signInMethods).unlink")
      }
    )
  }
}

/// How a link endpoint answered.
private enum LinkOutcome {
  case linked(Components.Schemas.MeIdentity?)
  case rejected
  case signedOut
  case inUse
  case unavailable
  case unexpected(Int)
}

extension DependencyValues {
  /// The account's sign-in methods.
  public var signInMethods: SignInMethodsClient {
    get { self[SignInMethodsClient.self] }
    set { self[SignInMethodsClient.self] = newValue }
  }
}
