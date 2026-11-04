#if os(macOS)
  import ComposableArchitecture
  import Foundation
  import HealthCards
  @testable import HealthCardEditor
  import HealthCatalog
  import HealthDatabase
  @testable import HealthMacApp
  import HealthUI
  import SQLiteData
  import SwiftUI
  import Testing

  // The card editor (`CardEditorView`, 851-3208) and its query builder (851-3209): a new card
  // before and after its type is picked, a seed card and example cards edited (one whose latest
  // night isn't in its type's latest week, 851-3987), inline validation errors, a refused save,
  // the symbol grid and another symbol and color chosen; the five example cards built from a new
  // card by the builder's actions, a workout window with a filter, a difference, four series, an
  // error the controls can't rule out, and the type list. The preview is the card from the
  // catalog database at `previewNow`, by the app's request. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: cardEditorCatalog.selectedStates)
    func cardEditor(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let cardEditorCatalog = StateCatalog(
    "Card Editor", width: 560, minHeight: 640,
    states: [
      // New Card…: nothing to preview until a type is picked.
      CatalogState("New card") { editor(CardEditorFeature.State()) },
      // The type picked: its name, its category's symbol and color, and its defaults.
      CatalogState("New card, heart rate") { editor(newHeartRate) },
      CatalogState("New card, heart rate, loading") { editor(newHeartRate, preview: .loading) },
      // Edit…: Delete Card… at the bottom, and what it charts under Data.
      CatalogState("Editing steps") { editor(editing(seedCards[0])) },
      CatalogState("Editing steps, loading") {
        editor(editing(seedCards[0]), preview: .loading)
      },
      // Two lines: the preview has the legend.
      CatalogState("Editing morning weight") {
        editor(editing(exampleCards[4]), in: exampleCardsDatabase)
      },
      // The preview opens where the card's page does: on last week, its latest night, though
      // heart rate goes on this week (851-3987).
      CatalogState("Editing heart rate before sleep, none this week") {
        editor(editing(weeklyHeartRateBeforeSleep), in: lapsedBeforeSleepDatabase)
      },
      // Another symbol and color, from the grid and the swatches.
      CatalogState("Another symbol and color") {
        var state = editing(seedCards[0])
        state.symbol = "figure.run"
        state.color = .teal
        state.validate()
        state.preview = state.spec
        return editor(state)
      },
      // The name cleared: its error under it, Save off, and the preview keeps the last valid
      // spec.
      CatalogState("No name") {
        var state = editing(seedCards[0])
        state.name = ""
        state.validate()
        return editor(state)
      },
      CatalogState("Name too long") {
        var state = editing(seedCards[0])
        state.name = "Steps on weekdays, walking to work and back home"
        state.validate()
        return editor(state)
      },
      // Another device brought the account to 100 cards while the editor was open.
      CatalogState("Too many cards") {
        var state = newHeartRate
        state.saveError = "You have 100 cards, the most lil health keeps. Delete one first."
        return editor(state)
      },
      // The popover's grid, the chosen symbol on a swatch of the card's color.
      CatalogState("Symbol picker", width: 320, minHeight: 0) {
        CardSymbolGrid(selection: "heart.fill", color: .red) { _ in }
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
      // Heart rate during runs and rides, from a Watch: the activities and the filter's menus.
      CatalogState("Workout window and filter") {
        var state = built(heartRateDuringWorkoutsActions)
        state.sources[heartRate] = CardFilterChoices(
          apps: [CardFilterChoices.App(id: "com.apple.health.watch", name: "Apple Watch")],
          deviceModels: ["Watch"])
        return editor(state)
      },
      // Sleeping heart rate above resting: two hidden series and their difference.
      CatalogState("Difference") {
        editor(built(differenceActions), in: exampleCardsDatabase)
      },
      // The most series a card has: Add Series is off.
      CatalogState("Four series") { editor(built(fourSeriesActions)) },
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
        return editor(state, in: exampleCardsDatabase)
      },
      // A series' type: the types in the card's unit, by category, with a search field.
      CatalogState("Type list", width: 300, minHeight: 0) {
        CardTypeList(types: HealthCards.chartableTypes, selection: heartRate) { _ in }
      },
      CatalogState("Type list, second series", width: 300, minHeight: 0) {
        let state = built(fourSeriesActions)
        return CardTypeList(types: state.types(forSeries: "b"), selection: restingHeartRate) {
          _ in
        }
      },
    ],
    // The fields below the preview stay put while it loads, and once a new card's type is picked
    // (851-3084).
    sameLayout: [
      ["New card", "New card, heart rate", "New card, heart rate, loading"],
      ["Editing steps", "Editing steps, loading"],
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
      + looks("Heart Rate in Outdoor Runs", "figure.run", .red)
      + [
        series(type: heartRate) {
          $0.window = .workout(activities: [37, 13], location: .outdoor)
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
    CardEditorFeature.State(typeID: "HKQuantityTypeIdentifierHeartRate")
  }

  private func editing(_ card: Card) -> CardEditorFeature.State {
    CardEditorFeature.State(editing: card)!
  }

  /// The editor with its preview's state: by default, the preview's spec from `database`, by the
  /// app's request.
  @MainActor
  private func editor(
    _ state: CardEditorFeature.State, preview: CardChart.State? = nil,
    in database: any DatabaseReader = catalogDatabase
  ) -> some View {
    CardEditorView(store: Store(initialState: state) { EmptyReducer() }) { spec in
      CardPreviewContent(
        spec: spec,
        state: preview
          ?? spec.map { spec in
            .loaded(try! database.read { try CardPreviewRequest(spec: spec).fetch($0)! })
          } ?? .loading)
    }
  }
#endif
