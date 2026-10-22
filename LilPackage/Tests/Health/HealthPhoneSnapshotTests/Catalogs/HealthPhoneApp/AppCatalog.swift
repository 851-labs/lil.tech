#if os(iOS)
  import ComposableArchitecture
  @testable import HealthPhoneApp
  import LilAuth
  import SwiftUI
  import Testing

  // The app's root (`AppView`): launching, signed out, the setup screens it shows after signing in
  // (consent, then Health access), signed in (Sync Status), and the alert about other iPhones
  // uploading to the account. `EmptyReducer`, so the view's task doesn't replace the state with the
  // real session's; `ifLet`, so closing an alert clears it, as the feature does. Synthetic data
  // only.

  extension PhoneSnapshotTests {
    @Test(arguments: appCatalog.selectedStates)
    func app(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let appCatalog = StateCatalog(
    phone: "App",
    states: [
      CatalogState("Launching") {
        app(AppFeature.State())
      },
      CatalogState("Signed out") {
        app(AppFeature.State(isSignedIn: false))
      },
      CatalogState("Asking for consent") {
        app(AppFeature.State(isSignedIn: true, healthConsent: HealthConsentFeature.State()))
      },
      CatalogState("Asking for Health access") {
        app(AppFeature.State(isSignedIn: true, healthAccess: HealthAccessFeature.State()))
      },
      CatalogState("Signed in") {
        app(AppFeature.State(isSignedIn: true))
      },
      CatalogState("Another iPhone") {
        app(AppFeature.State(isSignedIn: true, alert: .otherIPhones(1)))
      },
      CatalogState("Two other iPhones") {
        app(AppFeature.State(isSignedIn: true, alert: .otherIPhones(2)))
      },
    ])

  @MainActor
  private func app(_ state: AppFeature.State) -> some View {
    var state = state
    // As the app's, which has a Google client ID (the test dependency has none).
    state.signIn.authorization.isGoogleAvailable = true
    return AppView(
      store: Store(initialState: state) {
        EmptyReducer<AppFeature.State, AppFeature.Action>().ifLet(\.$alert, action: \.alert)
      })
  }
#endif
