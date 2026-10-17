public import ComposableArchitecture
public import Foundation
import LilAPI

/// Signing in with Apple (the stock button) or Google (in the browser), then exchanging the
/// provider's token for a session.
@Reducer
public struct SignInFeature {
  @ObservableState
  public struct State: Equatable {
    public var status: Status
    /// The raw nonce for the sign-in in progress. Apple gets its SHA-256 (``nonceHash``) and the
    /// server the nonce, which ties Apple's token to this sign-in.
    public var nonce: String?

    public enum Status: Equatable {
      case signedOut
      case signingIn
      case failed(String)
      case signedIn
    }

    /// The name from Apple's first authorization. Apple only gives it once, so it's kept for
    /// tries after a failed sign-in.
    public var givenName: String?
    public var familyName: String?

    /// The Google sign-in in the browser, while it's open.
    public var googleRequest: GoogleAuthorizationRequest?

    /// Whether the app has a Google OAuth client, so the Google button is shown.
    public var isGoogleAvailable: Bool

    /// Whether the app talks to a preview deployment, where it can sign in to a synthetic test
    /// account (`AuthClient.signInToTestAccount`).
    public var isTestAccountAvailable: Bool

    public init(
      status: Status = .signedOut, nonce: String? = nil,
      googleRequest: GoogleAuthorizationRequest? = nil
    ) {
      @Dependency(\.googleOAuth) var googleOAuth
      self.status = status
      self.nonce = nonce
      self.googleRequest = googleRequest
      self.isGoogleAvailable = googleOAuth.clientID != nil
      if case .preview = APIEnvironment.current() {
        self.isTestAccountAvailable = true
      } else {
        self.isTestAccountAvailable = false
      }
    }

    /// Starting another try clears the last one's error.
    mutating func clearFailure() {
      if case .failed = status { status = .signedOut }
    }

    /// What the Apple request's `nonce` is set to.
    public var nonceHash: String? {
      nonce.map(Nonce.sha256Hex)
    }
  }

  public enum Action {
    /// The Apple button was tapped, just before Apple's sheet appears.
    case appleButtonTapped
    case appleAuthorizationFinished(Result<AppleCredential, AppleAuthorizationError>)
    case googleButtonTapped
    /// Signs in to the synthetic account shared by test devices, on a preview deployment.
    case testAccountButtonTapped
    /// The browser came back with Google's redirect.
    case googleAuthorizationFinished(Result<URL, GoogleAuthorizationError>)
    case signInSucceeded
    case signInFailed(SignInError)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case signedIn
    }
  }

  public enum AppleAuthorizationError: Error, Equatable {
    /// The person closed Apple's sheet.
    case canceled
    case failed(String)
  }

  enum CancelID { case google }

  /// The synthetic account test devices sign in to, so an iPhone and a Mac share it.
  public static let testAccount = "e2e"

  @Dependency(\.auth) var auth
  @Dependency(\.googleOAuth) var googleOAuth
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appleButtonTapped:
        state.clearFailure()
        state.nonce = withRandomNumberGenerator { Nonce.randomHex(bytes: 32, using: &$0) }
        return .none

      case .appleAuthorizationFinished(.success(var credential)):
        if credential.givenName != nil || credential.familyName != nil {
          state.givenName = credential.givenName
          state.familyName = credential.familyName
        } else {
          credential.givenName = state.givenName
          credential.familyName = state.familyName
        }
        guard let nonce = state.nonce else {
          state.status = .failed(SignInError.rejected.message)
          return .none
        }
        state.status = .signingIn
        return .run { [auth, credential] send in
          do throws(SignInError) {
            try await auth.signInWithApple(credential, nonce)
            await send(.signInSucceeded)
          } catch {
            await send(.signInFailed(error))
          }
        }

      case .appleAuthorizationFinished(.failure(.canceled)):
        state.nonce = nil
        return .none

      case .appleAuthorizationFinished(.failure(.failed(let reason))):
        state.nonce = nil
        state.status = .failed(SignInError.failed(reason).message)
        return .none

      case .googleButtonTapped:
        guard let clientID = googleOAuth.clientID else {
          reportIssue("No Google OAuth client ID: set GIDClientID in the app's Info.plist")
          state.status = .failed(SignInError.unavailable.message)
          return .none
        }
        state.clearFailure()
        let request = withRandomNumberGenerator { generator in
          GoogleAuthorizationRequest.make(clientID: clientID, using: &generator)
        }
        state.googleRequest = request
        return .run { [googleOAuth] send in
          await send(.googleAuthorizationFinished(await googleOAuth.authorize(request)))
        }
        .cancellable(id: CancelID.google, cancelInFlight: true)

      case .testAccountButtonTapped:
        state.clearFailure()
        state.status = .signingIn
        return .run { [auth] send in
          do throws(SignInError) {
            try await auth.signInToTestAccount(SignInFeature.testAccount)
            await send(.signInSucceeded)
          } catch {
            await send(.signInFailed(error))
          }
        }

      case .googleAuthorizationFinished(.success(let callback)):
        guard let request = state.googleRequest else { return .none }
        state.googleRequest = nil
        let code: String
        do throws(GoogleAuthorizationError) {
          code = try request.code(from: callback)
        } catch {
          switch error {
          case .canceled: break
          case .failed(let reason): state.status = .failed(SignInError.failed(reason).message)
          }
          return .none
        }
        state.status = .signingIn
        return .run { [auth, googleOAuth] send in
          do throws(SignInError) {
            let idToken: String
            do {
              idToken = try await googleOAuth.redeem(code, request)
            } catch {
              throw .failed(error.localizedDescription)
            }
            try await auth.signInWithGoogle(idToken, request.nonce)
            await send(.signInSucceeded)
          } catch {
            await send(.signInFailed(error))
          }
        }

      case .googleAuthorizationFinished(.failure(.canceled)):
        state.googleRequest = nil
        return .none

      case .googleAuthorizationFinished(.failure(.failed(let reason))):
        state.googleRequest = nil
        state.status = .failed(SignInError.failed(reason).message)
        return .none

      case .signInSucceeded:
        state.nonce = nil
        state.givenName = nil
        state.familyName = nil
        state.status = .signedIn
        return .send(.delegate(.signedIn))

      case .signInFailed(let error):
        state.nonce = nil
        state.status = .failed(error.message)
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
