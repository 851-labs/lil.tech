import Foundation
import LilSync
import Testing

@testable import HealthMacApp

// The sidebar footer's words and bar for each stage of a sync (851-2946).
@Suite
struct SyncFooterContentTests {
  @Test
  func aFirstSyncCountsItemsLeftInEachStage() {
    #expect(
      SyncFooterContent(.bootstrapping(.downloading(0, of: 0)))
        == SyncFooterContent(title: "Downloading your data…", detail: nil, bar: .indeterminate))
    #expect(
      SyncFooterContent(.bootstrapping(.downloading(300_000, of: 2_000_000)))
        == SyncFooterContent(
          title: "Downloading your data…", detail: "\(1_700_000.formatted()) items left",
          bar: .determinate(done: 300_000, total: 2_000_000)))
    // Every part downloaded: saving starts from the top rather than sitting full.
    #expect(
      SyncFooterContent(.bootstrapping(.loading(0, of: 2_000_000)))
        == SyncFooterContent(
          title: "Saving to this Mac…", detail: "\(2_000_000.formatted()) items left",
          bar: .determinate(done: 0, total: 2_000_000)))
    #expect(
      SyncFooterContent(.bootstrapping(.loading(1_999_999, of: 2_000_000)))
        == SyncFooterContent(
          title: "Saving to this Mac…", detail: "1 item left",
          bar: .determinate(done: 1_999_999, total: 2_000_000)))
    // The final transaction can't report progress: no count, and a moving bar.
    #expect(
      SyncFooterContent(.bootstrapping(.finishing(2_000_000)))
        == SyncFooterContent(title: "Finishing up…", detail: nil, bar: .indeterminate))
  }

  @Test
  func aStagePastItsCountKeepsMoving() {
    // The manifest's counts are the server's: a part may hold more. The bar doesn't sit full
    // while records are still being saved.
    for progress in [
      BootstrapProgress.loading(2_000_000, of: 2_000_000), .loading(2_000_100, of: 2_000_000),
    ] {
      #expect(
        SyncFooterContent(.bootstrapping(progress))
          == SyncFooterContent(title: "Saving to this Mac…", detail: nil, bar: .indeterminate))
    }
  }

  @Test
  func aCatchUpCountsChangesLeft() {
    #expect(
      SyncFooterContent(.syncing(cursor: 2_000_000, head: 2_487_650))
        == SyncFooterContent(
          title: "Syncing…", detail: "\(487_650.formatted()) changes left", bar: .none))
    #expect(
      SyncFooterContent(.syncing(cursor: 8_999, head: 9_000))
        == SyncFooterContent(title: "Syncing…", detail: "1 change left", bar: .none))
    #expect(
      SyncFooterContent(.syncing(cursor: 9_000, head: 9_000))
        == SyncFooterContent(title: "Syncing…", detail: nil, bar: .none))
    #expect(
      SyncFooterContent(.idle) == SyncFooterContent(title: "Syncing…", detail: nil, bar: .none))
  }

  @Test
  func otherStatusesReadAsBefore() {
    #expect(
      SyncFooterContent(.offline)
        == SyncFooterContent(
          title: "Offline", detail: "Syncs when you're back online", bar: .none))
    #expect(
      SyncFooterContent(.failed("unexpectedStatus(500)"))
        == SyncFooterContent(title: "Couldn't sync", detail: "Trying again shortly", bar: .none))
  }
}
