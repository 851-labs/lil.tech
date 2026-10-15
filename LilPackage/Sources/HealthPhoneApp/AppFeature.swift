public import ComposableArchitecture
import Foundation
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
    public var syncStatus = SyncStatusFeature.State()
    /// Asking for Health access, after signing in, while Health has types to ask about or the
    /// medications and prescriptions step hasn't been offered yet.
    public var healthAccess: HealthAccessFeature.State?
    /// Whether onboarding got to the end once, medications and prescriptions included.
    @Shared(.appStorage("offeredPerObjectHealthTypes")) public var offeredPerObject = false
    /// Whether this account's other iPhones were checked for (and warned about) once already.
    @Shared(.appStorage("checkedForOtherIPhones")) public var checkedForOtherIPhones = false
    @Presents public var alert: AlertState<Action.Alert>?

    public init(
      isSignedIn: Bool? = nil, healthAccess: HealthAccessFeature.State? = nil,
      alert: AlertState<Action.Alert>? = nil
    ) {
      self.isSignedIn = isSignedIn
      self.healthAccess = healthAccess
      self.alert = alert
    }
  }

  public enum Action {
    case alert(PresentationAction<Alert>)
    /// Starts uploading the Health history, if it isn't all uploaded.
    case backfill
    case healthAccess(HealthAccessFeature.Action)
    case healthAccessChecked(needsRequest: Bool)
    /// The account's other iPhones with lil health, by name (`nil` if unknown).
    case otherIPhonesFound([String?])
    /// They couldn't be checked for (e.g. offline), so they're checked for on the next launch.
    case otherIPhonesCheckFailed
    case signedInChanged(Bool)
    case signIn(SignInFeature.Action)
    case syncStatus(SyncStatusFeature.Action)
    case task

    public enum Alert: Equatable {}
  }

  @Dependency(\.accountDevices) var accountDevices
  @Dependency(\.auth) var auth
  @Dependency(\.healthAuthorization) var healthAuthorization
  @Dependency(\.healthBackfill) var healthBackfill

  enum CancelID { case backfill }

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(\.signIn, action: \.signIn) {
      SignInFeature()
    }
    Scope(\.syncStatus, action: \.syncStatus) {
      SyncStatusFeature()
    }
    Reduce { state, action in
      switch action {
      case .alert:
        return .none

      case .backfill:
        // Failures are kept in the backfill's progress (for the status screen, 851-2557), and
        // it's tried again on the next launch.
        return .run { [healthBackfill] _ in
          // Again now that Health access may have been granted.
          await HealthChanges.observe()
          // Asked for up front: the app may be suspended long before the run ends.
          await HealthBackgroundWork.scheduleIfNeeded()
          try? await healthBackfill.run()
          // Withdrawn if it's done (or the user signed out meanwhile).
          await HealthBackgroundWork.scheduleIfNeeded()
        }
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

      case .otherIPhonesCheckFailed:
        state.$checkedForOtherIPhones.withLock { $0 = false }
        return .none

      case .otherIPhonesFound(let names):
        guard !names.isEmpty else { return .none }
        state.alert = .otherIPhones(names)
        return .none

      case .signedInChanged(let isSignedIn):
        state.isSignedIn = isSignedIn
        guard isSignedIn else {
          state.signIn = SignInFeature.State()
          state.healthAccess = nil
          state.syncStatus = SyncStatusFeature.State()
          // The next account is checked for other iPhones too.
          state.$checkedForOtherIPhones.withLock { $0 = false }
          // The next account starts its own backfill from the beginning.
          return .merge(
            .cancel(id: CancelID.backfill),
            .run { [healthBackfill] _ in await healthBackfill.reset() }
          )
        }
        let checkDevices = !state.checkedForOtherIPhones
        state.$checkedForOtherIPhones.withLock { $0 = true }
        return .run { [healthAuthorization, accountDevices] send in
          if healthAuthorization.isAvailable() {
            // If asking fails, there's nothing to show; the sync screen reports missing access.
            let needsRequest = (try? await healthAuthorization.needsRequest()) ?? false
            await send(.healthAccessChecked(needsRequest: needsRequest))
          }
          guard checkDevices else { return }
          do {
            await send(.otherIPhonesFound(try await accountDevices.othersWithThisApp()))
          } catch {
            await send(.otherIPhonesCheckFailed)
          }
        }

      case .signIn:
        // The session's updates say when signing in worked.
        return .none

      case .syncStatus(.delegate(.retry)):
        return .send(.backfill)

      case .syncStatus(.delegate(.reviewHealthAccess)):
        state.healthAccess = HealthAccessFeature.State()
        return .none

      case .syncStatus:
        return .none

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
    .ifLet(\.$alert, action: \.alert)
  }
}

extension AlertState where Action == AppFeature.Action.Alert {
  /// One lil health account holds one Health history: two iPhones only agree on it when Health
  /// syncs them through iCloud (`docs/DECISIONS.md`).
  public static func otherIPhones(_ names: [String?]) -> Self {
    let named = names.compactMap { $0 }
    let which = named.count == 1 ? "“\(named[0])” is" : "Another iPhone is"
    return Self {
      TextState("Another iPhone uses this account")
    } actions: {
      ButtonState(role: .cancel) { TextState("OK") }
    } message: {
      TextState(
        "\(which) already uploading Health data to this account. Both iPhones must be signed in to the same Apple ID with Health turned on in iCloud settings, or your data will be counted twice or go missing."
      )
    }
  }
}
