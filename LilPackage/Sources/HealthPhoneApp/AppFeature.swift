public import ComposableArchitecture
import Foundation
import HealthKitAccess
import HealthUpload
public import LilAuth

/// lil health on the iPhone: sign in, consent, Health access, then the home screen.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    /// `nil` until the stored session has been checked.
    public var isSignedIn: Bool?
    public var signIn = SignInFeature.State()
    public var syncStatus = SyncStatusFeature.State()
    /// Asking for consent to processing Health data, after signing in and before Health access.
    public var healthConsent: HealthConsentFeature.State?
    /// The policy version consent was given for on this account, if any (`docs/DECISIONS.md`).
    @Shared(.healthConsentPolicyVersion) public var consentedPolicyVersion: String?
    /// Whether the consent screen came up on its own since signing in. After Not Now, it's
    /// reached from the home screen instead.
    @Shared(.appStorage("askedForHealthConsent")) public var askedForConsent = false
    /// Asking for Health access, after signing in, while Health has types to ask about or the
    /// medications and prescriptions step hasn't been offered yet.
    public var healthAccess: HealthAccessFeature.State?
    /// Whether onboarding got to the end once, medications and prescriptions included.
    @Shared(.appStorage("offeredPerObjectHealthTypes")) public var offeredPerObject = false
    /// Whether this account's other iPhones were checked for (and warned about) once already.
    @Shared(.appStorage("checkedForOtherIPhones")) public var checkedForOtherIPhones = false
    @Presents public var alert: AlertState<Action.Alert>?

    public init(
      isSignedIn: Bool? = nil, healthConsent: HealthConsentFeature.State? = nil,
      healthAccess: HealthAccessFeature.State? = nil, alert: AlertState<Action.Alert>? = nil
    ) {
      self.isSignedIn = isSignedIn
      self.healthConsent = healthConsent
      self.healthAccess = healthAccess
      self.alert = alert
    }

    /// Consent to the policy this app describes is in force, as far as this iPhone knows.
    public var hasConsent: Bool { consentedPolicyVersion == HealthConsentClient.policyVersion }

    mutating func setConsent(_ given: Bool) {
      $consentedPolicyVersion.withLock { $0 = given ? HealthConsentClient.policyVersion : nil }
    }
  }

  public enum Action {
    case alert(PresentationAction<Alert>)
    /// Starts uploading the Health history, if it isn't all uploaded.
    case backfill
    /// The app came back to the front after being in the background: an upload left unfinished
    /// (e.g. the phone locked) picks up again.
    case returnedToForeground
    /// The user started an upload (finishing onboarding, Continue): the backfill, kept going
    /// after they leave the app.
    case startUpload
    /// What the server says about consent, or `nil` if it couldn't be asked (e.g. offline).
    case consentChecked(Bool?)
    case healthAccess(HealthAccessFeature.Action)
    case healthAccessChecked(needsRequest: Bool)
    case healthConsent(HealthConsentFeature.Action)
    /// How many other iPhones are signed in to the account with lil health.
    case otherIPhonesFound(Int)
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
  @Dependency(\.healthConsent) var healthConsent
  @Dependency(\.backgroundUpload) var backgroundUpload

  enum CancelID { case backfill, consentCheck, signedInChecks }

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
        return backfill(state, continuing: false)

      case .returnedToForeground:
        guard state.isSignedIn == true, state.healthConsent == nil, state.healthAccess == nil
        else { return .none }
        return .send(.startUpload)

      case .startUpload:
        return backfill(state, continuing: true)

      case .consentChecked(nil):
        return .none

      case .consentChecked(true):
        guard !state.hasConsent else { return .none }
        // Given before, e.g. on another iPhone or before reinstalling. Health access is checked
        // next, by the effect that asked.
        state.setConsent(true)
        state.healthConsent = nil
        return .none

      case .consentChecked(false):
        guard state.hasConsent else { return .none }
        state.setConsent(false)
        state.healthAccess = nil
        return stopUploading()

      case .healthConsent(.delegate(.agreed)):
        state.setConsent(true)
        state.healthConsent = nil
        // A check that started before agreeing would answer for before.
        return .merge(.cancel(id: CancelID.consentCheck), checkHealthAccess())

      case .healthConsent(.delegate(.notNow)):
        state.healthConsent = nil
        return .none

      case .healthConsent:
        return .none

      case .healthAccess(.delegate(.finished)):
        state.$offeredPerObject.withLock { $0 = true }
        state.healthAccess = nil
        // Onboarding is done: the first upload starts, and carries on after the app is left.
        return .send(.startUpload)

      case .healthAccess(.delegate(.skipped)):
        state.healthAccess = nil
        return .send(.startUpload)

      case .healthAccess:
        return .none

      case .healthAccessChecked(let needsRequest):
        guard state.isSignedIn == true, state.hasConsent, state.healthAccess == nil else {
          return .none
        }
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

      case .otherIPhonesFound(let count):
        guard count > 0, state.isSignedIn == true else { return .none }
        state.alert = .otherIPhones(count)
        return .none

      case .signedInChanged(let isSignedIn):
        state.isSignedIn = isSignedIn
        guard isSignedIn else {
          state.signIn = SignInFeature.State()
          state.healthConsent = nil
          state.healthAccess = nil
          state.syncStatus = SyncStatusFeature.State()
          // The next account is checked for other iPhones too, and gives its own consent.
          state.$checkedForOtherIPhones.withLock { $0 = false }
          state.setConsent(false)
          state.$askedForConsent.withLock { $0 = false }
          // The next account starts its own backfill from the beginning.
          return .merge(
            .cancel(id: CancelID.backfill),
            .cancel(id: CancelID.signedInChecks),
            .run { [healthBackfill] _ in await healthBackfill.reset() }
          )
        }
        let checkDevices = !state.checkedForOtherIPhones
        state.$checkedForOtherIPhones.withLock { $0 = true }
        // Consent comes first, before Health access.
        if !state.hasConsent, !state.askedForConsent {
          state.$askedForConsent.withLock { $0 = true }
          state.healthConsent = HealthConsentFeature.State()
        }
        let hasConsent = state.hasConsent
        return .run { [healthAuthorization, healthConsent, accountDevices] send in
          // It may have been withdrawn on another iPhone, or given there. Asked before uploading
          // anything; offline, this iPhone's answer stands.
          let given = await Self.checkConsent(healthConsent)
          await send(.consentChecked(given))
          if given ?? hasConsent, healthAuthorization.isAvailable() {
            await send(
              .healthAccessChecked(needsRequest: await Self.needsRequest(healthAuthorization)))
          }
          if checkDevices {
            do {
              await send(.otherIPhonesFound(try await accountDevices.otherInstallsOfThisApp()))
            } catch {
              await send(.otherIPhonesCheckFailed)
            }
          }
        }
        .cancellable(id: CancelID.signedInChecks, cancelInFlight: true)

      case .signIn:
        // The session's updates say when signing in worked.
        return .none

      case .syncStatus(.delegate(.retry)):
        return .send(.startUpload)

      case .syncStatus(.delegate(.reviewHealthAccess)):
        state.healthAccess = HealthAccessFeature.State()
        return .none

      case .syncStatus(.delegate(.reviewConsent)):
        state.healthConsent = HealthConsentFeature.State()
        return .none

      case .syncStatus(.alert(.presented(.confirmWithdrawal))):
        // A check that started before withdrawing would answer for before.
        return .cancel(id: CancelID.consentCheck)

      case .syncStatus(.delegate(.consentWithdrawn)):
        state.healthAccess = nil
        return stopUploading()

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
    .ifLet(\.healthConsent, action: \.healthConsent) {
      HealthConsentFeature()
    }
    .ifLet(\.healthAccess, action: \.healthAccess) {
      HealthAccessFeature()
    }
    .ifLet(\.$alert, action: \.alert)
  }
}

extension AppFeature {
  /// Whether Health has types to ask about. If asking fails, there's nothing to show; the sync
  /// screen reports missing access.
  static func needsRequest(_ healthAuthorization: HealthAuthorization) async -> Bool {
    (try? await healthAuthorization.needsRequest()) ?? false
  }

  /// What the server says about consent. `nil` if it couldn't be asked, or if consent was given
  /// or withdrawn here meanwhile (`CancelID.consentCheck`), which makes the answer stale.
  static func checkConsent(_ healthConsent: HealthConsentClient) async -> Bool? {
    await withTaskCancellation(id: CancelID.consentCheck, cancelInFlight: true) {
      let given = try? await healthConsent.isGiven()
      return Task.isCancelled ? nil : given
    }
  }

  /// Asks for Health access, or starts the backfill if there's nothing to ask.
  func checkHealthAccess() -> Effect<Action> {
    .run { [healthAuthorization] send in
      guard healthAuthorization.isAvailable() else { return }
      await send(
        .healthAccessChecked(needsRequest: await Self.needsRequest(healthAuthorization)))
    }
  }

  /// Runs the backfill, with consent. `continuing`, for an upload the user started: it's kept
  /// going after they leave the app (`BackgroundUpload`). Failures are kept in the backfill's
  /// progress (for the status screen), and it's tried again on the next launch.
  func backfill(_ state: State, continuing: Bool) -> Effect<Action> {
    guard state.hasConsent else { return .none }
    return .run { [healthBackfill, backgroundUpload] send in
      // Again now that Health access may have been granted.
      await HealthChanges.observe()
      // Asked for up front: the app may be suspended long before the run ends.
      await HealthBackgroundWork.scheduleIfNeeded()
      if continuing { await backgroundUpload.start() }
      do {
        try await healthBackfill.run()
      } catch is HealthBatchUploader.ConsentRequired {
        // Withdrawn on another iPhone, or the policy changed.
        await send(.consentChecked(false))
      } catch {}
      // Withdrawn if it's done (or the user signed out meanwhile).
      await HealthBackgroundWork.scheduleIfNeeded()
    }
    .cancellable(id: CancelID.backfill, cancelInFlight: true)
  }

  /// Without consent: stops the backfill and its background work.
  func stopUploading() -> Effect<Action> {
    .merge(
      .cancel(id: CancelID.backfill),
      .run { [healthBackfill] _ in
        await healthBackfill.pause()
        await HealthBackgroundWork.scheduleIfNeeded()
      }
    )
  }
}

extension AlertState where Action == AppFeature.Action.Alert {
  /// One lil health account holds one Health history: two iPhones only agree on it when Health
  /// syncs them through iCloud (`docs/DECISIONS.md`).
  public static func otherIPhones(_ count: Int) -> Self {
    let which = count == 1 ? "Another iPhone is" : "\(count) other iPhones are"
    return Self {
      TextState(count == 1 ? "Another iPhone uses this account" : "Other iPhones use this account")
    } actions: {
      ButtonState(role: .cancel) { TextState("OK") }
    } message: {
      TextState(
        "\(which) already signed in to this account. Each iPhone must be signed in to the same Apple ID with Health turned on in iCloud settings, or your data will be counted twice or go missing."
      )
    }
  }
}
