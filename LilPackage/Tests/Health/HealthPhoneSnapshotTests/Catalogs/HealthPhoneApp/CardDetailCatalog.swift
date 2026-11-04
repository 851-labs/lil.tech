#if os(iOS)
  import Foundation
  import HealthCardStore
  import HealthCards
  import HealthDatabase
  @testable import HealthPhoneApp
  import HealthUI
  import SQLiteData
  import SwiftUI
  import Testing

  // The full-page card on the iPhone (851-3212, `CardDetailContent`): the Mac's states
  // (`CardDetailCatalog` there) on a phone. The iPhone computes cards from HealthKit; here each
  // period is the Mac's for the same card (`HealthDatabase.cardData`) from the catalog database at
  // `previewNow`, so both apps' catalogs show the same synthetic data and no image depends on the
  // simulator's HealthKit. Synthetic data only.

  extension PhoneSnapshotTests {
    @Test(arguments: cardDetailCatalog.selectedStates)
    func cardDetail(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let cardDetailCatalog = StateCatalog(
    phone: "Card Detail",
    states: [
      CatalogState("Steps, week") { page(steps, .week) },
      CatalogState("Steps, loading") { page(steps, .week, state: .loading) },
      // Its Summary row hadn't found the latest data: the page looks for it, its dates "–" until
      // it knows the period.
      CatalogState("Steps, finding the latest data") {
        page(steps, .week, offset: nil, state: .loading)
      },
      // M chosen: the week stays, with a spinner, until the month loads (851-3084).
      CatalogState("Steps, loading the month") {
        page(steps, .month, state: .loaded(period(steps, .week), isUpdating: true))
      },
      // An earlier week, with Next on.
      CatalogState("Steps, last week") { page(steps, .week, offset: -1) },
      // No Data in the header only: the chart keeps a scale of the type's (851-3102).
      CatalogState("Steps, no data") { page(steps, .week, in: emptyDatabase) },
      // The whole reason, which Summary's row can only start (851-4020).
      CatalogState("Steps, failed") {
        page(steps, .week, state: .failed("Protected health data is inaccessible."))
      },
      // A dashed rule at 10,000, labeled.
      CatalogState("Steps with a goal") { page(stepsWithGoal, .week) },
      // Ranges: a capsule from each day's lowest to its highest reading.
      CatalogState("Heart rate, week") { page(Card.welcomeSeed[1], .week) },
      // The design's five examples (docs/decisions/cards.md), each in two ranges.
      CatalogState("Body temperature, week") { example(0, .week) },
      CatalogState("Body temperature, month") { example(0, .month) },
      CatalogState("Sleeping heart rate, week") { example(1, .week) },
      CatalogState("Sleeping heart rate, month") { example(1, .month) },
      // Dots with a 7-point moving average over them, and their legend.
      CatalogState("HRV, week") { example(2, .week) },
      CatalogState("HRV, month") { example(2, .month) },
      CatalogState("Heart rate before sleep, week") { example(3, .week) },
      CatalogState("Heart rate before sleep, month") { example(3, .month) },
      CatalogState("Morning weight, week") { example(4, .week) },
      CatalogState("Morning weight, month") { example(4, .month) },
      // In pounds (851-3116), plotted in them.
      CatalogState("Morning weight, month, US", locale: Locale(identifier: "en_US")) {
        example(4, .month)
      },
      CatalogState("A card from a later version") {
        NavigationStack { UnreadableCardPage(card: laterVersionCard) }
      },
    ])

  private let steps = Card.welcomeSeed[0]

  /// Steps with a goal of 10,000 steps a day.
  private let stepsWithGoal: Card = {
    var spec = Card.welcomeSeed[0].spec!
    spec.chart.goal = CardSpec.Goal(value: 10_000)
    return Card(
      id: "card_01JB7Z0000000000000000000G", spec: spec, position: "a9", createdAt: 0,
      updatedAt: 0)
  }()

  /// No data at all.
  private let emptyDatabase: any DatabaseWriter = try! HealthDatabase.make()

  /// A card's page in a navigation stack, for its title and toolbar: its data for the period from
  /// `database`, or the state given.
  @MainActor
  private func page(
    _ card: Card, _ range: CardRange, offset: Int? = 0, state: CardChart.State? = nil,
    in database: any DatabaseReader = catalogDatabase
  ) -> some View {
    NavigationStack {
      CardDetailContent(
        spec: card.spec!, range: .constant(range), offset: offset,
        state: state ?? .loaded(period(card, range, offset: offset ?? 0, in: database)))
    }
  }

  /// One of the design's example cards, from the Summary catalog's database for them.
  @MainActor
  private func example(_ index: Int, _ range: CardRange) -> some View {
    page(exampleCards[index], range, in: exampleCardsDatabase)
  }

  /// A card's period of `range`, `offset` from the current one, as the Mac computes it.
  private func period(
    _ card: Card, _ range: CardRange, offset: Int = 0,
    in database: any DatabaseReader = catalogDatabase
  ) -> CardPeriod {
    let spec = card.spec!
    let start = range.interval(offset: offset, now: previewNow, calendar: previewCalendar).start
    let data = try! database.read { db in
      try HealthDatabase.cardData(
        spec, range: range, date: start, now: previewNow, calendar: previewCalendar, db)
    }
    return CardPeriod(range: range, offset: offset, spec: spec, data: data)
  }
#endif
