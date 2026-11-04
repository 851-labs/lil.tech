import ComposableArchitecture
import Foundation
import HealthCardEditor
import HealthCardStore
import Testing

@testable import HealthPhoneApp

// What Summary shows (851-3211): the cards' state as it reads them, and where the upload's status
// goes. Synthetic data only.
struct SummaryTests {
  @Test
  func cardsLoadUntilReadAndPulled() {
    // Not read yet: the welcome seed's rows, loading.
    #expect(SummaryLoad(CardsFeature.State()) == .loading)
    var state = CardsFeature.State(cards: Card.welcomeSeed)
    #expect(SummaryLoad(state) == .loaded(Card.welcomeSeed))
    state.isLoading = true
    #expect(SummaryLoad(state) == .loading)
    // A failure wins: an empty list would be wrong.
    state.loadFailure = "The database couldn't be read."
    #expect(SummaryLoad(state) == .failed("The database couldn't be read."))
    #expect(SummaryLoad(CardsFeature.State(cards: [])) == .loaded([]))
  }

  @Test
  func statusIsARowWhileUploadingOrNeedingThePerson() {
    typealias Status = SyncStatusFeature.State.Status
    let rows: [Status] = [
      .needsConsent, .needsHealthAccess, .offline, .storageFull, .failed("HTTP 503"),
      .uploading(finishedTypes: 1, totalTypes: 4, records: 10),
      .paused(finishedTypes: 1, totalTypes: 4, records: 10),
    ]
    for status in rows {
      #expect(status.isShownAsRow, "\(status)")
    }
    // Otherwise a toolbar button.
    #expect(!Status.loading.isShownAsRow)
    #expect(!Status.upToDate(lastUpload: nil).isShownAsRow)
    #expect(Status.upToDate(lastUpload: nil).toolbarSymbol == "checkmark.icloud")
    #expect(Status.loading.toolbarSymbol == "icloud")
  }
}
