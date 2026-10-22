#if os(iOS)
  import ComposableArchitecture
  @testable import HealthPhoneApp
  import SwiftUI
  import Testing

  // The consent screen (`HealthConsentView`), after signing in: asking, saving and failed.
  // `EmptyReducer`, so nothing the screen sends changes the state shown. Its points scroll past
  // the screen's height, so the images show the top of the screen, as the app does.

  extension PhoneSnapshotTests {
    @Test(arguments: healthConsentCatalog.selectedStates)
    func healthConsent(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let healthConsentCatalog = StateCatalog(
    phone: "Health Consent",
    states: [
      CatalogState("Asking") {
        consent(HealthConsentFeature.State())
      },
      CatalogState("Saving") {
        consent(HealthConsentFeature.State(isSaving: true))
      },
      CatalogState("Failed") {
        consent(
          HealthConsentFeature.State(
            failure: "The privacy policy changed. Update lil health to review it."))
      },
    ])

  @MainActor
  private func consent(_ state: HealthConsentFeature.State) -> some View {
    HealthConsentView(store: Store(initialState: state) { EmptyReducer() })
  }
#endif
