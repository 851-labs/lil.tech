#if os(macOS)
  import Foundation
  import HealthDatabase
  @testable import HealthPages
  import SwiftUI
  import Testing

  // Health Details (`HealthDetailsContent`): the profile, with ages at `previewNow`. Synthetic
  // data only: a made-up profile.

  extension MacSnapshotTests {
    @Test(arguments: healthDetailsCatalog.selectedStates)
    func healthDetails(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let healthDetailsCatalog = StateCatalog(
    "Health Details", width: 620, minHeight: 560,
    states: [
      CatalogState("Health Details") {
        details(
          .loaded(
            HealthDetails(
              dateOfBirth: BirthDate(year: 1990, month: 4, day: 2), sex: .female,
              bloodType: .aPositive, skinType: .typeIII, wheelchairUse: .no, hasSynced: true)))
      },
      CatalogState("Health Details, partly set") {
        details(
          .loaded(
            HealthDetails(
              dateOfBirth: BirthDate(year: 1984, month: 11, day: 23), bloodType: .oNegative,
              hasSynced: true)))
      },
      CatalogState("Health Details, nothing synced") {
        details(.loaded(HealthDetails(characteristics: [])))
      },
      CatalogState("Health Details loading") { details(.loading) },
      CatalogState("Health Details failed") {
        details(.failed("The database couldn't be read."))
      },
    ])

  @MainActor
  private func details(_ state: HealthDetailsContent.State) -> some View {
    NavigationStack {
      HealthDetailsContent(state: state)
    }
  }
#endif
