#if os(macOS)
  import Foundation
  import HealthCards
  import HealthDatabase
  @testable import HealthMacApp
  import SQLiteData
  import SwiftUI
  import Testing

  // The full-page card (`CardDetailContent`, 851-3207): the welcome seed's and the design's five
  // example cards over a period, from the catalog database at `previewNow` (and the Summary
  // catalog's copy of it with readings before falling asleep), its loading, empty and failed
  // states, a goal line, and a card of a later version. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: cardDetailCatalog.selectedStates)
    func cardDetail(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let cardDetailCatalog = StateCatalog(
    "Card Detail", width: 760, minHeight: 820,
    states: [
      // A seed card: Show All Data and Data Sources for its type, as Metric Detail has them.
      CatalogState("Steps, week") { page(steps, .week) },
      CatalogState("Steps, loading") { page(steps, .week, state: .loading) },
      // M pressed: the week stays, with a spinner, until the month loads (851-3084).
      CatalogState("Steps, loading the month") {
        page(steps, .month, state: .loaded(period(steps, .week), isUpdating: true))
      },
      // No Data in the header only: the chart keeps a scale of the type's (851-3102).
      CatalogState("Steps, no data") { page(steps, .week, in: emptyDatabase) },
      CatalogState("Steps, failed") {
        page(steps, .week, state: .failed("The database couldn't be read."))
      },
      // A dashed rule at 10,000, labeled.
      CatalogState("Steps with a goal") { page(stepsWithGoal, .week) },
      // Ranges: a capsule from each day's lowest to its highest reading.
      CatalogState("Heart rate, week") { page(seedCards[1], .week) },
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
        NavigationStack { CardDetailView(card: laterVersionCard) }
      },
    ],
    // What's below the chart stays put while it loads, and whatever the period shows (851-3084).
    // A card's About This Card is its own sentence, so each card is a group of its own.
    sameLayout: [
      [
        "Steps, week", "Steps, loading", "Steps, loading the month", "Steps, no data",
        "Steps, failed", "Steps with a goal",
      ],
      ["Body temperature, week", "Body temperature, month"],
      ["Sleeping heart rate, week", "Sleeping heart rate, month"],
      ["HRV, week", "HRV, month"],
      ["Heart rate before sleep, week", "Heart rate before sleep, month"],
      ["Morning weight, week", "Morning weight, month", "Morning weight, month, US"],
    ])

  private let steps = seedCards[0]

  /// Steps with a goal of 10,000 steps a day.
  private let stepsWithGoal: Card = {
    var spec = seedCards[0].spec!
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
    _ card: Card, _ range: ChartRange, state: CardDetailContent.State? = nil,
    in database: any DatabaseReader = catalogDatabase
  ) -> some View {
    NavigationStack {
      CardDetailContent(
        spec: card.spec!, range: .constant(range), offset: .constant(0),
        state: state ?? .loaded(period(card, range, in: database)))
    }
  }

  /// One of the design's example cards, from the Summary catalog's database for them.
  @MainActor
  private func example(_ index: Int, _ range: ChartRange) -> some View {
    page(exampleCards[index], range, in: exampleCardsDatabase)
  }

  /// A card's current period of `range`, by the app's request.
  private func period(
    _ card: Card, _ range: ChartRange, in database: any DatabaseReader = catalogDatabase
  ) -> CardPeriod {
    try! database.read { db in
      try CardDataRequest(spec: card.spec!, range: range, offset: 0).fetch(db)!
    }
  }
#endif
