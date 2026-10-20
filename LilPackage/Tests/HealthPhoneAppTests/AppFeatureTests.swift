import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthKitAccess
import HealthPhoneApp
import HealthUpload
import LilAuth
import Testing

/// Consent was given on this iPhone, as after tapping Agree.
private func consented() {
  @Shared(.healthConsentPolicyVersion) var version
  $version.withLock { $0 = HealthConsentClient.policyVersion }
}

/// The server's answers about consent, each held until it's given with `answer`, so the steps
/// before it can be asserted: the flag is shared state, which a later action's change shows in
/// earlier assertions.
private func heldConsentChecks() -> (
  isGiven: @Sendable () async throws -> Bool, answer: (Bool) -> Void
) {
  let (answers, continuation) = AsyncStream<Bool>.makeStream()
  return (
    {
      for await given in answers { return given }
      throw CancellationError()
    },
    { continuation.yield($0) }
  )
}

// Each test has its own app storage, for the consent flag.
@MainActor
@Suite(.dependencies)
struct AppFeatureTests {
  @Test
  func anAlertOfTheAppsClosesSettings() async {
    var state = AppFeature.State(isSignedIn: true)
    state.syncStatus.isShowingSettings = true
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    // Settings, a sheet on the main screen, would hide the warning about other iPhones.
    await store.send(.otherIPhonesFound(1)) {
      $0.alert = .otherIPhones(1)
      $0.syncStatus.isShowingSettings = false
    }
  }

  @Test
  func followsTheSession() async {
    let (updates, continuation) = AsyncStream<Bool>.makeStream()
    let consent = heldConsentChecks()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.auth.signedInUpdates = { updates }
      $0.healthAuthorization.isAvailable = { true }
      $0.healthObserver = HealthObserver { _, _ in }
      $0.accountDevices = AccountDevices { 0 }
      $0.healthAuthorization.needsRequest = { false }
      $0.healthConsent.isGiven = consent.isGiven
    }

    let task = await store.send(.task)
    continuation.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
    }
    await store.receive(\.signIn.readyToSignIn)
    continuation.yield(true)
    // Consent comes first.
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
      $0.$askedForConsent.withLock { $0 = true }
      $0.healthConsent = HealthConsentFeature.State()
    }
    // It was given before (e.g. on another iPhone), so the screen goes.
    consent.answer(true)
    await store.receive(\.consentChecked) {
      $0.$consentedPolicyVersion.withLock { $0 = HealthConsentClient.policyVersion }
      $0.healthConsent = nil
    }
    // The sheet was answered before, but the medications step never offered.
    await store.receive(\.healthAccessChecked) {
      $0.syncStatus.needsHealthAccess = false
      $0.healthAccess = HealthAccessFeature.State(step: .perObject)
    }
    await store.receive(\.otherIPhonesFound)
    await task.cancel()
  }

  @Test
  func asksForHealthAccessAfterSigningIn() async {
    consented()
    let needsRequest = LockIsolated(true)
    let started = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.healthAuthorization.isAvailable = { true }
      $0.healthObserver = HealthObserver { _, _ in }
      $0.accountDevices = AccountDevices { 0 }
      $0.healthAuthorization.needsRequest = { needsRequest.value }
      $0.healthConsent.isGiven = { true }
      $0.backgroundUpload.start = { started.withValue { $0 += 1 } }
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.consentChecked)
    await store.receive(\.healthAccessChecked) {
      $0.syncStatus.needsHealthAccess = true
      $0.healthAccess = HealthAccessFeature.State()
    }
    await store.receive(\.otherIPhonesFound)
    await store.send(.healthAccess(.delegate(.finished))) {
      $0.healthAccess = nil
      $0.$offeredPerObject.withLock { $0 = true }
    }

    await store.receive(\.startUpload)

    // Once everything was offered and Health has nothing to ask, there's no onboarding: the
    // backfill starts.
    needsRequest.setValue(false)
    await store.send(.signedInChanged(true))
    await store.receive(\.consentChecked)
    await store.receive(\.healthAccessChecked) {
      $0.syncStatus.needsHealthAccess = false
    }
    await store.receive(\.backfill)
  }

  @Test
  func notNowShowsHomeAndOnboardingReturnsLater() async {
    consented()
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.healthAuthorization.isAvailable = { true }
      $0.healthObserver = HealthObserver { _, _ in }
      $0.accountDevices = AccountDevices { 0 }
      $0.healthAuthorization.needsRequest = { true }
      $0.healthConsent.isGiven = { true }
      $0.backgroundUpload.start = {}
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.consentChecked)
    await store.receive(\.healthAccessChecked) {
      $0.syncStatus.needsHealthAccess = true
      $0.healthAccess = HealthAccessFeature.State()
    }
    await store.receive(\.otherIPhonesFound)
    await store.send(.healthAccess(.delegate(.skipped))) {
      $0.healthAccess = nil
    }
    await store.receive(\.startUpload)
    await store.send(.signedInChanged(true))
    await store.receive(\.consentChecked)
    await store.receive(\.healthAccessChecked) {
      $0.healthAccess = HealthAccessFeature.State()
    }
  }

  @Test
  func withoutHealthTheresNothingToAsk() async {
    consented()
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.healthAuthorization.isAvailable = { false }
      $0.accountDevices = AccountDevices { 0 }
      $0.healthConsent.isGiven = { true }
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.consentChecked)
    await store.receive(\.otherIPhonesFound)
  }

  @Test
  func warnsOnceAboutAnotherIPhone() async {
    consented()
    let checks = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.healthAuthorization.isAvailable = { false }
      $0.accountDevices = AccountDevices {
        checks.withValue { $0 += 1 }
        return 1
      }
      $0.healthConsent.isGiven = { true }
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.consentChecked)
    await store.receive(\.otherIPhonesFound) {
      $0.alert = .otherIPhones(1)
    }
    await store.send(\.alert.dismiss) {
      $0.alert = nil
    }
    // Not again on the next launch.
    await store.send(.signedInChanged(true))
    await store.receive(\.consentChecked)
    #expect(checks.value == 1)
  }

  @Test
  func theWarningCountsTheOtherIPhones() {
    #expect(
      AlertState<AppFeature.Action.Alert>.otherIPhones(1).title
        == TextState("Another iPhone uses this account"))
    #expect(
      AlertState<AppFeature.Action.Alert>.otherIPhones(2).title
        == TextState("Other iPhones use this account"))
  }

  @Test
  func aCheckThatFinishesAfterSigningOutShowsNothing() async {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    }
    await store.send(.otherIPhonesFound(1))
  }

  @Test
  func checksAgainAfterSigningOutAndAfterAFailedCheck() async {
    struct Offline: Error {}
    consented()
    let consent = heldConsentChecks()
    // The first account's checks change nothing.
    consent.answer(true)
    consent.answer(true)
    let failing = LockIsolated(true)
    // The failing check waits for this, so the flag it set can be seen before it's cleared.
    let (release, finish) = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.healthAuthorization.isAvailable = { false }
      $0.healthBackfill = HealthBackfill(types: [])
      $0.accountDevices = AccountDevices {
        if failing.value {
          for await _ in release {}
          throw Offline()
        }
        return 0
      }
      $0.healthConsent.isGiven = consent.isGiven
    }

    // Offline: it's tried again on the next launch.
    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.consentChecked)
    finish.finish()
    await store.receive(\.otherIPhonesCheckFailed) {
      $0.$checkedForOtherIPhones.withLock { $0 = false }
    }
    failing.setValue(false)
    await store.send(.signedInChanged(true)) {
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.consentChecked)
    await store.receive(\.otherIPhonesFound)

    // The next account is checked too, and asked for its own consent.
    await store.send(.signedInChanged(false)) {
      $0.isSignedIn = false
      $0.$checkedForOtherIPhones.withLock { $0 = false }
      $0.$consentedPolicyVersion.withLock { $0 = nil }
    }
    await store.receive(\.signIn.readyToSignIn)
    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
      $0.$askedForConsent.withLock { $0 = true }
      $0.healthConsent = HealthConsentFeature.State()
    }
    consent.answer(true)
    await store.receive(\.consentChecked) {
      $0.$consentedPolicyVersion.withLock { $0 = HealthConsentClient.policyVersion }
      $0.healthConsent = nil
    }
    await store.receive(\.otherIPhonesFound)
  }

  @Test
  func signingOutStartsSignInAfresh() async {
    consented()
    let signedOut = LockIsolated(false)
    var state = AppFeature.State(isSignedIn: true)
    state.signIn.status = .signedIn
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.auth.signOut = { signedOut.setValue(true) }
    }

    await store.send(.syncStatus(.signOutButtonTapped)).finish()
    #expect(signedOut.value)
    await store.send(.signedInChanged(false)) {
      $0.isSignedIn = false
      $0.signIn = SignInFeature.State()
      $0.healthAccess = nil
      // The next account gives its own consent.
      $0.$consentedPolicyVersion.withLock { $0 = nil }
    }
    await store.receive(\.signIn.readyToSignIn)
  }

  @Test
  func reviewingHealthAccessReopensOnboarding() async {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    }

    await store.send(.syncStatus(.reviewHealthAccessButtonTapped))
    await store.receive(\.syncStatus.delegate.reviewHealthAccess) {
      $0.healthAccess = HealthAccessFeature.State()
    }
  }

  @Test
  func tryAgainRunsTheBackfillAndKeepsItGoingInTheBackground() async {
    consented()
    let started = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.healthAuthorization.isAvailable = { false }
      $0.backgroundUpload.start = { started.withValue { $0 += 1 } }
    }

    await store.send(.syncStatus(.retryButtonTapped))
    await store.receive(\.syncStatus.delegate.retry)
    await store.receive(\.startUpload)
    await store.finish()
    #expect(started.value == 1)
  }

  @Test
  func comingBackToTheAppPicksTheUploadUpAgain() async {
    consented()
    let started = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.healthAuthorization.isAvailable = { false }
      $0.backgroundUpload.start = { started.withValue { $0 += 1 } }
    }

    await store.send(.returnedToForeground)
    await store.receive(\.startUpload)
    await store.finish()
    #expect(started.value == 1)

    // Not without consent, nor before onboarding is done.
    @Shared(.healthConsentPolicyVersion) var consented
    $consented.withLock { $0 = nil }
    await store.send(.returnedToForeground)
    await store.receive(\.startUpload)
    await store.finish()
    #expect(started.value == 1)
  }

  @Test
  func notSignedInNothingPicksUp() async {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    }
    await store.send(.returnedToForeground)
  }

  @Test
  func asksForConsentBeforeHealthAccess() async {
    let given = LockIsolated(false)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { true }
      $0.healthAuthorization.needsRequest = { true }
      $0.accountDevices = AccountDevices { 0 }
      $0.healthConsent.isGiven = { given.value }
      $0.healthConsent.give = { given.setValue(true) }
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
      $0.$askedForConsent.withLock { $0 = true }
      $0.healthConsent = HealthConsentFeature.State()
    }
    await store.receive(\.consentChecked)
    await store.receive(\.otherIPhonesFound)
    // Nothing uploads before consent.
    await store.send(.backfill)

    await store.send(\.healthConsent.agreeButtonTapped) {
      $0.healthConsent?.isSaving = true
    }
    // The delegate action is handled in the same step, so its change to the flag shows here.
    await store.receive(\.healthConsent.agreed) {
      $0.healthConsent?.isSaving = false
      $0.$consentedPolicyVersion.withLock { $0 = HealthConsentClient.policyVersion }
    }
    await store.receive(\.healthConsent.delegate.agreed) {
      $0.healthConsent = nil
    }
    #expect(given.value)
    await store.receive(\.healthAccessChecked) {
      $0.syncStatus.needsHealthAccess = true
      $0.healthAccess = HealthAccessFeature.State()
    }
  }

  @Test
  func notNowLeavesUploadsOffUntilConsentIsGiven() async {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { false }
      $0.accountDevices = AccountDevices { 0 }
      $0.healthConsent.isGiven = { false }
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
      $0.$askedForConsent.withLock { $0 = true }
      $0.healthConsent = HealthConsentFeature.State()
    }
    await store.receive(\.consentChecked)
    await store.receive(\.otherIPhonesFound)
    await store.send(\.healthConsent.notNowButtonTapped)
    await store.receive(\.healthConsent.delegate.notNow) {
      $0.healthConsent = nil
    }
    #expect(store.state.syncStatus.status == .needsConsent)

    // Not asked again on its own at the next launch, but from the home screen.
    await store.send(.signedInChanged(true))
    await store.receive(\.consentChecked)
    await store.send(\.syncStatus.reviewConsentButtonTapped)
    await store.receive(\.syncStatus.delegate.reviewConsent) {
      $0.healthConsent = HealthConsentFeature.State()
    }
  }

  @Test
  func consentWithdrawnElsewhereStopsUploading() async {
    consented()
    let consent = heldConsentChecks()
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { false }
      $0.accountDevices = AccountDevices { 0 }
      $0.healthConsent.isGiven = consent.isGiven
      $0.healthBackfill = HealthBackfill(types: [])
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    consent.answer(false)
    await store.receive(\.consentChecked) {
      $0.$consentedPolicyVersion.withLock { $0 = nil }
    }
    await store.receive(\.otherIPhonesFound)
    // Withdrawn, not a first sign-in: the home screen says so, rather than the consent screen.
    #expect(store.state.healthConsent == nil)
    #expect(store.state.syncStatus.status == .needsConsent)
  }

  @Test
  func anUploadRefusedForConsentStopsUploading() async {
    consented()
    let backfill = withDependencies {
      // Withdrawn on another iPhone: the server refuses the upload.
      $0.healthReader = HealthReader { _, _, _ in
        HealthPage(
          mutations: [
            .upsert("health_sample", id: "6f1c2a40-0000-4000-8000-000000000001", row: [:])
          ],
          anchor: Data("1".utf8), hasMore: false)
      }
      $0.healthBatchUploader = HealthBatchUploader { _, _ in
        throw HealthBatchUploader.ConsentRequired()
      }
      $0.uuid = .incrementing
    } operation: {
      HealthBackfill(types: [HealthBackfillType(id: "HKQuantityTypeIdentifierBodyMass")])
    }
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { false }
      $0.healthBackfill = backfill
    }

    await store.send(.backfill)
    await store.receive(\.consentChecked) {
      $0.$consentedPolicyVersion.withLock { $0 = nil }
    }
  }

  @Test
  func withdrawingConsentStopsUploading() async {
    consented()
    var state = AppFeature.State(isSignedIn: true)
    state.syncStatus.alert = .confirmWithdrawal
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.healthConsent.withdraw = {}
      $0.healthBackfill = HealthBackfill(types: [])
    }

    // Nothing uploads from the moment it's confirmed.
    await store.send(.syncStatus(.alert(.presented(.confirmWithdrawal)))) {
      $0.syncStatus.alert = nil
      $0.syncStatus.isWithdrawingConsent = true
      $0.$consentedPolicyVersion.withLock { $0 = nil }
    }
    await store.receive(\.syncStatus.consentWithdrawn) {
      $0.syncStatus.isWithdrawingConsent = false
      $0.syncStatus.alert = .consentWithdrawn
    }
    await store.receive(\.syncStatus.delegate.consentWithdrawn)
    // Nothing uploads from here.
    await store.send(.backfill)
  }

  @Test
  func anAnswerFromBeforeAgreeingIsDropped() async {
    let consent = heldConsentChecks()
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { false }
      $0.accountDevices = AccountDevices { 0 }
      $0.healthConsent.isGiven = consent.isGiven
      $0.healthConsent.give = {}
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
      $0.$askedForConsent.withLock { $0 = true }
      $0.healthConsent = HealthConsentFeature.State()
    }
    // Agreeing while the launch check is still out.
    await store.send(\.healthConsent.agreeButtonTapped) {
      $0.healthConsent?.isSaving = true
    }
    await store.receive(\.healthConsent.agreed) {
      $0.healthConsent?.isSaving = false
      $0.$consentedPolicyVersion.withLock { $0 = HealthConsentClient.policyVersion }
    }
    await store.receive(\.healthConsent.delegate.agreed) {
      $0.healthConsent = nil
    }
    // Its answer, from before, doesn't undo the consent.
    consent.answer(false)
    await store.receive(\.consentChecked)
    await store.receive(\.otherIPhonesFound)
    #expect(store.state.hasConsent)
  }
}
