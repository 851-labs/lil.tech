#if os(macOS)
  import HealthDatabase
  @testable import HealthMacApp
  import LilSync
  import SwiftUI
  import Testing

  // The sidebar's sync footer (`SyncFooterView`) through a sync: a first sync's stages, counting
  // items left (851-2946), a catch-up, and the failures that need attention. Up to date, the
  // sidebar hides it (851-2991, `SyncFooterVisibility`).

  extension MacSnapshotTests {
    @Test(arguments: syncFooterCatalog.selectedStates)
    func syncFooter(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let syncFooterCatalog = StateCatalog(
    "Sync Footer", width: 260, minHeight: 0,
    states: [
      CatalogState("Syncing") { footer(.syncing(cursor: 1_200, head: 9_000)) },
      // Catching up on the changes since the snapshot, after a first sync.
      CatalogState("Catching up, many changes") {
        footer(.syncing(cursor: 2_000_000, head: 2_487_650))
      },
      CatalogState("Downloading, starting") { footer(.bootstrapping(.downloading(0, of: 0))) },
      CatalogState("Downloading") {
        footer(.bootstrapping(.downloading(300_000, of: 2_000_000)))
      },
      CatalogState("Downloading, very large") {
        footer(.bootstrapping(.downloading(1_250_000, of: 48_731_204)))
      },
      // Every part downloaded: the count starts again for saving them, rather than sitting at
      // zero.
      CatalogState("Downloaded, saving starts") {
        footer(.bootstrapping(.loading(0, of: 2_000_000)))
      },
      CatalogState("Saving") { footer(.bootstrapping(.loading(1_385_000, of: 2_000_000))) },
      CatalogState("Saving, one left") {
        footer(.bootstrapping(.loading(1_999_999, of: 2_000_000)))
      },
      CatalogState("Finishing up") { footer(.bootstrapping(.finishing(2_000_000))) },
      CatalogState("Offline") { footer(.offline) },
      CatalogState("Failed") { footer(.failed("unexpectedStatus(500)")) },
    ])

  @MainActor
  private func footer(_ status: SyncStatus) -> some View {
    SyncFooterView(status: status, retry: {})
      .background(.background)
  }
#endif
