public import ComposableArchitecture
public import Foundation
public import HealthCatalog
import HealthKitAccess
public import HealthUpload
public import LilAuth

/// The iPhone's main screen: what's uploaded and what isn't.
@Reducer
public struct SyncStatusFeature {
  @ObservableState
  public struct State: Equatable {
    /// `nil` until the backfill reports.
    public var progress: HealthBackfill.Progress?
    /// Whether Health still has types to ask about (e.g. the person tapped Not Now), once known:
    /// `nil` while it's being checked.
    public var needsHealthAccess: Bool?
    /// The policy version consent was given for, if any (`AppFeature`).
    @Shared(.healthConsentPolicyVersion) public var consentedPolicyVersion: String?
    public var isWithdrawingConsent = false
    public var isDeletingAccount = false
    @Presents public var alert: AlertState<Action.Alert>?
    public var signInMethods = SignInMethodsFeature.State()
    /// Whether the Settings sheet is open: the account's sign-in methods, consent, signing out
    /// and deleting it (851-2758).
    public var isShowingSettings: Bool

    public init(
      progress: HealthBackfill.Progress? = nil, needsHealthAccess: Bool? = nil,
      isWithdrawingConsent: Bool = false,
      isDeletingAccount: Bool = false, alert: AlertState<Action.Alert>? = nil,
      isShowingSettings: Bool = false
    ) {
      self.progress = progress
      self.needsHealthAccess = needsHealthAccess
      self.isWithdrawingConsent = isWithdrawingConsent
      self.isDeletingAccount = isDeletingAccount
      self.alert = alert
      self.isShowingSettings = isShowingSettings
    }

    public enum Status: Equatable {
      /// Nothing uploads until the person consents (they tapped Not Now, or withdrew it).
      case needsConsent
      case loading
      case needsHealthAccess
      /// Paused until there's a network connection.
      case offline
      /// The account's storage is full, so nothing more uploads until there's room.
      case storageFull
      case failed(String)
      /// `totalRecords` once every type left has been counted.
      case uploading(finishedTypes: Int, totalTypes: Int, records: Int, totalRecords: Int? = nil)
      /// Not finished and not running, e.g. iOS paused it or the phone is locked.
      case paused(finishedTypes: Int, totalTypes: Int, records: Int, totalRecords: Int? = nil)
      case upToDate(lastUpload: Date?)
    }

    public var hasConsent: Bool { consentedPolicyVersion == HealthConsentClient.policyVersion }

    /// Whether the Settings sheet has something in progress: withdrawing consent, deleting the
    /// account, or linking or unlinking a sign-in method.
    public var isSettingsBusy: Bool {
      isWithdrawingConsent || isDeletingAccount || signInMethods.isBusy
    }

    public var status: Status {
      if !hasConsent { return .needsConsent }
      guard let progress else { return .loading }
      if needsHealthAccess == true { return .needsHealthAccess }
      if let failure = progress.failure, !progress.isRunning {
        if progress.isStorageFull { return .storageFull }
        return progress.isOffline ? .offline : .failed(failure)
      }
      // Health can take a while to answer on a fresh install (minutes, in a new simulator).
      // Until it does, nothing has uploaded yet: not paused, still being set up.
      if needsHealthAccess == nil, !progress.isFinished, !progress.isRunning,
        progress.uploadedRecords == 0
      {
        return .loading
      }
      if !progress.isFinished {
        return progress.isRunning
          ? .uploading(
            finishedTypes: progress.finishedTypes, totalTypes: progress.totalTypes,
            records: progress.uploadedRecords, totalRecords: progress.totalRecords)
          : .paused(
            finishedTypes: progress.finishedTypes, totalTypes: progress.totalTypes,
            records: progress.uploadedRecords, totalRecords: progress.totalRecords)
      }
      return .upToDate(lastUpload: progress.lastUploadAt)
    }

    /// Browse's categories, with how much of each is uploaded.
    public var categories: [CategoryProgress] {
      guard let progress else { return [] }
      let byCategory = Dictionary(grouping: progress.types.values.indices) { index in
        HealthCatalog.type(id: progress.types.keys[index])?.category
      }
      return HealthCategory.allCases.compactMap { category in
        guard let indices = byCategory[category] else { return nil }
        let types = indices.map { progress.types.values[$0] }
        return CategoryProgress(
          category: category,
          finishedTypes: types.filter(\.isDone).count, totalTypes: types.count,
          records: types.map(\.uploadedRecords).reduce(0, +))
      }
    }
  }

  public struct CategoryProgress: Equatable, Identifiable, Sendable {
    public var category: HealthCategory
    public var finishedTypes: Int
    public var totalTypes: Int
    public var records: Int

    public var id: HealthCategory { category }
    public var isDone: Bool { finishedTypes == totalTypes }
  }

  public enum Action {
    case task
    case progressChanged(HealthBackfill.Progress)
    case healthAccessChecked(needsRequest: Bool)
    case retryButtonTapped
    case reviewHealthAccessButtonTapped
    case reviewConsentButtonTapped
    case withdrawConsentButtonTapped
    /// The server recorded the withdrawal.
    case consentWithdrawn
    case consentWithdrawalFailed(String)
    case openSettingsButtonTapped
    case uploadEverythingAgainButtonTapped
    /// The gear button opened the Settings sheet, or Done or a swipe closed it.
    case settingsPresented(Bool)
    case signOutButtonTapped
    case deleteAccountButtonTapped
    /// The request finished: the app signs out next.
    case accountDeleted
    case accountDeletionFailed(String)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
    case signInMethods(SignInMethodsFeature.Action)

    public enum Alert: Equatable {
      case confirmDeletion
      case confirmWithdrawal
      case confirmUploadEverythingAgain
    }

    @CasePathable
    public enum Delegate {
      /// Show the Health access onboarding again.
      case reviewHealthAccess
      /// Show the consent screen.
      case reviewConsent
      /// Consent was withdrawn: stop uploading.
      case consentWithdrawn
      /// Run the backfill now.
      case retry
    }
  }

  @Dependency(\.auth) var auth
  @Dependency(\.healthAuthorization) var healthAuthorization
  @Dependency(\.healthBackfill) var healthBackfill
  @Dependency(\.healthConsent) var healthConsent
  @Dependency(\.openURL) var openURL

  /// The app's page in Settings, where its Health access is.
  static let settingsURL = URL(string: "app-settings:")!

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(\.signInMethods, action: \.signInMethods) {
      SignInMethodsFeature()
    }
    Reduce { state, action in
      switch action {
      case .task:
        return .merge(
          .run { [healthBackfill] send in
            for await progress in await healthBackfill.progressUpdates() {
              await send(.progressChanged(progress))
            }
          },
          .run { [healthAuthorization] send in
            await send(
              .healthAccessChecked(needsRequest: await AppFeature.needsRequest(healthAuthorization))
            )
          }
        )

      case .progressChanged(let progress):
        state.progress = progress
        return .none

      case .healthAccessChecked(let needsRequest):
        state.needsHealthAccess = needsRequest
        return .none

      case .retryButtonTapped:
        // Through the app's backfill, so background scheduling and signing out apply.
        return .send(.delegate(.retry))

      case .reviewHealthAccessButtonTapped:
        // Asked again: unknown until Health answers, not still needed.
        state.needsHealthAccess = nil
        return .send(.delegate(.reviewHealthAccess))

      case .reviewConsentButtonTapped:
        return .send(.delegate(.reviewConsent))

      case .withdrawConsentButtonTapped:
        state.alert = .confirmWithdrawal
        return .none

      case .uploadEverythingAgainButtonTapped:
        state.alert = .confirmUploadEverythingAgain
        return .none

      case .alert(.presented(.confirmUploadEverythingAgain)):
        // Forgets what went up, not the account or consent, and runs again from the start: older
        // records Health shares since (iOS 27's history setting, 851-2662) go up, and the server
        // keeps what it has, changing nothing for identical records.
        return .run { [healthBackfill] send in
          await healthBackfill.reset()
          await send(.delegate(.retry))
        }

      case .alert(.presented(.confirmWithdrawal)):
        state.isWithdrawingConsent = true
        // Nothing more goes up from here, even before the server is told: without it, nothing
        // starts uploading, including in the background.
        state.$consentedPolicyVersion.withLock { $0 = nil }
        return .run { [healthBackfill, healthConsent] send in
          await healthBackfill.pause()
          do {
            try await healthConsent.withdraw()
            await send(.consentWithdrawn)
          } catch {
            await send(.consentWithdrawalFailed(error.localizedDescription))
          }
        }

      case .consentWithdrawn:
        state.isWithdrawingConsent = false
        // What's uploaded stays until the account is deleted, which is offered next.
        state.alert = .consentWithdrawn
        return .send(.delegate(.consentWithdrawn))

      case .consentWithdrawalFailed(let reason):
        state.isWithdrawingConsent = false
        // Consent still stands. Uploading stays paused until the next change, launch or Continue.
        state.$consentedPolicyVersion.withLock { $0 = HealthConsentClient.policyVersion }
        state.alert = .withdrawalFailed(reason)
        return .none

      case .openSettingsButtonTapped:
        return .run { [openURL] _ in await openURL(Self.settingsURL) }

      case .settingsPresented(let presented):
        // Not closed while what it started is in progress: its answers show in it.
        if !presented, state.isSettingsBusy { return .none }
        state.isShowingSettings = presented
        return .none

      case .signOutButtonTapped:
        return .run { [auth] _ in await auth.signOut() }

      case .deleteAccountButtonTapped:
        state.alert = .confirmDeletion
        return .none

      case .alert(.presented(.confirmDeletion)):
        state.isDeletingAccount = true
        return .run { [auth, healthBackfill] send in
          // No uploads racing the deletion.
          await healthBackfill.pause()
          do throws(AccountDeletionError) {
            // Once deleted, the session ends, and the app signs out and clears what's here.
            try await auth.deleteAccount()
            await send(.accountDeleted)
          } catch {
            await send(.accountDeletionFailed(error.message))
          }
        }

      case .accountDeleted:
        state.isDeletingAccount = false
        return .none

      case .accountDeletionFailed(let reason):
        state.isDeletingAccount = false
        state.alert = .deletionFailed(reason)
        return .none

      case .alert:
        return .none

      case .delegate, .signInMethods:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}

extension AlertState where Action == SyncStatusFeature.Action.Alert {
  static var confirmDeletion: Self {
    Self {
      TextState("Delete Your Account?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDeletion) {
        TextState("Delete Account")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "This deletes your lil health account and everything uploaded to it, on every device. The data in Health on this iPhone stays."
      )
    }
  }

  public static var confirmUploadEverythingAgain: Self {
    Self {
      TextState("Upload Everything Again?")
    } actions: {
      ButtonState(action: .confirmUploadEverythingAgain) {
        TextState("Upload Everything")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "lil health reads all the Health data you share again, and uploads what isn't in your account yet. Nothing is uploaded twice. It can take a while."
      )
    }
  }

  public static var confirmWithdrawal: Self {
    Self {
      TextState("Withdraw Your Consent?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmWithdrawal) {
        TextState("Withdraw")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "lil health stops uploading your Health data. What's already uploaded stays in your account until you delete it."
      )
    }
  }

  public static var consentWithdrawn: Self {
    Self {
      TextState("Consent Withdrawn")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDeletion) {
        TextState("Delete Account")
      }
      ButtonState(role: .cancel) {
        TextState("Keep Account")
      }
    } message: {
      TextState(
        "Nothing more is uploaded. To remove what's already uploaded too, delete your account: that deletes everything in it, on every device. The data in Health on this iPhone stays."
      )
    }
  }

  public static func withdrawalFailed(_ reason: String) -> Self {
    Self {
      TextState("Your Consent Wasn't Withdrawn")
    } message: {
      TextState(reason)
    }
  }

  static func deletionFailed(_ reason: String) -> Self {
    Self {
      TextState("Your Account Wasn't Deleted")
    } message: {
      TextState(reason)
    }
  }
}
