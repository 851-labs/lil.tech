import ComposableArchitecture
import LilAuth
import Testing

@testable import HealthMacApp

/// Sign Out, in Settings › Account (851-3096).
@MainActor
struct AccountFeatureTests {
  @Test
  func signOutAsksFirst() async {
    let signedOut = LockIsolated(false)
    let store = TestStore(initialState: AccountFeature.State()) {
      AccountFeature()
    } withDependencies: {
      $0.auth.signOut = { signedOut.setValue(true) }
    }

    await store.send(.signOutButtonTapped) {
      $0.alert = .confirmSignOut
    }
    #expect(!signedOut.value)
    await store.send(.alert(.presented(.confirmSignOut))) {
      $0.alert = nil
    }
    await store.finish()
    #expect(signedOut.value)
  }

  @Test
  func cancellingStaysSignedIn() async {
    // No auth dependency: signing out would fail the test.
    let store = TestStore(initialState: AccountFeature.State()) {
      AccountFeature()
    }

    await store.send(.signOutButtonTapped) {
      $0.alert = .confirmSignOut
    }
    await store.send(.alert(.dismiss)) {
      $0.alert = nil
    }
  }

  @Test
  func theConfirmationSaysWhatStays() {
    let alert = AlertState<AccountFeature.Action.Alert>.confirmSignOut
    #expect(String(state: alert.title) == "Sign Out of lil health?")
    #expect(
      alert.message.map { String(state: $0) }
        == "Your Health data will be removed from this Mac. Your account, and the data your iPhone syncs to it, stay."
    )
    #expect(alert.buttons.map { String(state: $0.label) } == ["Sign Out", "Cancel"])
  }
}
