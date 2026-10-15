public import ComposableArchitecture
import HealthKitAccess
import HealthUpload
public import LilAuth

/// lil health on the iPhone: sign in, then the home screen.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    /// `nil` until the stored session has been checked.
    public var isSignedIn: Bool?
    public var signIn = SignInFeature.State()
    /// Asking for Health access, after signing in, while Health has types to ask about or the
    /// medications and prescriptions step hasn't been offered yet.
    public var healthAccess: HealthAccessFeature.State?
    /// Whether onboarding got to the end once, medications and prescriptions included.
    @Shared(.appStorage("offeredPerObjectHealthTypes")) public var offeredPerObject = false

    public init(isSignedIn: Bool? = nil, healthAccess: HealthAccessFeature.State? = nil) {
      self.isSignedIn = isSignedIn
      self.healthAccess = healthAccess
    }
  }

  public enum Action {
    /// Starts uploading the Health history, if it isn't all uploaded.
    case backfill
    case healthAccess(HealthAccessFeature.Action)
    case healthAccessChecked(needsRequest: Bool)
    case signedInChanged(Bool)
    case signIn(SignInFeature.Action)
    case signOutButtonTapped
    case task
  }

  @Dependency(\.auth) var auth
  @Dependency(\.healthAuthorization) var healthAuthorization
  @Dependency(\.healthBackfill) var healthBackfill

  enum CancelID { case backfill }

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(\.signIn, action: \.signIn) {
      SignInFeature()
    }
    Reduce { state, action in
      switch action {
      case .backfill:
        // Failures show in the backfill's progress; it's tried again on the next launch.
        return .run { [healthBackfill] _ in try? await healthBackfill.run() }
          .cancellable(id: CancelID.backfill, cancelInFlight: true)

      case .healthAccess(.delegate(.finished)):
        state.$offeredPerObject.withLock { $0 = true }
        state.healthAccess = nil
        return .send(.backfill)

      case .healthAccess(.delegate(.skipped)):
        state.healthAccess = nil
        return .send(.backfill)

      case .healthAccess:
        return .none

      case .healthAccessChecked(let needsRequest):
        guard state.isSignedIn == true, state.healthAccess == nil else { return .none }
        if needsRequest {
          state.healthAccess = HealthAccessFeature.State()
        } else if !state.offeredPerObject {
          // The system sheet was answered, but onboarding stopped before its last step.
          state.healthAccess = HealthAccessFeature.State(step: .perObject)
        } else {
          return .send(.backfill)
        }
        return .none

      case .signedInChanged(let isSignedIn):
        state.isSignedIn = isSignedIn
        guard isSignedIn else {
          state.signIn = SignInFeature.State()
          state.healthAccess = nil
          // The next account starts its own backfill from the beginning.
          return .merge(
            .cancel(id: CancelID.backfill),
            .run { [healthBackfill] _ in try? await healthBackfill.reset() }
          )
        }
        return .run { [healthAuthorization] send in
          guard healthAuthorization.isAvailable() else { return }
          // If asking fails, there's nothing to show; the sync screen reports missing access.
          let needsRequest = (try? await healthAuthorization.needsRequest()) ?? false
          await send(.healthAccessChecked(needsRequest: needsRequest))
        }

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
    .ifLet(\.healthAccess, action: \.healthAccess) {
      HealthAccessFeature()
    }
  }
}
