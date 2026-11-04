import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthCards
import HealthCatalog
import HealthDatabase
import LilSync
import LilTestSupport
import SQLiteData
import Testing

@testable import HealthCardEditor
@testable import HealthMacApp

private let heartRate = "HKQuantityTypeIdentifierHeartRate"
private let restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"
private let steps = "HKQuantityTypeIdentifierStepCount"
private let weight = "HKQuantityTypeIdentifierBodyMass"
private let hrv = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
private let bodyTemperature = "HKQuantityTypeIdentifierBodyTemperature"

/// The five example cards (docs/decisions/cards.md, The five example cards), canonical.
private let examples: [String: CardSpec] = [
  "Body Temperature":
    #"{"version": 1, "display": {"name": "Body Temperature", "symbol": "thermometer.medium", "color": "red"}, "series": [{"type": "Body Temperature"}], "range": "M", "chart": {"style": "line"}}"#,
  "Sleeping Heart Rate":
    #"{"version": 1, "display": {"name": "Sleeping Heart Rate", "symbol": "moon.zzz.fill", "color": "indigo"}, "series": [{"type": "Heart Rate", "window": {"kind": "asleep"}}], "bucket": "night", "range": "M", "chart": {"style": "line"}}"#,
  "HRV":
    #"{"version": 1, "display": {"name": "HRV", "symbol": "waveform.path.ecg", "color": "pink"}, "series": [{"type": "HeartRateVariabilitySDNN"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "range": "M", "chart": {"style": "dots"}}"#,
  "Heart Rate Before Sleep":
    #"{"version": 1, "display": {"name": "Heart Rate Before Sleep", "symbol": "bed.double.fill", "color": "mint"}, "series": [{"type": "Heart Rate", "window": {"kind": "beforeSleep", "minutes": 5}}], "bucket": "night", "range": "M", "chart": {"style": "dots"}}"#,
  "Morning Weight":
    #"{"version": 1, "display": {"name": "Morning Weight", "symbol": "scalemass.fill", "color": "purple"}, "series": [{"type": "Weight", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}, "label": "First weigh-in before noon"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7, "label": "7-day rolling average"}], "bucket": "day", "range": "M", "chart": {"style": "dots"}}"#,
].mapValues { try! CardSpec(inputJSON: Data($0.utf8)) }

/// The query builder (851-3209): the editor's sections that write a card's query, offering only
/// what the rules allow, with the validator's errors under their fields.
@Suite(.dependencies { $0.date.now = Date(timeIntervalSince1970: 1_760_500_000) })
@MainActor
struct CardQueryBuilderTests {
  let clock = ManualClock()

  private func newCard() -> TestStoreOf<CardEditorFeature> {
    let store = TestStore(initialState: CardEditorFeature.State()) {
      CardEditorFeature()
    } withDependencies: { [clock] in
      $0.continuousClock = clock
    }
    store.exhaustivity = .off
    return store
  }

  /// A series as the store has it, changed as its section's controls change it.
  private func change(
    _ store: TestStoreOf<CardEditorFeature>, series id: String = "a",
    _ edit: (inout CardSpec.Series) -> Void
  ) async {
    var series = store.state.draft.series.first { $0.id == id }!
    edit(&series)
    await store.send(.seriesChanged(series))
  }

  private func changeFormula(
    _ store: TestStoreOf<CardEditorFeature>, _ edit: (inout CardSpec.Formula) -> Void
  ) async {
    var formula = store.state.draft.formulas[0]
    edit(&formula)
    await store.send(.formulaChanged(formula))
  }

  private func looks(
    _ store: TestStoreOf<CardEditorFeature>, _ name: String, _ symbol: String, _ color: CardColor
  ) async {
    await store.send(.nameChanged(name))
    await store.send(.symbolChosen(symbol))
    await store.send(.colorChosen(color))
  }

  // MARK: - The five example cards

  /// Each example card, built from a new card the way its controls build it, is the design's spec
  /// exactly.
  @Test
  func buildsTheFiveExampleCards() async throws {
    // 1. Body temperature: a line over time.
    var store = newCard()
    await store.send(.typeChosen(series: "a", type: bodyTemperature))
    await looks(store, "Body Temperature", "thermometer.medium", .red)
    await store.send(.rangeChosen(.month))
    await store.send(.styleChosen(.line))
    #expect(store.state.spec == examples["Body Temperature"])
    await store.skipInFlightEffects(strict: false)

    // 2. Sleeping heart rate: a sleep window makes each point a night.
    store = newCard()
    await store.send(.typeChosen(series: "a", type: heartRate))
    await looks(store, "Sleeping Heart Rate", "moon.zzz.fill", .indigo)
    await change(store) { $0.window = CardWindowChoice.asleep.window(from: $0.window) }
    #expect(store.state.draft.bucket == .night)
    await store.send(.rangeChosen(.month))
    await store.send(.styleChosen(.line))
    #expect(store.state.spec == examples["Sleeping Heart Rate"])
    await store.skipInFlightEffects(strict: false)

    // 3. HRV: dots with a 7-point moving average.
    store = newCard()
    await store.send(.typeChosen(series: "a", type: hrv))
    await looks(store, "HRV", "waveform.path.ecg", .pink)
    await store.send(.addFormulaButtonTapped(.movingAverage))
    await store.send(.rangeChosen(.month))
    await store.send(.styleChosen(.dots))
    #expect(store.state.spec == examples["HRV"])
    await store.skipInFlightEffects(strict: false)

    // 4. Heart rate in the 5 minutes before falling asleep, per night.
    store = newCard()
    await store.send(.typeChosen(series: "a", type: heartRate))
    await looks(store, "Heart Rate Before Sleep", "bed.double.fill", .mint)
    await change(store) { $0.window = CardWindowChoice.beforeSleep.window(from: $0.window) }
    #expect(store.state.draft.series[0].window == .beforeSleep(minutes: 5))
    await store.send(.rangeChosen(.month))
    await store.send(.styleChosen(.dots))
    #expect(store.state.spec == examples["Heart Rate Before Sleep"])
    await store.skipInFlightEffects(strict: false)

    // 5. Morning weight: the first weigh-in before noon each day, and its 7-day average.
    store = newCard()
    await store.send(.typeChosen(series: "a", type: weight))
    await looks(store, "Morning Weight", "scalemass.fill", .purple)
    await change(store) { $0.aggregation = .first }
    await change(store) { $0.window = CardWindowChoice.timeOfDay.window(from: $0.window) }
    await store.send(.bucketChosen(.day))
    await store.send(.rangeChosen(.month))
    await store.send(.styleChosen(.dots))
    await store.send(.addFormulaButtonTapped(.movingAverage))
    await change(store) { $0.label = "First weigh-in before noon" }
    await changeFormula(store) { $0.label = "7-day rolling average" }
    #expect(store.state.spec == examples["Morning Weight"])
    #expect(store.state.canSave)
    await store.skipInFlightEffects(strict: false)
  }

  /// Each example card opens in the builder as its fields, and saving it unchanged writes nothing.
  @Test
  func examplesOpenAsTheirFields() throws {
    for (name, spec) in examples {
      let card = Card(id: "card_x", spec: spec, position: "a0", createdAt: 0, updatedAt: 0)
      let state = try #require(CardEditorFeature.State(editing: card))
      #expect(state.draft == spec, "\(name)")
      #expect(state.spec == spec && state.errors.isEmpty && !state.canSave, "\(name)")
    }
  }

  // MARK: - What's offered

  @Test
  func onlyTheTypesAggregationsAreOffered() {
    var state = CardEditorFeature.State(typeID: steps)
    #expect(state.aggregations(for: state.draft.series[0]) == [.sum])
    #expect(state.styles == [.bars, .dots, .line])

    state.typeChosen(heartRate, series: "a")
    #expect(state.draft.series[0].aggregation == .avg)
    #expect(
      state.aggregations(for: state.draft.series[0]) == [.avg, .min, .max, .first, .latest, .count])
    #expect(state.styles == HealthDataType.ChartStyle.allCases)
  }

  /// A total takes no window or filter: picking one for a type that adds up drops them.
  @Test
  func aTotalDropsItsWindowAndFilter() {
    var state = CardEditorFeature.State(typeID: heartRate)
    state.draft.series[0].window = .workout(activities: [37])
    state.draft.series[0].filter = CardSpec.Filter(deviceModels: ["Watch"])
    state.typeChosen(steps, series: "a")
    #expect(state.draft.series[0].aggregation == .sum)
    #expect(state.draft.series[0].window == nil && state.draft.series[0].filter == nil)
  }

  /// Night needs a sleep window, and a sleep window a night, week or month; the range follows
  /// the bucket.
  @Test
  func bucketsAndRangesFollowTheWindows() {
    var state = CardEditorFeature.State(typeID: heartRate)
    #expect(state.buckets == [.auto, .hour, .day, .week, .month])

    state.draft.bucket = .hour
    state.draft.range = .day
    state.draft.series[0].window = .asleep
    state.normalize()
    #expect(state.buckets == [.night, .week, .month])
    #expect(state.draft.bucket == .night && state.draft.range == .day)

    state.draft.bucket = .month
    state.normalize()
    #expect(state.draft.range == .sixMonths)

    // Without the window, a month stays a month; a night becomes automatic.
    state.draft.series[0].window = nil
    state.normalize()
    #expect(state.draft.bucket == .month)
    state.draft.series[0].window = .asleep
    state.draft.bucket = .night
    state.normalize()
    state.draft.series[0].window = nil
    state.normalize()
    #expect(state.draft.bucket == .auto)
  }

  /// A count has no lowest and highest reading: Ranges isn't offered, and a card drawn as ranges
  /// becomes dots.
  @Test
  func aCountIsntDrawnAsRanges() async {
    let store = newCard()
    await store.send(.typeChosen(series: "a", type: heartRate))
    #expect(store.state.draft.chart.style == .ranges)
    await change(store) { $0.aggregation = .count }
    #expect(store.state.styles == [.bars, .dots, .line])
    #expect(store.state.draft.chart.style == .dots && store.state.spec?.chart.style == .dots)
    await store.skipInFlightEffects(strict: false)
  }

  @Test
  func unitsAreTheLeadsDimensions() {
    var state = CardEditorFeature.State(typeID: weight)
    #expect(state.units == ["kg", "lb", "st"])
    state.draft.display.unit = "lb"
    state.typeChosen(heartRate, series: "a")
    #expect(state.units.isEmpty && state.draft.display.unit == nil)
  }

  /// Up to 4 series, each new one of the first's type; a series' type list keeps to the card's
  /// unit, and removing a series removes the formulas of it.
  @Test
  func upToFourSeriesInOneUnit() {
    var state = CardEditorFeature.State(typeID: heartRate)
    #expect(state.types(forSeries: "a").count == HealthCards.chartableTypes.count)
    state.addSeries()
    state.addSeries()
    state.addSeries()
    #expect(state.draft.series.map(\.id) == ["a", "b", "c", "d"])
    #expect(state.draft.series.allSatisfy { $0.type == heartRate })
    #expect(!state.canAddSeries)
    state.addSeries()
    #expect(state.draft.series.count == 4)
    #expect(state.types(forSeries: "b").allSatisfy { $0.unit == "count/min" })
    #expect(state.types(forSeries: "b").contains { $0.id == restingHeartRate })

    state.removeSeries(id: "d")
    state.addFormula(.difference)
    #expect(state.draft.formulas.map(\.operation) == [.difference(of: "a", minus: "b")])
    state.removeSeries(id: "b")
    #expect(state.draft.formulas.isEmpty && state.draft.series.map(\.id) == ["a", "c"])
  }

  /// A card shows at most 4 lines: no formula on 4 visible series, until one's hidden.
  @Test
  func formulasFitTheVisibleLines() {
    var state = CardEditorFeature.State(typeID: heartRate)
    #expect(state.canAddFormula(.movingAverage) && !state.canAddFormula(.difference))
    state.addSeries()
    state.addSeries()
    state.addSeries()
    #expect(!state.canAddFormula(.movingAverage))
    state.draft.series[3].hidden = true
    state.draft.series[2].hidden = true
    #expect(state.canAddFormula(.movingAverage) && state.canAddFormula(.difference))
    state.addFormula(.movingAverage)
    state.addFormula(.difference)
    #expect(state.draft.formulas.map(\.id) == ["trend", "gap"])
    #expect(!state.canAddFormula(.movingAverage))
  }

  /// Sleeping heart rate above resting, per night: two hidden series and their difference.
  @Test
  func buildsADifference() async throws {
    let store = newCard()
    await store.send(.typeChosen(series: "a", type: heartRate))
    await change(store) { $0.window = .asleep }
    await store.send(.addSeriesButtonTapped)
    await store.send(.typeChosen(series: "b", type: restingHeartRate))
    await change(store, series: "b") { $0.window = nil }
    await store.send(.addFormulaButtonTapped(.difference))
    await change(store) { $0.hidden = true }
    await change(store, series: "b") { $0.hidden = true }
    let spec = try #require(store.state.spec)
    #expect(spec.bucket == .night)
    #expect(spec.formulas.map(\.operation) == [.difference(of: "a", minus: "b")])
    #expect(
      spec.about == "Average heart rate while asleep minus average resting heart rate, per night.")
    await store.skipInFlightEffects(strict: false)
  }

  /// A card's only line can't stay hidden, since it has no Show in Chart.
  @Test
  func aLoneLineIsShown() {
    var state = CardEditorFeature.State(typeID: heartRate)
    state.addSeries()
    state.draft.series[0].hidden = true
    state.removeSeries(id: "b")
    #expect(state.draft.series.map(\.hidden) == [false])
  }

  /// A goal is in the lead's unit: a type of another unit, or a count, clears it.
  @Test
  func aGoalClearsWithItsUnit() async {
    let store = newCard()
    await store.send(.typeChosen(series: "a", type: weight))
    await store.send(.goalChanged(70))
    await store.send(.typeChosen(series: "a", type: "HKQuantityTypeIdentifierLeanBodyMass"))
    #expect(store.state.draft.chart.goal == CardSpec.Goal(value: 70))
    await change(store) { $0.aggregation = .count }
    #expect(store.state.draft.chart.goal == nil)
    await store.skipInFlightEffects(strict: false)
  }

  /// No series past 4 visible lines, and a difference only of two series in one unit.
  @Test
  func seriesAndDifferencesFitTheRules() {
    var state = CardEditorFeature.State(typeID: heartRate)
    state.addSeries()
    state.addSeries()
    state.addFormula(.movingAverage)
    #expect(!state.canAddSeries)

    state = CardEditorFeature.State(typeID: heartRate)
    state.addSeries()
    state.draft.series[1].aggregation = .count
    #expect(!state.canAddFormula(.difference))
    state.addSeries()
    state.addFormula(.difference)
    #expect(state.draft.formulas.map(\.operation) == [.difference(of: "a", minus: "c")])
  }

  // MARK: - Errors

  /// What the controls can't rule out shows under the field it's about, in the editor's words.
  @Test
  func errorsShowUnderTheirFields() throws {
    var state = CardEditorFeature.State(typeID: weight)
    state.addFormula(.movingAverage)
    state.draft.series[0].label = String(repeating: "a", count: 41)
    state.draft.series[0].window = .timeOfDay(
      CardTimeOfDay(from: CardClockTime("08:00")!, to: CardClockTime("08:00")!))
    state.draft.chart.goal = CardSpec.Goal(value: -1)
    state.validate()
    #expect(
      state.errors(for: .series("a", .label)) == ["Label must be 1 to 40 characters (it's 41)."])
    #expect(
      state.errors(for: .series("a", .window)) == [
        "From and To can't be the same time. To can be earlier than From, to cross midnight."
      ])
    #expect(
      state.errors(for: .goal) == ["Goal must be a number of at least 0, in kg (Weight's unit)."])
    #expect(state.spec == nil && !state.canSave)

    // Every line hidden.
    state = CardEditorFeature.State(typeID: weight)
    state.draft.series[0].hidden = true
    state.validate()
    #expect(
      state.errors(for: .seriesList) == [
        "Every series and formula is hidden: leave at least one visible."
      ])

    // A label of spaces is no label.
    state = CardEditorFeature.State(typeID: weight)
    state.draft.series[0].label = "   "
    state.validate()
    #expect(state.errors.isEmpty && state.spec?.series[0].label == nil)
  }

  // MARK: - The preview

  /// Picks show at once; a label, or minutes stepped, once typing stops. Labels don't run the
  /// card again.
  @Test(.timeLimit(.minutes(1)))
  func thePreviewFollowsTypingOnceItStops() async throws {
    let store = newCard()
    await store.send(.typeChosen(series: "a", type: heartRate))
    await change(store) { $0.window = .beforeSleep(minutes: 5) }
    #expect(store.state.preview?.series[0].window == .beforeSleep(minutes: 5))

    await change(store) { $0.window = .beforeSleep(minutes: 6) }
    await change(store) { $0.window = .beforeSleep(minutes: 7) }
    #expect(store.state.preview?.series[0].window == .beforeSleep(minutes: 5))
    #expect(store.state.spec?.series[0].window == .beforeSleep(minutes: 7))
    try await clock.waitUntilAsleep(endingIn: CardEditorFeature.previewDelay)
    clock.advance(by: CardEditorFeature.previewDelay)
    await store.receive(\.previewDebounced)
    #expect(store.state.preview?.series[0].window == .beforeSleep(minutes: 7))

    let before = try #require(store.state.preview)
    var labeled = before
    labeled.series[0].label = "Winding down"
    #expect(labeled.withoutAppearance == before.withoutAppearance)
  }

  // MARK: - Saving

  /// A query the person changed is written as they left it, over one another device changed
  /// meanwhile: the last writer's.
  @Test
  func savingAChangedQueryWritesIt() async throws {
    let database = try HealthDatabase.make()
    let seed = HealthCards.welcomeSeed.map {
      Card(
        id: $0.id, spec: $0.spec, position: $0.position, createdAt: 0, updatedAt: 0, seed: $0.seed)
    }
    let store = TestStore(initialState: CardsFeature.State(cards: seed)) {
      CardsFeature()
    } withDependencies: { [clock] in
      $0.defaultDatabase = database
      $0.continuousClock = clock
      $0.sync.push = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.editCardButtonTapped(id: seed[0].id))
    var changed = seed[0]
    changed.spec?.chart.goal = CardSpec.Goal(value: 10_000)
    await store.send(.cardsLoaded([changed] + seed.dropFirst()))
    await store.send(\.editor.bucketChosen, .day)
    await store.send(\.editor.saveButtonTapped)
    await store.receive(\.editor.delegate.save)
    let saved = try #require(store.state.cards[id: seed[0].id]?.spec)
    #expect(saved.bucket == .day && saved.chart.goal == nil)
    await store.receive(\.pushFinished)
  }
}
