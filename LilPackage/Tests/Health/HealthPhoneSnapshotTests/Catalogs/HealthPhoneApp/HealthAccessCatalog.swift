#if os(iOS)
  import ComposableArchitecture
  @testable import HealthPhoneApp
  import SwiftUI
  import Testing

  // Asking for Health access (`HealthAccessView`): the explanation, before and since iOS 27 (whose
  // Health sheet ends by asking how much history to share), the request, the medications and
  // prescriptions step, and failures. `EmptyReducer`, so nothing the screen sends changes the state
  // shown.

  extension PhoneSnapshotTests {
    @Test(arguments: healthAccessCatalog.selectedStates)
    func healthAccess(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let healthAccessCatalog = StateCatalog(
    phone: "Health Access",
    states: [
      // As the simulator's iOS asks: since iOS 27.
      CatalogState("Explain") {
        HealthAccessView(store: store(HealthAccessFeature.State()))
      },
      CatalogState("Explain, before iOS 27") {
        HealthAccessView(store: store(HealthAccessFeature.State()), asksAboutHistory: false)
      },
      CatalogState("Explain, iOS 27") {
        HealthAccessView(store: store(HealthAccessFeature.State()), asksAboutHistory: true)
      },
      CatalogState("Requesting") {
        HealthAccessView(store: store(HealthAccessFeature.State(step: .requesting)))
      },
      CatalogState("Medications and prescriptions") {
        HealthAccessView(store: store(HealthAccessFeature.State(step: .perObject)))
      },
      CatalogState("Failed") {
        HealthAccessView(
          store: store(HealthAccessFeature.State(failure: "Health isn't available on this device."))
        )
      },
      CatalogState("Medications and prescriptions, failed") {
        HealthAccessView(
          store: store(
            HealthAccessFeature.State(
              step: .perObject, failure: "Health couldn't show your medications.")))
      },
    ])

  @MainActor
  private func store(_ state: HealthAccessFeature.State) -> StoreOf<HealthAccessFeature> {
    Store(initialState: state) { EmptyReducer() }
  }
#endif
