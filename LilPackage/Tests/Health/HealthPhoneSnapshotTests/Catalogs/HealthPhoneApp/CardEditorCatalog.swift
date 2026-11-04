#if os(iOS)
  import ComposableArchitecture
  import Foundation
  @testable import HealthCardEditor
  import HealthCardStore
  import HealthCards
  import HealthCatalog
  import HealthDatabase
  @testable import HealthPhoneApp
  import HealthUI
  import SQLiteData
  import SwiftUI
  import Testing

  // The card editor on the iPhone (851-3213, `CardEditorView`, shared with the Mac): the Mac's
  // states (`CardEditorCatalog` there) on a phone, in the sheet's navigation stack. A screen holds
  // the top of the form, so states about the sections below show them scrolled to. The iPhone's
  // preview runs on HealthKit; here it's the Mac's for the same card (`HealthDatabase.cardData`)
  // from the catalog database at `previewNow`, so no image depends on the simulator's HealthKit.
  // Synthetic data only.

  extension PhoneSnapshotTests {
    @Test(arguments: cardEditorCatalog.selectedStates)
    func cardEditor(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let cardEditorCatalog = StateCatalog(
    phone: "Card Editor",
    states: [
      // New Card: nothing to preview until a type is picked.
      CatalogState("New card") { editor(CardEditorFeature.State()) },
      // The type picked: its name, its category's symbol and color, and its defaults.
      CatalogState("New card, heart rate") { editor(newHeartRate) },
      CatalogState("New card, heart rate, loading") { editor(newHeartRate, preview: .loading) },
      // Edit: what it charts under Data, and Delete Card… at the bottom.
      CatalogState("Editing steps") { editor(editing(Card.welcomeSeed[0])) },
      CatalogState("Editing steps, loading") {
        editor(editing(Card.welcomeSeed[0]), preview: .loading)
      },
      CatalogState("Editing steps, Delete Card") {
        editor(editing(Card.welcomeSeed[0]), scrolledTo: .delete)
      },
      // Delete Card…'s confirmation.
      CatalogState("Deleting steps") {
        var state = editing(Card.welcomeSeed[0])
        state.alert = .confirmDeleteCard(named: "Steps", .confirmDelete)
        return editor(state, scrolledTo: .delete)
      },
      // Two lines: the preview has the legend.
      CatalogState("Editing morning weight") {
        editor(editing(exampleCards[4]), in: exampleCardsDatabase)
      },
      // Another symbol and color, from the symbols' page and the swatches.
      CatalogState("Another symbol and color") {
        var state = editing(Card.welcomeSeed[0])
        state.symbol = "figure.run"
        state.color = .teal
        state.validate()
        state.preview = state.spec
        return editor(state)
      },
      // The name cleared: its error under it, Save off, and the preview keeps the last valid
      // spec.
      CatalogState("No name") {
        var state = editing(Card.welcomeSeed[0])
        state.name = ""
        state.validate()
        return editor(state)
      },
      CatalogState("Name too long") {
        var state = editing(Card.welcomeSeed[0])
        state.name = "Steps on weekdays, walking to work and back home"
        state.validate()
        return editor(state)
      },
      // Another device brought the account to 100 cards while the editor was open: why, under
      // the preview.
      CatalogState("Too many cards") {
        var state = newHeartRate
        state.saveError = "You have 100 cards, the most lil health keeps. Delete one first."
        return editor(state)
      },
      // The symbols' page, the chosen one on a swatch of the card's color.
      CatalogState("Symbol picker") {
        NavigationStack {
          CardSymbolPage(selection: "heart.fill", color: .red) { _ in }
        }
      },
      // The five example cards (docs/decisions/cards.md), each built from a new card by the
      // builder's actions, as the controls send them.
      CatalogState("Built: body temperature") { editor(built(bodyTemperatureActions)) },
      CatalogState("Built: sleeping heart rate") {
        editor(built(sleepingHeartRateActions), in: exampleCardsDatabase)
      },
      CatalogState("Built: HRV") { editor(built(hrvActions)) },
      CatalogState("Built: heart rate before sleep") {
        editor(built(heartRateBeforeSleepActions), in: exampleCardsDatabase)
      },
      CatalogState("Built: morning weight") {
        editor(built(morningWeightActions), in: exampleCardsDatabase)
      },
      // Its series, from the Data section: First Reading, before noon, labeled.
      CatalogState("Built: morning weight, data") {
        editor(built(morningWeightActions), scrolledTo: .series("a"), in: exampleCardsDatabase)
      },
      // Each point a day, opening on the month, as dots, and the moving average below.
      CatalogState("Built: morning weight, chart") {
        editor(built(morningWeightActions), scrolledTo: .chart, in: exampleCardsDatabase)
      },
      // Heart rate during runs and rides, from a Watch: the activities and the filter's menus.
      CatalogState("Workout window and filter") {
        var state = built(heartRateDuringWorkoutsActions)
        state.sources[heartRate] = CardFilterChoices(
          apps: [CardFilterChoices.App(id: "com.apple.health.watch", name: "Apple Watch")],
          deviceModels: ["Watch"])
        return editor(state, scrolledTo: .series("a"))
      },
      // Sleeping heart rate above resting: two hidden series and their difference.
      CatalogState("Difference") {
        editor(built(differenceActions), scrolledTo: .formula("gap"), in: exampleCardsDatabase)
      },
      // The most series a card has: Add Series is off.
      CatalogState("Four series") { editor(built(fourSeriesActions), scrolledTo: .addSeries) },
      // What the controls can't rule out, under its field: From and To the same time, and a
      // label too long. Save is off, and the preview keeps the last valid spec.
      CatalogState("Errors") {
        var state = built(morningWeightActions)
        let preview = state.preview
        state.draft.series[0].window = .timeOfDay(
          CardTimeOfDay(from: CardClockTime("08:00")!, to: CardClockTime("08:00")!))
        state.draft.series[0].label = "First weigh-in of the morning, before breakfast"
        state.validate()
        state.preview = preview
        return editor(state, scrolledTo: .series("a"), in: exampleCardsDatabase)
      },
      // A series' type: the types in the card's unit, by category, with a search field.
      CatalogState("Type list") {
        NavigationStack {
          CardTypeList(types: HealthCards.chartableTypes, selection: heartRate) { _ in }
        }
      },
      CatalogState("Type list, second series") {
        let state = built(fourSeriesActions)
        return NavigationStack {
          CardTypeList(types: state.types(forSeries: "b"), selection: restingHeartRate) { _ in }
        }
      },
    ])

  private let heartRate = "HKQuantityTypeIdentifierHeartRate"
  private let restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"

  /// A new card after `actions`, sent to the editor's store: the builder's own steps, so each
  /// state is what the person gets by making those choices. The preview shows the result, as it
  /// does once typing stops.
  @MainActor
  private func built(_ actions: [CardEditorFeature.Action]) -> CardEditorFeature.State {
    let store = Store(initialState: CardEditorFeature.State()) {
      CardEditorFeature()
    } withDependencies: {
      // The preview's debounce, which the state below doesn't wait for.
      $0.continuousClock = ContinuousClock()
    }
    for action in actions {
      store.send(action)
    }
    var state = store.state
    state.preview = state.spec
    return state
  }

  /// A series' change, as its section's controls make it.
  private func series(
    _ id: String = "a", type: String, _ edit: (inout CardSpec.Series) -> Void
  ) -> CardEditorFeature.Action {
    var series = CardSpec.Series(id: id, type: type, aggregation: .avg)
    edit(&series)
    return .seriesChanged(series)
  }

  private func looks(_ name: String, _ symbol: String, _ color: CardColor)
    -> [CardEditorFeature.Action]
  {
    [.nameChanged(name), .symbolChosen(symbol), .colorChosen(color)]
  }

  private var bodyTemperatureActions: [CardEditorFeature.Action] {
    [.typeChosen(series: "a", type: "HKQuantityTypeIdentifierBodyTemperature")]
      + looks("Body Temperature", "thermometer.medium", .red)
      + [.rangeChosen(.month), .styleChosen(.line)]
  }

  private var sleepingHeartRateActions: [CardEditorFeature.Action] {
    [.typeChosen(series: "a", type: heartRate)]
      + looks("Sleeping Heart Rate", "moon.zzz.fill", .indigo)
      + [
        series(type: heartRate) { $0.window = .asleep }, .rangeChosen(.month), .styleChosen(.line),
      ]
  }

  private var hrvActions: [CardEditorFeature.Action] {
    [.typeChosen(series: "a", type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN")]
      + looks("HRV", "waveform.path.ecg", .pink)
      + [.addFormulaButtonTapped(.movingAverage), .rangeChosen(.month), .styleChosen(.dots)]
  }

  private var heartRateBeforeSleepActions: [CardEditorFeature.Action] {
    [.typeChosen(series: "a", type: heartRate)]
      + looks("Heart Rate Before Sleep", "bed.double.fill", .mint)
      + [
        series(type: heartRate) { $0.window = .beforeSleep(minutes: 5) }, .rangeChosen(.month),
        .styleChosen(.dots),
      ]
  }

  private var morningWeightActions: [CardEditorFeature.Action] {
    let weight = "HKQuantityTypeIdentifierBodyMass"
    let morning = CardTimeOfDay(from: CardClockTime("00:00")!, to: CardClockTime("12:00")!)
    return [.typeChosen(series: "a", type: weight)]
      + looks("Morning Weight", "scalemass.fill", .purple)
      + [
        series(type: weight) {
          $0.aggregation = .first
          $0.window = .timeOfDay(morning)
        },
        .bucketChosen(.day), .rangeChosen(.month), .styleChosen(.dots),
        .addFormulaButtonTapped(.movingAverage),
        series(type: weight) {
          $0.aggregation = .first
          $0.window = .timeOfDay(morning)
          $0.label = "First weigh-in before noon"
        },
        .formulaChanged(
          CardSpec.Formula(
            id: "trend", operation: .movingAverage(of: "a", points: 7),
            label: "7-day rolling average")),
      ]
  }

  private var heartRateDuringWorkoutsActions: [CardEditorFeature.Action] {
    [.typeChosen(series: "a", type: heartRate)]
      + looks("Heart Rate in Runs and Rides", "figure.run", .red)
      + [
        series(type: heartRate) {
          $0.window = .workout(activities: [37, 13])
          $0.filter = CardSpec.Filter(deviceModels: ["Watch"])
        },
        .bucketChosen(.day),
      ]
  }

  private var differenceActions: [CardEditorFeature.Action] {
    [.typeChosen(series: "a", type: heartRate)]
      + looks("Sleeping Above Resting", "moon.zzz.fill", .indigo)
      + [
        series(type: heartRate) { $0.window = .asleep },
        .addSeriesButtonTapped,
        .typeChosen(series: "b", type: restingHeartRate),
        .addFormulaButtonTapped(.difference),
        series(type: heartRate) {
          $0.window = .asleep
          $0.hidden = true
        },
        series("b", type: restingHeartRate) { $0.hidden = true },
        .formulaChanged(
          CardSpec.Formula(
            id: "gap", operation: .difference(of: "a", minus: "b"), label: "Above resting")),
        .rangeChosen(.month),
      ]
  }

  private var fourSeriesActions: [CardEditorFeature.Action] {
    [.typeChosen(series: "a", type: heartRate), .styleChosen(.line)]
      + [.addSeriesButtonTapped, .addSeriesButtonTapped, .addSeriesButtonTapped]
      + [
        series("b", type: heartRate) {
          $0.aggregation = .min
          $0.label = "Lowest"
        },
        series("c", type: heartRate) {
          $0.aggregation = .max
          $0.label = "Highest"
        },
        .typeChosen(series: "d", type: restingHeartRate),
      ]
  }

  /// A new card with heart rate picked.
  @MainActor private var newHeartRate: CardEditorFeature.State {
    CardEditorFeature.State(typeID: heartRate)
  }

  private func editing(_ card: Card) -> CardEditorFeature.State {
    CardEditorFeature.State(editing: card)!
  }

  /// The editor in its sheet's navigation stack, with its preview's state: by default, the
  /// preview's spec from `database`, opening on its headline's period, as the iPhone's does.
  @MainActor
  private func editor(
    _ state: CardEditorFeature.State, preview: CardChart.State? = nil,
    scrolledTo: CardEditorAnchor? = nil, in database: any DatabaseReader = catalogDatabase
  ) -> some View {
    NavigationStack {
      // The editor itself, which takes its alert down when the state's view is.
      CardEditorView(
        store: Store(initialState: state) { CardEditorFeature() }, scrolledTo: scrolledTo
      ) {
        spec in
        let period = spec.map { latestPeriod(of: $0, in: database) }
        CardPreviewContent(
          spec: spec, state: preview ?? period.map { .loaded($0) } ?? .loading,
          offset: period?.offset ?? 0)
      }
    }
  }

  /// A card at its range, on the period its page opens on (its headline's, 851-3987), as the Mac
  /// computes it.
  private func latestPeriod(of spec: CardSpec, in database: any DatabaseReader) -> CardPeriod {
    let range = spec.range
    return try! database.read { db in
      let latest = try HealthDatabase.cardOpeningDate(
        spec, range: range, now: previewNow, calendar: previewCalendar, db)
      let offset = range.openingOffset(latest: latest, now: previewNow, calendar: previewCalendar)
      let start = range.interval(offset: offset, now: previewNow, calendar: previewCalendar).start
      let data = try HealthDatabase.cardData(
        spec, range: range, date: start, now: previewNow, calendar: previewCalendar, db)
      return CardPeriod(range: range, offset: offset, spec: spec, data: data)
    }
  }
#endif
