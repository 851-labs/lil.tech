public import ComposableArchitecture
import CryptoKit
import Foundation

/// Signing in with Apple: the stock button, then exchanging Apple's token for a session.
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

    public init(status: Status = .signedOut, nonce: String? = nil) {
      self.status = status
      self.nonce = nonce
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

      case .appleAuthorizationFinished(.success(let credential)):
        guard let nonce = state.nonce else {
          state.status = .failed(SignInError.rejected.message)
          return .none
        }
        state.status = .signingIn
        return .run { [auth] send in
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

      case .signInSucceeded:
        state.nonce = nil
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
