public import ComposableArchitecture
public import LilAuth

/// lil health on the iPhone: sign in, then the home screen.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    /// `nil` until the stored session has been checked.
    public var isSignedIn: Bool?
    public var signIn = SignInFeature.State()

    public init(isSignedIn: Bool? = nil) {
      self.isSignedIn = isSignedIn
    }
  }

  public enum Action {
    case signedInChanged(Bool)
    case signIn(SignInFeature.Action)
    case signOutButtonTapped
    case task
  }

  @Dependency(\.auth) var auth

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(\.signIn, action: \.signIn) {
      SignInFeature()
    }
    Reduce { state, action in
      switch action {
      case .signedInChanged(let isSignedIn):
        state.isSignedIn = isSignedIn
        if !isSignedIn {
          state.signIn = SignInFeature.State()
        }
        return .none

      case .signIn:
        // The session's updates say when signing in worked.
        return .none

      case .signOutButtonTapped:
        return .run { [auth] _ in await auth.signOut() }

      case .task:
        return .run { [auth] send in
          for await isSignedIn in await auth.signedInUpdates() {
            await send(.signedInChanged(isSignedIn))
          }
        }
      }
    }
  }
}
