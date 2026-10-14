public import ComposableArchitecture
import CryptoKit
public import Foundation

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

    public init(
      status: Status = .signedOut, nonce: String? = nil,
      googleRequest: GoogleAuthorizationRequest? = nil
    ) {
      self.status = status
      self.nonce = nonce
      self.googleRequest = googleRequest
    }

    /// What the Apple request's `nonce` is set to.
    public var nonceHash: String? {
      nonce.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
  }

  public enum Action {
    /// The Apple button was tapped, just before Apple's sheet appears.
    case appleButtonTapped
    case appleAuthorizationFinished(Result<AppleCredential, AppleAuthorizationError>)
    case googleButtonTapped
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

  @Dependency(\.auth) var auth
  @Dependency(\.googleOAuth) var googleOAuth
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appleButtonTapped:
        state.nonce = withRandomNumberGenerator { generator in
          (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
          }
          .joined()
        }
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
          state.status = .failed(SignInError.unavailable.message)
          return .none
        }
        state.googleRequest = withRandomNumberGenerator { generator in
          GoogleAuthorizationRequest.make(clientID: clientID, using: &generator)
        }
        return .none

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
