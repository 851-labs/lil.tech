#if os(macOS)
  import ComposableArchitecture
  import Foundation
  import HealthCards
  import HealthCatalog
  import HealthDatabase
  @testable import HealthMacApp
  import HealthPages
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
      // Every card deleted.
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
      SummaryContent(cards: cards, highlights: highlights) { card in
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
    guard let spec = card.spec else { return .loading }
    let result = try! database.read { db in
      try CardHeadlineRequest(spec: spec, day: previewNow).fetch(db)
    }
    return .loaded(result?.headline)
  }

  /// A card of spec version 2, which this version can't read: its name, symbol and color still
  /// show.
  let laterVersionCard = Card(
    HealthCard(
      id: "card_01JB7Z0000000000000000000A",
      spec:
        #"{"version":2,"display":{"name":"Oxygen at Altitude","symbol":"lungs.fill","color":"teal","unit":null},"series":[]}"#,
      position: "a1V", createdAt: 0, updatedAt: 0))

  /// The design's five example cards, in its order, as an agent would write them. The Card Detail
  /// catalog shows their pages.
  let exampleCards: [Card] = [
    #"{"version": 1, "display": {"name": "Body Temperature", "symbol": "thermometer.medium", "color": "red"}, "series": [{"type": "Body Temperature"}], "range": "M", "chart": {"style": "line"}}"#,
    #"{"version": 1, "display": {"name": "Sleeping Heart Rate", "symbol": "moon.zzz.fill", "color": "indigo"}, "series": [{"type": "Heart Rate", "window": {"kind": "asleep"}}], "bucket": "night", "range": "M", "chart": {"style": "line"}}"#,
    #"{"version": 1, "display": {"name": "HRV", "symbol": "waveform.path.ecg", "color": "pink"}, "series": [{"type": "HeartRateVariabilitySDNN"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "range": "M", "chart": {"style": "dots"}}"#,
    #"{"version": 1, "display": {"name": "Heart Rate Before Sleep", "symbol": "bed.double.fill", "color": "mint"}, "series": [{"type": "Heart Rate", "window": {"kind": "beforeSleep", "minutes": 5}}], "bucket": "night", "range": "M", "chart": {"style": "dots"}}"#,
    #"{"version": 1, "display": {"name": "Morning Weight", "symbol": "scalemass.fill", "color": "purple"}, "series": [{"type": "Weight", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}, "label": "First weigh-in before noon"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7, "label": "7-day rolling average"}], "bucket": "day", "range": "M", "chart": {"style": "dots"}}"#,
  ].enumerated().map { index, json in
    Card(
      id: "card_01JB7Z000000000000000000\(index)E",
      spec: try! CardSpec(inputJSON: Data(json.utf8)), position: "a\(index)", createdAt: 0,
      updatedAt: 0)
  }

  /// The catalog database, and a heart rate reading 3 minutes before each night's sleep, which
  /// its readings every 30 minutes never are (it's asleep from 23:00): for the example of heart
  /// rate before falling asleep. Its own, so no other catalog's images change.
  let exampleCardsDatabase: any DatabaseWriter = {
    let database = makePreviewHealthDatabase(now: previewNow, calendar: previewCalendar)
    let today = previewCalendar.startOfDay(for: previewNow)
    try! database.write { db in
      try HealthSample.insert {
        (0..<14).map { night in
          let start = previewCalendar.date(byAdding: .day, value: -night, to: today)!
            .addingTimeInterval(-63 * 60)
          return HealthSample(
            id: "00000000-0000-4000-8000-0000000000\(10 + night)",
            type: HealthDatabase.heartRateType,
            startDate: start.unixMilliseconds, endDate: start.unixMilliseconds + 60_000,
            value: Double(62 + night * 7 % 9), unit: "count/min", sourceName: "Apple Watch",
            sourceBundleID: "com.apple.health.watch")
        }
      }
      .execute(db)
    }
    return database
  }()

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
