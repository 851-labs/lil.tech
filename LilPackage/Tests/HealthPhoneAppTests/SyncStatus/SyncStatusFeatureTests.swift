import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthCatalog
import HealthKitAccess
import HealthPhoneApp
import HealthUpload
import LilAuth
import Testing

// Synthetic data only (AGENTS.md).
private let steps = "HKQuantityTypeIdentifierStepCount"
private let energy = "HKQuantityTypeIdentifierActiveEnergyBurned"
private let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
private let lastUpload = Date(timeIntervalSince1970: 1_760_400_000)

private func progress(
  _ types: [String: HealthBackfill.TypeProgress], running: Bool = false, failure: String? = nil,
  offline: Bool = false, storageFull: Bool = false
) -> HealthBackfill.Progress {
  HealthBackfill.Progress(
    finishedTypes: types.values.filter(\.isDone).count, totalTypes: types.count,
    uploadedRecords: types.values.map(\.uploadedRecords).reduce(0, +), isRunning: running,
    failure: failure, isOffline: offline, isStorageFull: storageFull, types: types,
    lastUploadAt: lastUpload)
}

// Each test has its own app storage, for the consent flag.
@MainActor
@Suite(.dependencies)
struct SyncStatusFeatureTests {
  @Test
  func statusFollowsTheProgress() {
    typealias State = SyncStatusFeature.State
    @Shared(.healthConsentPolicyVersion) var consented
    // Without consent nothing uploads, whatever the progress.
    #expect(State(progress: progress([:])).status == .needsConsent)
    $consented.withLock { $0 = HealthConsentClient.policyVersion }
    let done = HealthBackfill.TypeProgress(isDone: true, uploadedRecords: 10)
    let notYet = HealthBackfill.TypeProgress(isDone: false, uploadedRecords: 0)
    #expect(State().status == .loading)
    #expect(
      State(progress: progress([steps: done]), needsHealthAccess: true).status
        == .needsHealthAccess)
    #expect(
      State(progress: progress([steps: done, sleep: notYet], running: true)).status
        == .uploading(finishedTypes: 1, totalTypes: 2, records: 10))
    var counted = progress([steps: done, sleep: notYet], running: true)
    counted.totalRecords = 25
    #expect(
      State(progress: counted).status
        == .uploading(finishedTypes: 1, totalTypes: 2, records: 10, totalRecords: 25))
    #expect(
      State(progress: progress([steps: done, sleep: notYet])).status
        == .paused(finishedTypes: 1, totalTypes: 2, records: 10))
    #expect(State(progress: progress([steps: done])).status == .upToDate(lastUpload: lastUpload))
    // Running over a finished backfill (catching up) is still up to date.
    #expect(
      State(progress: progress([steps: done], running: true)).status
        == .upToDate(lastUpload: lastUpload))
    #expect(
      State(progress: progress([steps: notYet], failure: "Offline", offline: true)).status
        == .offline)
    #expect(
      State(progress: progress([steps: notYet], failure: "HTTP 503")).status
        == .failed("HTTP 503"))
    #expect(
      State(progress: progress([steps: notYet], failure: "Full", storageFull: true)).status
        == .storageFull)
    // Before Health says whether to ask for access, a new install isn't paused, it's checking.
    #expect(State(progress: progress([sleep: notYet])).status == .loading)
    #expect(
      State(progress: progress([sleep: notYet]), needsHealthAccess: false).status
        == .paused(finishedTypes: 0, totalTypes: 1, records: 0))
    // Finished with nothing to upload is up to date, answer or not.
    let empty = HealthBackfill.TypeProgress(isDone: true, uploadedRecords: 0)
    #expect(State(progress: progress([sleep: empty])).status == .upToDate(lastUpload: lastUpload))
  }

  @Test
  func categoriesAddUpTheirTypes() {
    let state = SyncStatusFeature.State(
      progress: progress([
        steps: .init(isDone: true, uploadedRecords: 10),
        energy: .init(isDone: false, uploadedRecords: 5),
        sleep: .init(isDone: true, uploadedRecords: 2),
      ]))
    #expect(
      state.categories.map {
        [$0.category.rawValue, "\($0.finishedTypes)/\($0.totalTypes)", "\($0.records)"]
      }
        == [["activity", "1/2", "15"], ["sleep", "1/1", "2"]])
  }

  @Test
  func followsTheBackfill() async throws {
    let store = TestStore(initialState: SyncStatusFeature.State()) {
      SyncStatusFeature()
    } withDependencies: {
      $0.healthAuthorization.needsRequest = { false }
    }
    store.exhaustivity = .off

    let task = await store.send(.task)
    // The access check and the progress race; only the progress matters here.
    await store.receive(\.progressChanged)
    #expect(store.state.progress?.totalTypes == 0)
    await task.cancel()
  }

  @Test
  func theGearOpensSettingsAndDoneClosesThem() async {
    let store = TestStore(initialState: SyncStatusFeature.State()) {
      SyncStatusFeature()
    }

    await store.send(.settingsPresented(true)) {
      $0.isShowingSettings = true
    }
    await store.send(.settingsPresented(false)) {
      $0.isShowingSettings = false
    }
  }

  @Test
  func settingsStayOpenWhileTheyreBusy() async {
    let store = TestStore(
      initialState: SyncStatusFeature.State(isDeletingAccount: true, isShowingSettings: true)
    ) {
      SyncStatusFeature()
    }

    // Deleting the account's answer shows in the sheet, so Done and swiping it away wait.
    await store.send(.settingsPresented(false))
  }

  @Test
  func settingsStayOpenWhileAnAgentIsRevoked() async {
    var state = SyncStatusFeature.State(isShowingSettings: true)
    state.connectedAgents.revoking = ["grant-1"]
    let store = TestStore(initialState: state) {
      SyncStatusFeature()
    }

    // A failure to revoke shows in the sheet, so Done and swiping it away wait.
    await store.send(.settingsPresented(false))
    await store.send(.connectedAgents(.revoked(id: "grant-1", .success(())))) {
      $0.connectedAgents.revoking = []
      $0.connectedAgents.agents = .loaded([])
    }
    await store.send(.settingsPresented(false)) {
      $0.isShowingSettings = false
    }
  }

  @Test
  func buttons() async {
    let chosen = LockIsolated<[PerObjectHealthType]>([])
    let signedOut = LockIsolated(false)
    let store = TestStore(initialState: SyncStatusFeature.State()) {
      SyncStatusFeature()
    } withDependencies: {
      $0.healthAuthorization.requestPerObject = { type in chosen.withValue { $0.append(type) } }
      $0.auth.signOut = { signedOut.setValue(true) }
    }

    // Health's picker, then the app uploads what's newly shared.
    await store.send(.chooseButtonTapped(.medications)) { $0.isChoosing = true }
    await store.receive(\.chooseFinished) { $0.isChoosing = false }
    await store.receive(\.delegate.retry)
    #expect(chosen.value == [.medications])
    await store.send(.signOutButtonTapped).finish()
    #expect(signedOut.value)
    await store.send(.reviewHealthAccessButtonTapped)
    await store.receive(\.delegate.reviewHealthAccess)
    await store.send(.reviewConsentButtonTapped)
    await store.receive(\.delegate.reviewConsent)
    await store.send(.retryButtonTapped)
    await store.receive(\.delegate.retry)
  }

  @Test
  func deletingTheAccount() async {
    let deleted = LockIsolated(false)
    let store = TestStore(initialState: SyncStatusFeature.State()) {
      SyncStatusFeature()
    } withDependencies: {
      $0.auth.deleteAccount = { () throws(AccountDeletionError) in deleted.setValue(true) }
    }

    await store.send(.deleteAccountButtonTapped) {
      $0.alert = .init {
        TextState("Delete Your Account?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmDeletion) { TextState("Delete Account") }
        ButtonState(role: .cancel) { TextState("Cancel") }
      } message: {
        TextState(
          "This deletes your lil health account and everything uploaded to it, on every device. The data in Health on this iPhone stays."
        )
      }
    }
    await store.send(.alert(.presented(.confirmDeletion))) {
      $0.alert = nil
      $0.isDeletingAccount = true
    }
    // The session ends, and the app signs out from there.
    await store.receive(\.accountDeleted) {
      $0.isDeletingAccount = false
    }
    #expect(deleted.value)
  }

  @Test
  func aFailedDeletionSaysWhy() async {
    var confirming = SyncStatusFeature.State()
    confirming.alert = AlertState {
      TextState("Delete Your Account?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDeletion) { TextState("Delete Account") }
    }
    let store = TestStore(initialState: confirming) {
      SyncStatusFeature()
    } withDependencies: {
      $0.auth.deleteAccount = { () throws(AccountDeletionError) in throw .unavailable }
    }

    await store.send(.alert(.presented(.confirmDeletion))) {
      $0.alert = nil
      $0.isDeletingAccount = true
    }
    await store.receive(\.accountDeletionFailed) {
      $0.isDeletingAccount = false
      $0.alert = AlertState {
        TextState("Your Account Wasn't Deleted")
      } message: {
        TextState("It isn't possible right now. Please try again later.")
      }
    }
  }

  @Test
  func aFailedWithdrawalSaysWhy() async {
    struct Offline: LocalizedError {
      var errorDescription: String? { "The Internet connection appears to be offline." }
    }
    @Shared(.healthConsentPolicyVersion) var consented
    $consented.withLock { $0 = HealthConsentClient.policyVersion }
    let store = TestStore(initialState: SyncStatusFeature.State()) {
      SyncStatusFeature()
    } withDependencies: {
      $0.healthConsent.withdraw = { throw Offline() }
      $0.healthBackfill = HealthBackfill(types: [])
    }

    await store.send(.withdrawConsentButtonTapped) {
      $0.alert = .confirmWithdrawal
    }
    // Nothing uploads from the moment it's confirmed.
    await store.send(.alert(.presented(.confirmWithdrawal))) {
      $0.alert = nil
      $0.isWithdrawingConsent = true
      $0.$consentedPolicyVersion.withLock { $0 = nil }
    }
    // Consent still stands. Uploading stays paused rather than starting again.
    await store.receive(\.consentWithdrawalFailed) {
      $0.isWithdrawingConsent = false
      $0.$consentedPolicyVersion.withLock { $0 = HealthConsentClient.policyVersion }
      $0.alert = .withdrawalFailed("The Internet connection appears to be offline.")
    }
  }

  @Test
  func uploadingEverythingAgainCatchesUpThenReadsFromTheStart() async throws {
    @Shared(.healthConsentPolicyVersion) var consented
    $consented.withLock { $0 = HealthConsentClient.policyVersion }
    // A backfill that's uploaded a type's history up to an anchor.
    let storage = HealthBackfillStorage.inMemory()
    var uploaded = HealthBackfillState()
    uploaded.anchors[steps] = Data([1, 2, 3])
    uploaded.finished = [steps]
    uploaded.uploadedRecords = 1_200
    try storage.saveState(uploaded)
    // The backfill reads its dependencies when it's made.
    let backfill = withDependencies {
      $0.healthBackfillStorage = storage
      $0.healthReader = HealthReader { _, _, _ in
        HealthPage(mutations: [], blobs: [], anchor: Data([1, 2, 3]), hasMore: false)
      }
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = lastUpload
    } operation: {
      HealthBackfill(types: [])
    }
    // No auth dependency: signing out or deleting the account would fail the test.
    let store = TestStore(initialState: SyncStatusFeature.State()) {
      SyncStatusFeature()
    } withDependencies: {
      $0.healthBackfill = backfill
    }

    await store.send(.uploadEverythingAgainButtonTapped) {
      $0.alert = .confirmUploadEverythingAgain
    }
    await store.send(.alert(.presented(.confirmUploadEverythingAgain))) {
      $0.alert = nil
      $0.isUploadingAgain = true
    }
    await store.receive(\.uploadAgainStarted) {
      $0.isUploadingAgain = false
    }
    // Then the app runs the backfill, from the start.
    await store.receive(\.delegate.retry)
    let state = try #require(try storage.loadState())
    #expect(state.anchors.isEmpty)
    #expect(state.finished.isEmpty)
    #expect(state.uploadedRecords == 0)
    #expect(consented == HealthConsentClient.policyVersion)
  }

  @Test
  func signingOutStopsUploadingEverythingAgain() async {
    let store = TestStore(
      initialState: SyncStatusFeature.State(isUploadingAgain: true)
    ) {
      SyncStatusFeature()
    } withDependencies: {
      $0.auth.signOut = {}
    }
    await store.send(.signOutButtonTapped) {
      $0.isUploadingAgain = false
    }
  }

  @Test
  func choosingFailsWithAnAlert() async {
    struct Unavailable: LocalizedError {
      var errorDescription: String? { "Health data is unavailable on this device." }
    }
    let store = TestStore(initialState: SyncStatusFeature.State()) {
      SyncStatusFeature()
    } withDependencies: {
      $0.healthAuthorization.requestPerObject = { _ in throw Unavailable() }
    }
    await store.send(.chooseButtonTapped(.visionPrescriptions)) { $0.isChoosing = true }
    await store.receive(\.chooseFailed) {
      $0.isChoosing = false
      $0.alert = .chooseFailed("Health data is unavailable on this device.")
    }
  }
}
