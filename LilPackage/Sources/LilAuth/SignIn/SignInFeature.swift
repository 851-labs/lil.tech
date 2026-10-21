public import ComposableArchitecture
import Foundation
import LilAPI

/// Signing in with Apple (the stock button) or Google (in the browser), then exchanging the
/// provider's token for a session. Getting the provider's token is `ProviderAuthorization`'s job,
/// shared with linking (`SignInMethodsFeature`).
@Reducer
public struct SignInFeature {
  @ObservableState
  public struct State: Equatable {
    public var status: Status
    /// The provider flows: Apple's sheet or page, and Google's page.
    public var authorization = ProviderAuthorization.State(owner: "sign-in")

    public enum Status: Equatable {
      case signedOut
      case signingIn
      case failed(String)
      case signedIn
    }

    /// Whether the app talks to a preview deployment, where it can sign in to a synthetic test
    /// account (`AuthClient.signInToTestAccount`).
    public var isTestAccountAvailable: Bool

    public init(status: Status = .signedOut) {
      self.status = status
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
  }

  public enum Action {
    case authorization(ProviderAuthorization.Action)
    /// Signs in to the synthetic account shared by test devices, on a preview deployment.
    case testAccountButtonTapped
    /// The app is signed out, with the last account's data gone, e.g. once it opens. On a
    /// scripted run, it signs in to the test account (`LaunchSignIn`).
    case readyToSignIn
    case signInSucceeded
    case signInFailed(SignInError)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case signedIn
    }
  }

  /// The synthetic account test devices sign in to, so an iPhone and a Mac share it.
  public static let testAccount = "e2e"

  @Dependency(\.auth) var auth
  @Dependency(\.launchSignIn) var launchSignIn

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(\.authorization, action: \.authorization) {
      ProviderAuthorization()
    }
    Reduce { state, action in
      switch action {
      case .authorization(.delegate(.started)):
        state.clearFailure()
        return .none

      case .authorization(.delegate(.redeemingGoogle)):
        state.status = .signingIn
        return .none

      case .authorization(.delegate(.authorized(let credential))):
        state.status = .signingIn
        return .run { [auth] send in
          do throws(SignInError) {
            switch credential {
            case .apple(let credential, let nonce):
              try await auth.signInWithApple(credential, nonce)
            case .google(let idToken, let nonce):
              try await auth.signInWithGoogle(idToken, nonce)
            }
            await send(.signInSucceeded)
          } catch {
            await send(.signInFailed(error))
          }
        }

      case .authorization(.delegate(.canceled)):
        return .none

      case .authorization(.delegate(.failed(_, let failure))):
        state.status = .failed(SignInError(failure).message)
        return .none

      case .authorization:
        return .none

      case .readyToSignIn:
        guard state.isTestAccountAvailable, state.status == .signedOut, launchSignIn.claim()
        else { return .none }
        return signInToTestAccount(&state)

      case .testAccountButtonTapped:
        return signInToTestAccount(&state)

      case .signInSucceeded:
        state.authorization.forgetName()
        state.status = .signedIn
        return .send(.delegate(.signedIn))

      case .signInFailed(let error):
        state.status = .failed(error.message)
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func signInToTestAccount(_ state: inout State) -> Effect<Action> {
    state.status = .signingIn
    return .merge(
      // Instead of a Google or Apple sign-in still open in the browser.
      .send(.authorization(.close)),
      .run { [auth] send in
        do throws(SignInError) {
          try await auth.signInToTestAccount(SignInFeature.testAccount)
          await send(.signInSucceeded)
        } catch {
          await send(.signInFailed(error))
        }
      }
    )
  }
}

extension SignInError {
  init(_ failure: ProviderAuthorization.AuthorizationFailure) {
    switch failure {
    case .unavailable: self = .unavailable
    case .rejected: self = .rejected
    case .failed(let reason): self = .failed(reason)
    }
  }
}
