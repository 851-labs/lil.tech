#if os(macOS)
  import ComposableArchitecture
  import MessagesOnboarding
  import SwiftUI
  import Testing

  // Full Disk Access onboarding (`FullDiskAccessView`), before and while checking again. Stores
  // have no reducer, so the app becoming active during a snapshot can't start a check.

  extension MacSnapshotTests {
    @Test(arguments: fullDiskAccessCatalog.selectedStates)
    func fullDiskAccess(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let fullDiskAccessCatalog = StateCatalog(
    "Full Disk Access", width: 480, minHeight: 320,
    states: [
      CatalogState("Default") {
        FullDiskAccessView(
          store: Store(initialState: FullDiskAccessFeature.State()) { EmptyReducer() })
      },
      CatalogState("Checking") {
        FullDiskAccessView(
          store: Store(initialState: FullDiskAccessFeature.State(isChecking: true)) {
            EmptyReducer()
          })
      },
    ])
#endif
