public import ComposableArchitecture
public import Foundation
public import HealthCatalog
public import HealthKitAccess
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
    /// Catching up before reading everything again (Upload Everything Again).
    public var isUploadingAgain = false
    /// Health's picker for medications or vision prescriptions is up.
    public var isChoosing = false
    @Presents public var alert: AlertState<Action.Alert>?
    public var signInMethods = SignInMethodsFeature.State()
    /// Settings › Connected Agents: the remote agents that read the account's Health data, and
    /// what they read (851-2854).
    public var connectedAgents = ConnectedAgentsFeature.State()
    /// Whether the Settings sheet is open: the account's sign-in methods, consent, signing out
    /// and deleting it (851-2758).
    public var isShowingSettings: Bool

    public init(
      progress: HealthBackfill.Progress? = nil, needsHealthAccess: Bool? = nil,
      isWithdrawingConsent: Bool = false,
      isDeletingAccount: Bool = false, isUploadingAgain: Bool = false, isChoosing: Bool = false,
      alert: AlertState<Action.Alert>? = nil,
      isShowingSettings: Bool = false
    ) {
      self.progress = progress
      self.needsHealthAccess = needsHealthAccess
      self.isWithdrawingConsent = isWithdrawingConsent
      self.isDeletingAccount = isDeletingAccount
      self.isUploadingAgain = isUploadingAgain
      self.isChoosing = isChoosing
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
    /// account, linking or unlinking a sign-in method, or revoking agents.
    public var isSettingsBusy: Bool {
      isWithdrawingConsent || isDeletingAccount || signInMethods.isBusy || connectedAgents.isBusy
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
    /// Choose Medications… or Choose Vision Prescriptions…: Health's picker for sharing them.
    case chooseButtonTapped(PerObjectHealthType)
    case chooseFinished
    case chooseFailed(String)
    case uploadEverythingAgainButtonTapped
    case uploadAgainStarted
    case uploadAgainFailed(String)
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
    case connectedAgents(ConnectedAgentsFeature.Action)

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

  private enum CancelID { case uploadAgain, choose }

  @Dependency(\.auth) var auth
  @Dependency(\.healthAuthorization) var healthAuthorization
  @Dependency(\.healthBackfill) var healthBackfill
  @Dependency(\.healthConsent) var healthConsent
  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(\.signInMethods, action: \.signInMethods) {
      SignInMethodsFeature()
    }
    Scope(\.connectedAgents, action: \.connectedAgents) {
      ConnectedAgentsFeature()
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
        // Catches up, then forgets how far each type was read, not the account or consent, and
        // the app runs again from the start: older records Health shares since (iOS 27's history
        // setting, 851-2662) go up, and the server keeps one copy of each.
        state.isUploadingAgain = true
        return .run { [healthBackfill] send in
          try await healthBackfill.uploadAgain()
          await send(.uploadAgainStarted)
        } catch: { error, send in
          await send(.uploadAgainFailed(error.localizedDescription))
        }
        .cancellable(id: CancelID.uploadAgain, cancelInFlight: true)

      case .uploadAgainStarted:
        state.isUploadingAgain = false
        return .send(.delegate(.retry))

      case .uploadAgainFailed(let reason):
        state.isUploadingAgain = false
        state.alert = .uploadAgainFailed(reason)
        return .none

      case .alert(.presented(.confirmWithdrawal)):
        state.isWithdrawingConsent = true
        state.isUploadingAgain = false
        state.isChoosing = false
        // Nothing more goes up from here, even before the server is told: without it, nothing
        // starts uploading, including in the background.
        state.$consentedPolicyVersion.withLock { $0 = nil }
        return .merge(
          .cancel(id: CancelID.uploadAgain), .cancel(id: CancelID.choose),
          .run { [healthBackfill, healthConsent] send in
            await healthBackfill.pause()
            do {
              try await healthConsent.withdraw()
              await send(.consentWithdrawn)
            } catch {
              await send(.consentWithdrawalFailed(error.localizedDescription))
            }
          })

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

      case .chooseButtonTapped(let type):
        // One at a time, and not while Upload Everything Again catches up, which runs anyway.
        guard !state.isChoosing, !state.isUploadingAgain else { return .none }
        state.isChoosing = true
        // Health's own picker; what's shared since goes up with the next run, now.
        return .run { [healthAuthorization] send in
          try await healthAuthorization.requestPerObject(type)
          await send(.chooseFinished)
        } catch: { error, send in
          await send(.chooseFailed(error.localizedDescription))
        }
        .cancellable(id: CancelID.choose, cancelInFlight: true)

      case .chooseFinished:
        state.isChoosing = false
        return .send(.delegate(.retry))

      case .chooseFailed(let reason):
        state.isChoosing = false
        state.alert = .chooseFailed(reason)
        return .none

      case .settingsPresented(let presented):
        // Not closed while what it started is in progress: its answers show in it.
        if !presented, state.isSettingsBusy { return .none }
        state.isShowingSettings = presented
        return .none

      case .signOutButtonTapped:
        state.isUploadingAgain = false
        state.isChoosing = false
        return .merge(
          .cancel(id: CancelID.uploadAgain), .cancel(id: CancelID.choose),
          .run { [auth] _ in await auth.signOut() })

      case .deleteAccountButtonTapped:
        state.alert = .confirmDeletion
        return .none

      case .alert(.presented(.confirmDeletion)):
        state.isDeletingAccount = true
        state.isUploadingAgain = false
        state.isChoosing = false
        return .merge(
          .cancel(id: CancelID.uploadAgain), .cancel(id: CancelID.choose),
          .run { [auth, healthBackfill] send in
            // No uploads racing the deletion.
            await healthBackfill.pause()
            do throws(AccountDeletionError) {
              // Once deleted, the session ends, and the app signs out and clears what's here.
              try await auth.deleteAccount()
              await send(.accountDeleted)
            } catch {
              await send(.accountDeletionFailed(error.message))
            }
          })

      case .accountDeleted:
        state.isDeletingAccount = false
        return .none

      case .accountDeletionFailed(let reason):
        state.isDeletingAccount = false
        state.alert = .deletionFailed(reason)
        return .none

      case .alert:
        return .none

      case .delegate, .signInMethods, .connectedAgents:
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
        "Everything in your account is deleted, on every device. Your data in Health stays.")
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
      TextState("This can take a while and use a lot of data, so Wi-Fi is best.")
    }
  }

  public static func chooseFailed(_ reason: String) -> Self {
    Self {
      TextState("Couldn't Open Health's Picker")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState(reason)
    }
  }

  public static func uploadAgainFailed(_ reason: String) -> Self {
    Self {
      TextState("Couldn't Upload Everything Again")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("\(reason) Nothing changed; try again later.")
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
      TextState("lil health stops uploading. What's already uploaded stays in your account.")
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
        "To remove what's already uploaded, delete your account. Your data in Health stays.")
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
