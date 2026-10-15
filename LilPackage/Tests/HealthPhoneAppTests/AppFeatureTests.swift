import ComposableArchitecture
import HealthKitAccess
import HealthPhoneApp
import HealthUpload
import LilAuth
import Testing

@MainActor
struct AppFeatureTests {
  @Test
  func followsTheSession() async {
    let (updates, continuation) = AsyncStream<Bool>.makeStream()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.auth.signedInUpdates = { updates }
      $0.healthAuthorization.isAvailable = { true }
      $0.healthObserver = HealthObserver { _, _ in }
      $0.accountDevices = AccountDevices { [] }
      $0.healthAuthorization.needsRequest = { false }
    }

    let task = await store.send(.task)
    continuation.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
    }
    continuation.yield(true)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    // The sheet was answered before, but the medications step never offered.
    await store.receive(\.healthAccessChecked) {
      $0.healthAccess = HealthAccessFeature.State(step: .perObject)
    }
    await store.receive(\.otherIPhonesFound)
    await task.cancel()
  }

  @Test
  func asksForHealthAccessAfterSigningIn() async {
    let needsRequest = LockIsolated(true)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { true }
      $0.healthObserver = HealthObserver { _, _ in }
      $0.accountDevices = AccountDevices { [] }
      $0.healthAuthorization.needsRequest = { needsRequest.value }
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.healthAccessChecked) {
      $0.healthAccess = HealthAccessFeature.State()
    }
    await store.receive(\.otherIPhonesFound)
    await store.send(.healthAccess(.delegate(.finished))) {
      $0.healthAccess = nil
      $0.$offeredPerObject.withLock { $0 = true }
    }

    await store.receive(\.backfill)

    // Once everything was offered and Health has nothing to ask, there's no onboarding: the
    // backfill starts.
    needsRequest.setValue(false)
    await store.send(.signedInChanged(true))
    await store.receive(\.healthAccessChecked)
    await store.receive(\.backfill)
  }

  @Test
  func notNowShowsHomeAndOnboardingReturnsLater() async {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { true }
      $0.healthObserver = HealthObserver { _, _ in }
      $0.accountDevices = AccountDevices { [] }
      $0.healthAuthorization.needsRequest = { true }
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.healthAccessChecked) {
      $0.healthAccess = HealthAccessFeature.State()
    }
    await store.receive(\.otherIPhonesFound)
    await store.send(.healthAccess(.delegate(.skipped))) {
      $0.healthAccess = nil
    }
    await store.receive(\.backfill)
    await store.send(.signedInChanged(true))
    await store.receive(\.healthAccessChecked) {
      $0.healthAccess = HealthAccessFeature.State()
    }
  }

  @Test
  func withoutHealthTheresNothingToAsk() async {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { false }
      $0.accountDevices = AccountDevices { [] }
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.otherIPhonesFound)
  }

  @Test
  func warnsOnceAboutAnotherIPhone() async {
    let checks = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { false }
      $0.accountDevices = AccountDevices {
        checks.withValue { $0 += 1 }
        return ["Ada's iPhone"]
      }
    }

    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.otherIPhonesFound) {
      $0.alert = .otherIPhones(["Ada's iPhone"])
    }
    await store.send(\.alert.dismiss) {
      $0.alert = nil
    }
    // Not again on the next launch.
    await store.send(.signedInChanged(true))
    #expect(checks.value == 1)
  }

  @Test
  func checksAgainAfterSigningOutAndAfterAFailedCheck() async {
    struct Offline: Error {}
    let failing = LockIsolated(true)
    // The failing check waits for this, so the flag it set can be seen before it's cleared.
    let (release, finish) = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { false }
      $0.healthBackfill = HealthBackfill(types: [])
      $0.accountDevices = AccountDevices {
        if failing.value {
          for await _ in release {}
          throw Offline()
        }
        return []
      }
    }

    // Offline: it's tried again on the next launch.
    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    finish.finish()
    await store.receive(\.otherIPhonesCheckFailed) {
      $0.$checkedForOtherIPhones.withLock { $0 = false }
    }
    failing.setValue(false)
    await store.send(.signedInChanged(true)) {
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.otherIPhonesFound)

    // The next account is checked too.
    await store.send(.signedInChanged(false)) {
      $0.isSignedIn = false
      $0.$checkedForOtherIPhones.withLock { $0 = false }
    }
    await store.send(.signedInChanged(true)) {
      $0.isSignedIn = true
      $0.$checkedForOtherIPhones.withLock { $0 = true }
    }
    await store.receive(\.otherIPhonesFound)
  }

  @Test
  func signingOutStartsSignInAfresh() async {
    let signedOut = LockIsolated(false)
    var state = AppFeature.State(isSignedIn: true)
    state.signIn.status = .signedIn
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.auth.signOut = { signedOut.setValue(true) }
    }

    await store.send(.syncStatus(.signOutButtonTapped)).finish()
    #expect(signedOut.value)
    await store.send(.signedInChanged(false)) {
      $0.isSignedIn = false
      $0.signIn = SignInFeature.State()
      $0.healthAccess = nil
    }
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
  func tryAgainRunsTheBackfill() async {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.healthAuthorization.isAvailable = { false }
    }

    await store.send(.syncStatus(.retryButtonTapped))
    await store.receive(\.syncStatus.delegate.retry)
    await store.receive(\.backfill)
  }
}
