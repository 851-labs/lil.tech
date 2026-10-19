public import ComposableArchitecture
public import Foundation
import LilAPI

/// What a provider gave to prove who someone is, with the raw nonce it's bound to (the provider
/// got the nonce's SHA-256, the server gets the nonce).
public enum ProviderCredential: Equatable, Sendable {
  case apple(AppleCredential, nonce: String)
  case google(idToken: String, nonce: String)
}

/// Getting a provider's proof of who someone is: Apple's native sheet (the iPhone) or web page (the
/// Mac), or Google's page in the browser. It ends with a credential, which the parent uses to sign
/// in (`SignInFeature`) or to link an account (`SignInMethodsFeature`).
@Reducer
public struct ProviderAuthorization {
  @ObservableState
  public struct State: Equatable {
    /// The raw nonce for the Apple authorization in progress. Apple gets its SHA-256
    /// (``nonceHash``) and the server the nonce, which ties Apple's token to this request.
    public var nonce: String?
    /// The Google sign-in in the browser, while it's open.
    public var googleRequest: GoogleAuthorizationRequest?
    /// The Apple sign-in in the browser, while it's open (the Mac).
    public var appleWebRequest: AppleWebAuthorizationRequest?
    /// Whether the app has a Google OAuth client, so Google is offered.
    public var isGoogleAvailable: Bool
    /// The API that Apple's web sign-in returns through, on the Mac
    /// (`AppleWebAuthorizationRequest`). `nil` on the iPhone and for a preview deployment.
    public var appleWebAPI: URL?
    /// The name from Apple's first authorization. Apple only gives it once, so it's kept for
    /// tries after a failed one, until ``forgetName()``.
    public var givenName: String?
    public var familyName: String?

    public init() {
      @Dependency(\.googleOAuth) var googleOAuth
      self.isGoogleAvailable = googleOAuth.clientID != nil
      self.appleWebAPI = AppleWebAuthorizationRequest.api(for: APIEnvironment.current())
    }

    /// What the Apple request's `nonce` is set to.
    public var nonceHash: String? {
      nonce.map(Nonce.sha256Hex)
    }

    /// Whether a browser page is open.
    public var isBrowserOpen: Bool {
      googleRequest != nil || appleWebRequest != nil
    }

    /// Forgets Apple's name, once it has reached the server.
    public mutating func forgetName() {
      givenName = nil
      familyName = nil
    }

    /// Closes any browser page (with ``cancel()``'s effect).
    public mutating func close() {
      googleRequest = nil
      appleWebRequest = nil
    }
  }

  public enum Action {
    /// The iPhone's Apple button was tapped, just before Apple's sheet appears.
    case appleButtonTapped
    case appleAuthorizationFinished(Result<AppleCredential, AppleAuthorizationError>)
    /// The Mac's Apple button: Apple's web page, in the browser.
    case appleWebButtonTapped
    /// The browser came back from Apple's web page, through the API's return URL.
    case appleWebAuthorizationFinished(Result<URL, AppleAuthorizationError>)
    case googleButtonTapped
    /// The browser came back with Google's redirect.
    case googleAuthorizationFinished(Result<URL, GoogleAuthorizationError>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      /// Google answered, and its code is being redeemed for the ID token.
      case redeemingGoogle
      case authorized(ProviderCredential)
      /// The person closed the provider's sheet or page.
      case canceled
      case failed(AuthorizationFailure)
    }
  }

  public enum AppleAuthorizationError: Error, Equatable, Sendable {
    /// The person closed Apple's sheet.
    case canceled
    case failed(String)
  }

  /// Why getting a credential didn't work, for the parent to word.
  public enum AuthorizationFailure: Equatable, Sendable {
    /// The app can't use this provider (e.g. no Google OAuth client).
    case unavailable
    /// Apple answered without a request in progress, so its token can't be tied to one.
    case rejected
    case failed(String)
  }

  enum CancelID { case google, appleWeb }

  /// Closes any browser page that's open (with ``State/close()``).
  public static func cancel<Action>() -> Effect<Action> {
    .merge(.cancel(id: CancelID.google), .cancel(id: CancelID.appleWeb))
  }

  @Dependency(\.appleWebSignIn) var appleWebSignIn
  @Dependency(\.googleOAuth) var googleOAuth
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appleButtonTapped:
        state.nonce = withRandomNumberGenerator { Nonce.randomHex(bytes: 32, using: &$0) }
        return .none

      case .appleAuthorizationFinished(let result):
        return finishApple(result, &state)

      case .appleWebButtonTapped:
        guard let api = state.appleWebAPI else { return .none }
        let request = withRandomNumberGenerator {
          AppleWebAuthorizationRequest.make(api: api, using: &$0)
        }
        // Kept where the native sheet keeps it, so both finish the same way.
        state.nonce = request.nonce
        state.appleWebRequest = request
        return .run { [appleWebSignIn] send in
          await send(.appleWebAuthorizationFinished(await appleWebSignIn.authorize(request)))
        }
        .cancellable(id: CancelID.appleWeb, cancelInFlight: true)

      case .appleWebAuthorizationFinished(let result):
        // Gone by the time the browser answered (e.g. closed for the test account).
        guard let request = state.appleWebRequest else {
          state.nonce = nil
          return .send(.delegate(.canceled))
        }
        state.appleWebRequest = nil
        return finishApple(
          result.flatMap { callback in
            Result { () throws(AppleAuthorizationError) in try request.credential(from: callback) }
          },
          &state)

      case .googleButtonTapped:
        guard let clientID = googleOAuth.clientID else {
          reportIssue("No Google OAuth client ID: set GIDClientID in the app's Info.plist")
          return .send(.delegate(.failed(.unavailable)))
        }
        let request = withRandomNumberGenerator { generator in
          GoogleAuthorizationRequest.make(clientID: clientID, using: &generator)
        }
        state.googleRequest = request
        return .run { [googleOAuth] send in
          await send(.googleAuthorizationFinished(await googleOAuth.authorize(request)))
        }
        .cancellable(id: CancelID.google, cancelInFlight: true)

      case .googleAuthorizationFinished(let result):
        guard let request = state.googleRequest else { return .send(.delegate(.canceled)) }
        state.googleRequest = nil
        let code: String
        do throws(GoogleAuthorizationError) {
          code = try request.code(from: result.get())
        } catch {
          switch error {
          case .canceled: return .send(.delegate(.canceled))
          case .failed(let reason): return .send(.delegate(.failed(.failed(reason))))
          }
        }
        return .run { [googleOAuth] send in
          await send(.delegate(.redeemingGoogle))
          do {
            let idToken = try await googleOAuth.redeem(code, request)
            await send(.delegate(.authorized(.google(idToken: idToken, nonce: request.nonce))))
          } catch {
            await send(.delegate(.failed(.failed(error.localizedDescription))))
          }
        }
        // Closing (`cancel()`) stops a redemption too.
        .cancellable(id: CancelID.google)

      case .delegate:
        return .none
      }
    }
  }

  /// Apple's answer, from the native sheet (the iPhone) or Apple's web page (the Mac), with the
  /// nonce kept for the request and the name kept from the first authorization.
  private func finishApple(
    _ result: Result<AppleCredential, AppleAuthorizationError>, _ state: inout State
  ) -> Effect<Action> {
    let nonce = state.nonce
    state.nonce = nil
    switch result {
    case .success(var credential):
      if credential.givenName != nil || credential.familyName != nil {
        state.givenName = credential.givenName
        state.familyName = credential.familyName
      } else {
        credential.givenName = state.givenName
        credential.familyName = state.familyName
      }
      guard let nonce else { return .send(.delegate(.failed(.rejected))) }
      return .send(.delegate(.authorized(.apple(credential, nonce: nonce))))
    case .failure(.canceled):
      return .send(.delegate(.canceled))
    case .failure(.failed(let reason)):
      return .send(.delegate(.failed(.failed(reason))))
    }
  }
}
