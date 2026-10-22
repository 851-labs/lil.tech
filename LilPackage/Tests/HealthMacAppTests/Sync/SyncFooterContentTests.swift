import Foundation
import LilSync
import Testing

@testable import HealthMacApp

// The sidebar footer's words and bar for each stage of a sync (851-2946).

/// What "Updated 2 minutes ago" counts from.
private let now = Date(timeIntervalSince1970: 1_760_000_000)

@Suite
struct SyncFooterContentTests {
  @Test
  func aFirstSyncCountsItemsLeftInEachStage() {
    #expect(
      SyncFooterContent(.bootstrapping(.downloading(0, of: 0)), now: now)
        == SyncFooterContent(title: "Downloading your data…", detail: nil, bar: .indeterminate))
    #expect(
      SyncFooterContent(.bootstrapping(.downloading(300_000, of: 2_000_000)), now: now)
        == SyncFooterContent(
          title: "Downloading your data…", detail: "\(1_700_000.formatted()) items left",
          bar: .determinate(done: 300_000, total: 2_000_000)))
    // Every part downloaded: saving starts from the top rather than sitting full.
    #expect(
      SyncFooterContent(.bootstrapping(.loading(0, of: 2_000_000)), now: now)
        == SyncFooterContent(
          title: "Saving to this Mac…", detail: "\(2_000_000.formatted()) items left",
          bar: .determinate(done: 0, total: 2_000_000)))
    #expect(
      SyncFooterContent(.bootstrapping(.loading(1_999_999, of: 2_000_000)), now: now)
        == SyncFooterContent(
          title: "Saving to this Mac…", detail: "1 item left",
          bar: .determinate(done: 1_999_999, total: 2_000_000)))
    // The final transaction can't report progress: no count, and a moving bar.
    #expect(
      SyncFooterContent(.bootstrapping(.finishing(2_000_000)), now: now)
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
        SyncFooterContent(.bootstrapping(progress), now: now)
          == SyncFooterContent(title: "Saving to this Mac…", detail: nil, bar: .indeterminate))
    }
  }

  @Test
  func aCatchUpCountsChangesLeft() {
    #expect(
      SyncFooterContent(.syncing(cursor: 2_000_000, head: 2_487_650), now: now)
        == SyncFooterContent(
          title: "Syncing…", detail: "\(487_650.formatted()) changes left", bar: .none))
    #expect(
      SyncFooterContent(.syncing(cursor: 8_999, head: 9_000), now: now)
        == SyncFooterContent(title: "Syncing…", detail: "1 change left", bar: .none))
    #expect(
      SyncFooterContent(.syncing(cursor: 9_000, head: 9_000), now: now)
        == SyncFooterContent(title: "Syncing…", detail: nil, bar: .none))
    #expect(
      SyncFooterContent(.idle, now: now)
        == SyncFooterContent(title: "Syncing…", detail: nil, bar: .none))
  }

  @Test
  func upToDateSaysWhenFromNow() {
    // From the `now` given, not the wall clock: the same two minutes, a day later, read the same.
    // In the process's language, so compared with each other rather than with English.
    let later = now.addingTimeInterval(86_400)
    let content = SyncFooterContent(.upToDate(at: now.addingTimeInterval(-120)), now: now)
    #expect(content.title == "Up to date")
    #expect(
      content == SyncFooterContent(.upToDate(at: later.addingTimeInterval(-120)), now: later))
    #expect(
      content != SyncFooterContent(.upToDate(at: now.addingTimeInterval(-120)), now: later))
  }

  @Test
  func otherStatusesReadAsBefore() {
    #expect(
      SyncFooterContent(.offline, now: now)
        == SyncFooterContent(
          title: "Offline", detail: "Syncs when you're back online", bar: .none))
    #expect(
      SyncFooterContent(.failed("unexpectedStatus(500)"), now: now)
        == SyncFooterContent(title: "Couldn't sync", detail: "Trying again shortly", bar: .none))
  }
}
