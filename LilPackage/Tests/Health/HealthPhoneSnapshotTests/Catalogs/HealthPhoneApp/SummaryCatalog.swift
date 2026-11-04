#if os(iOS)
  import ComposableArchitecture
  import Foundation
  @testable import HealthCardEditor
  import HealthCardStore
  import HealthCards
  import HealthDatabase
  @testable import HealthPhoneApp
  import HealthUI
  import SQLiteData
  import SwiftUI
  import Testing

  // Summary, the iPhone's root screen (851-3211, `SummaryContent`): the account's cards' rows, with
  // the upload's status as a row or a toolbar button. The iPhone computes cards from HealthKit; here
  // each headline is the Mac's for the same card (`HealthDatabase.cardHeadline`) from the catalog
  // database at `previewNow`, so both apps' catalogs show the same synthetic data and no image
  // depends on the simulator's HealthKit. Synthetic data only.

  extension PhoneSnapshotTests {
    @Test(arguments: summaryCatalog.selectedStates)
    func summary(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let summaryCatalog = StateCatalog(
    phone: "Summary",
    states: [
      CatalogState("Loaded") {
        summary(.loaded(Card.welcomeSeed))
      },
      // The first upload is under way: its progress is a row at the top.
      CatalogState("Uploading") {
        summary(
          .loaded(Card.welcomeSeed),
          status: .uploading(
            finishedTypes: 12, totalTypes: 40, records: 412_000, totalRecords: 1_284_000))
      },
      // Something needs the person: a row too, with what it needs.
      CatalogState("Health access needed") {
        summary(.loaded(Card.welcomeSeed), status: .needsHealthAccess)
      },
      // Health access not asked for yet (a new install, or Not Now): HealthKit says so, and the
      // rows say what they need rather than loading (851-4035).
      CatalogState("Health access not given") {
        summary(.loaded(Card.welcomeSeed), status: .needsHealthAccess) { _ in .needsHealthAccess }
      },
      // A new account, or Health access to its types not allowed: HealthKit doesn't say which.
      CatalogState("No data") {
        summary(.loaded(Card.welcomeSeed)) { _ in .loaded(nil) }
      },
      // The cards aren't read yet, or the first pull hasn't brought them: the seed's rows.
      CatalogState("Loading") {
        summary(.loading, status: .loading)
      },
      CatalogState("Failed") {
        summary(.failed("The database couldn't be read."))
      },
      // Every card deleted: New Card, there and in the toolbar.
      CatalogState("No cards") {
        summary(.loaded([]))
      },
      // Edit: the rows' handles, to drag them into another order (851-3213).
      CatalogState("Reordering") {
        summary(.loaded(Card.welcomeSeed), isEditing: true)
      },
      // A row's Delete, swiped or from its menu, asks first.
      CatalogState("Deleting a card") {
        var cards = CardsFeature.State(cards: Card.welcomeSeed)
        cards.alert = .confirmDeleteCard(
          named: "Heart Rate", .confirmDelete(id: "card_seed_heart_rate"))
        // The feature itself, which takes the alert down when the state's view is.
        return CardsAlert(store: Store(initialState: cards) { CardsFeature() }) {
          summary(.loaded(Card.welcomeSeed))
        }
      },
      // One card's headline couldn't be computed; the others' could.
      CatalogState("A card that fails") {
        summary(.loaded(Card.welcomeSeed)) { card in
          card.id == "card_seed_heart_rate"
            ? .failed("Protected health data is inaccessible.") : headline(of: card)
        }
      },
      // A card another device made with a later version of the spec.
      CatalogState("A card from a later version") {
        summary(
          .loaded(
            Array(Card.welcomeSeed.prefix(2)) + [laterVersionCard] + Card.welcomeSeed.suffix(1)))
      },
      // The design's five example cards (docs/decisions/cards.md): a line, a line per night (a
      // sleep window), dots with a moving average, dots per night, and morning weight's dots and
      // average, with its legend.
      CatalogState("Example cards") {
        summary(.loaded(exampleCards)) { headline(of: $0, in: exampleCardsDatabase) }
      },
      CatalogState("Example cards, loading") {
        summary(.loaded(exampleCards)) { _ in .loading }
      },
      // Morning weight in the US's pounds.
      CatalogState("Morning weight in pounds", locale: Locale(identifier: "en_US")) {
        summary(.loaded(exampleCards.suffix(1))) { headline(of: $0, in: exampleCardsDatabase) }
      },
    ])

  /// Summary in a navigation stack, for its title and toolbar, with each card's headline from
  /// `headline`: by default, the catalog database's.
  @MainActor
  private func summary(
    _ cards: SummaryLoad,
    status: SyncStatusFeature.State.Status = .upToDate(
      lastUpload: previewNow.addingTimeInterval(-300)),
    isEditing: Bool = false,
    headline: @escaping (Card) -> CardRow.Headline = { headline(of: $0) }
  ) -> some View {
    NavigationStack {
      SummaryContent(cards: cards, syncStatus: status) { card in
        CardRow(card: card, headline: headline(card), now: previewNow, calendar: previewCalendar)
      }
      .environment(\.editMode, .constant(isEditing ? .active : .inactive))
    }
  }

  /// `content` with the cards' alert, as Summary shows it.
  private struct CardsAlert<Content: View>: View {
    @Bindable var store: StoreOf<CardsFeature>
    @ViewBuilder let content: Content

    var body: some View {
      content.alert($store.scope(\.alert, action: \.alert))
    }
  }

  /// A card's headline from the catalog database, or another, as the Mac finds it.
  private func headline(
    of card: Card, in database: any DatabaseReader = catalogDatabase
  ) -> CardRow.Headline {
    guard let spec = card.spec else { return .loading }
    let headline = try! database.read { db in
      try HealthDatabase.cardHeadline(spec, now: previewNow, calendar: previewCalendar, db)
    }
    return .loaded(headline)
  }
#endif
