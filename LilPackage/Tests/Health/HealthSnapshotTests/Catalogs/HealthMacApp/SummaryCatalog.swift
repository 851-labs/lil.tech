#if os(macOS)
  import ComposableArchitecture
  import Foundation
  import HealthCards
  import HealthCatalog
  import HealthDatabase
  @testable import HealthMacApp
  import HealthPages
  import HealthUI
  import SQLiteData
  import SwiftUI
  import Testing

  // Summary (`SummaryContent`): the account's cards' rows (851-3206) and highlights, from the
  // catalog database at `previewNow`, and highlights with made-up values. Synthetic data only.
  //
  // The welcome seed's states (Loaded, No data, Loading) are Summary's from before cards, image for
  // image: the seed reads and looks exactly as the metrics did.

  extension MacSnapshotTests {
    @Test(arguments: summaryCatalog.selectedStates)
    func summary(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let summaryCatalog = StateCatalog(
    "Summary", width: 760, minHeight: 480,
    states: [
      CatalogState("Loaded") {
        summary(.loaded(seedCards), highlights: .loaded(highlights()))
      },
      // A new account, before its iPhone has shared anything.
      CatalogState("No data") {
        summary(.loaded(seedCards)) { _ in .loaded(nil) }
      },
      // The cards aren't read yet, or a first pull hasn't brought them: the seed's rows.
      CatalogState("Loading") { summary(.loading, highlights: .loading) },
      CatalogState("Failed") {
        summary(
          .failed("The database couldn't be read."),
          highlights: .failed("The database couldn't be read."))
      },
      // Every card deleted: New Card… (851-3208).
      CatalogState("No cards") {
        summary(.loaded([]), highlights: .loaded(highlights()))
      },
      // One card's headline couldn't be read; the others' could.
      CatalogState("A card that fails") {
        summary(.loaded(seedCards)) { card in
          card.id == "card_seed_heart_rate"
            ? .failed("The database couldn't be read.") : headline(of: card)
        }
      },
      // A card another device made with a later version of the spec.
      CatalogState("A card from a later version") {
        summary(.loaded(Array(seedCards.prefix(2)) + [laterVersionCard] + seedCards.suffix(1)))
      },
      // The design's five example cards (docs/decisions/cards.md): a line, a line per night, dots
      // with a moving average, dots per night, and morning weight's dots and average, with its
      // legend.
      CatalogState("Example cards") {
        summary(.loaded(exampleCards)) { headline(of: $0, in: exampleCardsDatabase) }
      },
      CatalogState("Example cards, loading") {
        summary(.loaded(exampleCards)) { _ in .loading }
      },
      // Morning weight's legend in a narrow column: it truncates, never wraps.
      CatalogState("Morning weight legend, narrow", width: 300) {
        summary(.loaded(exampleCards.suffix(1))) { headline(of: $0, in: exampleCardsDatabase) }
      },
      // About the same, up a lot, and down to almost nothing, in a narrow column, where the bars'
      // names used to run into the bar above (851-2824).
      CatalogState("Week comparisons", width: 360, minHeight: 640) {
        // Links, as Summary's rows are, so the form's chevron takes its width here too.
        NavigationStack {
          Form {
            Section("Highlights") {
              weekHighlight("HKQuantityTypeIdentifierRestingHeartRate", current: 61, previous: 60)
              weekHighlight("HKQuantityTypeIdentifierStepCount", current: 12_480, previous: 4_210)
              weekHighlight(
                "HKQuantityTypeIdentifierActiveEnergyBurned", current: 12, previous: 640)
            }
          }
          .formStyle(.grouped)
        }
      },
    ],
    // The highlights start in the same place, loading or not, with data or without (851-3092), and
    // whether a card's headline has loaded or not.
    sameLayout: [["Loaded", "Loading", "No data"], ["Example cards", "Example cards, loading"]])

  /// Summary in a navigation stack, for its title, with each card's headline from `headline`: by
  /// default, the app's request at the suite's date and calendar.
  @MainActor
  private func summary(
    _ cards: SummaryLoad<[Card]>, highlights: SummaryLoad<[Highlight]> = .loaded([]),
    headline: @escaping (Card) -> CardRow.Headline = { headline(of: $0) }
  ) -> some View {
    NavigationStack {
      SummaryContent(
        cards: cards, highlights: highlights,
        actions: SummaryCardActions(
          newCard: {}, edit: { _ in }, delete: { _ in }, moveUp: { _ in }, moveDown: { _ in })
      ) { card in
        CardRow(card: card, headline: headline(card), now: previewNow, calendar: previewCalendar)
      }
    }
  }

  /// The welcome seed, as an account has it once synced.
  let seedCards = Card.welcomeSeed

  /// A card's headline from the catalog database, or another, by the app's request.
  private func headline(
    of card: Card, in database: any DatabaseReader = catalogDatabase
  ) -> CardRow.Headline {
    let headlines = try! database.read { db in
      CardHeadlinesRequest(cards: [card], day: previewNow).fetch(
        now: previewNow, calendar: previewCalendar, db)
    }
    return headlines[card]
  }

  /// The catalog database's week highlights (two weeks of data), after a made-up trend.
  private func highlights() -> [Highlight] {
    let calendar = previewCalendar
    let weeks = try! catalogDatabase.read { db in
      try HealthDatabase.highlights(now: previewNow, calendar: calendar, db)
    }
    let start = calendar.date(byAdding: .weekOfYear, value: -16, to: previewNow)!
    let trend = Highlight(
      typeID: "HKQuantityTypeIdentifierRestingHeartRate", kind: .trend, current: 58, previous: 66,
      recentStart: calendar.date(byAdding: .weekOfYear, value: 12, to: start)!,
      points: (0..<16).map { week in
        DailyValue(
          day: calendar.date(byAdding: .weekOfYear, value: week, to: start)!,
          value: week < 12 ? 66 + Double(week % 3) - 1 : 58 + Double(week % 2))
      })
    return [trend] + weeks.prefix(2)
  }

  @MainActor
  private func weekHighlight(_ typeID: String, current: Double, previous: Double) -> some View {
    NavigationLink(value: typeID) {
      HighlightRow(
        highlight: Highlight(
          typeID: typeID, kind: .week, current: current, previous: previous,
          recentStart: previewNow),
        type: HealthCatalog.type(id: typeID)!)
    }
  }
#endif
