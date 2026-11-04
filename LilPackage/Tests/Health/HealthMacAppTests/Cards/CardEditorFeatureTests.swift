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

private let now = Date(timeIntervalSince1970: 1_760_500_000)

private let seedCards = HealthCards.welcomeSeed.map {
  Card(
    id: $0.id, spec: $0.spec, position: $0.position, createdAt: 1_760_400_000_000,
    updatedAt: 1_760_400_000_000, seed: $0.seed)
}

private let heartRate = "HKQuantityTypeIdentifierHeartRate"
private let restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"

/// The card editor (851-3208): a card's name, symbol and color, a live preview, inline errors,
/// and saving and deleting through `CardsFeature`.
@Suite(
  .dependencies {
    $0.date.now = now
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
  })
@MainActor
struct CardEditorFeatureTests {
  /// What the cards pushed, in order.
  let pushed = LockIsolated<[[SyncMutation]]>([])
  let clock = ManualClock()

  private func cardsStore(cards: [Card] = seedCards) throws -> TestStoreOf<CardsFeature> {
    let database = try HealthDatabase.make()
    let store = TestStore(initialState: CardsFeature.State(cards: cards)) {
      CardsFeature.mac
    } withDependencies: { [pushed, clock] in
      $0.defaultDatabase = database
      $0.continuousClock = clock
      $0.sync.push = { mutations in pushed.withValue { $0.append(mutations) } }
    }
    store.exhaustivity = .off
    return store
  }

  // MARK: - The editor

  /// A new card has no spec until its type is picked, then the type's name, symbol and color,
  /// until the person changes them.
  @Test
  func aNewCardFollowsItsTypeUntilChanged() throws {
    var state = CardEditorFeature.State()
    #expect(state.spec == nil && state.errors.isEmpty && state.preview == nil && !state.canSave)

    state.typeChosen(heartRate, series: "a")
    state.validate()
    #expect(state.name == "Heart Rate")
    #expect(state.symbol == "heart.fill" && state.color == .red)
    let spec = try #require(state.spec)
    #expect(spec.series.map(\.type) == [heartRate] && spec.series[0].aggregation == .avg)
    #expect(spec.chart.style == .ranges && spec.bucket == .auto && spec.range == .week)
    #expect(state.canSave)
  }

  @Test
  func choicesShowInThePreviewAtOnce() async {
    let store = TestStore(initialState: CardEditorFeature.State()) {
      CardEditorFeature()
    } withDependencies: { [clock] in
      $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.typeChosen(series: "a", type: heartRate))
    #expect(store.state.preview?.display.name == "Heart Rate")

    await store.send(.colorChosen(.teal))
    await store.send(.symbolChosen("moon.zzz.fill"))
    #expect(store.state.preview?.display.color == .teal)
    #expect(store.state.preview?.display.symbol == "moon.zzz.fill")

    // Chosen by hand, they stay; the name, still the type's, follows the next type.
    await store.send(.typeChosen(series: "a", type: restingHeartRate))
    #expect(store.state.name == "Resting Heart Rate")
    #expect(store.state.color == .teal && store.state.symbol == "moon.zzz.fill")
    #expect(store.state.preview?.series.first?.type == restingHeartRate)

    // A name typed stays too.
    await store.send(.nameChanged("Calm"))
    await store.send(.typeChosen(series: "a", type: heartRate))
    #expect(store.state.name == "Calm")
  }

  /// The preview follows typing once it stops, and keeps the last valid spec meanwhile.
  @Test(.timeLimit(.minutes(1)))
  func thePreviewFollowsTheNameOnceTypingStops() async throws {
    let steps = try #require(CardEditorFeature.State(editing: seedCards[0]))
    let store = TestStore(initialState: steps) {
      CardEditorFeature()
    } withDependencies: { [clock] in
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.nameChanged("Daily"))
    await store.send(.nameChanged("Daily Steps"))
    #expect(store.state.preview?.display.name == "Steps")
    try await clock.waitUntilAsleep(endingIn: CardEditorFeature.previewDelay)
    clock.advance(by: CardEditorFeature.previewDelay)
    await store.receive(\.previewDebounced)
    #expect(store.state.preview?.display.name == "Daily Steps")
    #expect(store.state.spec?.display.name == "Daily Steps" && store.state.canSave)
  }

  /// Errors from `CardSpec(input:)` show under their field, named as the editor names it, and
  /// Save is off while there are any.
  @Test
  func errorsShowUnderTheirFields() throws {
    var state = try #require(CardEditorFeature.State(editing: seedCards[0]))
    #expect(state.errors.isEmpty && !state.canSave)  // Nothing changed yet.

    state.name = "   "
    state.validate()
    #expect(state.errors(for: .name) == ["Name must be 1 to 40 characters (it's 0)."])
    #expect(state.errors(for: .query).isEmpty && state.spec == nil && !state.canSave)

    state.name = String(repeating: "a", count: 41)
    state.validate()
    #expect(state.errors(for: .name) == ["Name must be 1 to 40 characters (it's 41)."])

    state.name = "  Steps Today "
    state.validate()
    #expect(state.errors.isEmpty && state.spec?.display.name == "Steps Today" && state.canSave)
  }

  /// Editing keeps the card's query as it is: only the display changes.
  @Test
  func editingKeepsTheQuery() async throws {
    var spec = try #require(seedCards[1].spec)
    spec.chart.goal = CardSpec.Goal(value: 120)
    spec.display.unit = nil
    let card = Card(id: "card_x", spec: spec, position: "a0", createdAt: 0, updatedAt: 0)
    var state = try #require(CardEditorFeature.State(editing: card))
    state.name = "Pulse"
    state.color = .purple
    state.validate()
    var expected = spec
    expected.display.name = "Pulse"
    expected.display.color = .purple
    #expect(state.spec == expected)
  }

  @Test
  func aLaterVersionsCardCantBeEdited() {
    let card = Card(
      HealthCard(
        id: "card_later", spec: #"{"version":3,"display":{"name":"Later"}}"#, position: "a0",
        createdAt: 0, updatedAt: 0))
    #expect(CardEditorFeature.State(editing: card) == nil)
  }

  // MARK: - Through the cards

  @Test
  func newCardAddsACardAtTheEnd() async throws {
    let store = try cardsStore()
    await store.send(.newCardButtonTapped)
    #expect(store.state.editor?.isNew == true)
    await store.send(\.editor.typeChosen, (series: "a", type: heartRate))
    await store.send(\.editor.saveButtonTapped)
    await store.receive(\.editor.delegate.save)
    #expect(store.state.editor == nil)
    #expect(store.state.cards.count == seedCards.count + 1)
    #expect(store.state.cards.last?.spec?.display.name == "Heart Rate")
    await store.receive(\.pushFinished)
    #expect(pushed.value.count == 1)
  }

  @Test
  func savingAnEditReplacesTheCardsSpec() async throws {
    let store = try cardsStore()
    await store.send(.editCardButtonTapped(id: seedCards[0].id))
    await store.send(\.editor.colorChosen, .mint)
    await store.send(\.editor.saveButtonTapped)
    await store.receive(\.editor.delegate.save)
    #expect(store.state.editor == nil)
    #expect(store.state.cards[id: seedCards[0].id]?.spec?.display.color == .mint)
    #expect(store.state.cards.ids == IdentifiedArray(uniqueElements: seedCards).ids)
    await store.receive(\.pushFinished)
  }

  /// An agent changes the card's query while its editor is open: saving keeps the agent's query
  /// and writes only the name, symbol and color.
  @Test
  func savingKeepsAQueryChangedMeanwhile() async throws {
    let store = try cardsStore()
    await store.send(.editCardButtonTapped(id: seedCards[0].id))
    var changed = seedCards[0]
    changed.spec?.chart.goal = CardSpec.Goal(value: 10_000)
    await store.send(.cardsLoaded([changed] + seedCards.dropFirst()))
    await store.send(\.editor.colorChosen, .mint)
    await store.send(\.editor.saveButtonTapped)
    await store.receive(\.editor.delegate.save)
    let saved = try #require(store.state.cards[id: seedCards[0].id]?.spec)
    #expect(saved.chart.goal == CardSpec.Goal(value: 10_000) && saved.display.color == .mint)
    await store.receive(\.pushFinished)
  }

  /// A unit is part of what a card shows: changing only it writes it.
  @Test
  func savingAUnitWritesIt() async throws {
    let store = try cardsStore()
    let weight = try #require(seedCards.last)
    await store.send(.editCardButtonTapped(id: weight.id))
    await store.send(\.editor.unitChosen, "lb")
    await store.send(\.editor.saveButtonTapped)
    await store.receive(\.editor.delegate.save)
    #expect(store.state.cards[id: weight.id]?.spec?.display.unit == "lb")
    await store.receive(\.pushFinished)
  }

  /// A write that's refused leaves the editor open, saying why: here another device brought the
  /// account to 100 cards while it was open.
  @Test
  func aRefusedSaveKeepsTheEditorOpen() async throws {
    let cards = (0..<HealthCards.maxCards - 1).map { index in
      Card(
        id: "card_\(index)", spec: seedCards[0].spec!, position: "a\(index)", createdAt: 0,
        updatedAt: 0)
    }
    let store = try cardsStore(cards: cards)
    await store.send(.newCardButtonTapped)
    let another = Card(
      id: "card_more", spec: seedCards[0].spec!, position: "b0", createdAt: 0, updatedAt: 0)
    await store.send(.cardsLoaded(cards + [another]))
    #expect(!store.state.canCreateCard)
    await store.send(\.editor.typeChosen, (series: "a", type: heartRate))
    await store.send(\.editor.saveButtonTapped)
    await store.receive(\.editor.delegate.save)
    #expect(
      store.state.editor?.saveError
        == "You have 100 cards, the most lil health keeps. Delete one first.")
    #expect(store.state.writeError == nil && store.state.cards.count == HealthCards.maxCards)
    #expect(pushed.value.isEmpty)
  }

  @Test
  func newCardIsOffAtAHundredCards() async throws {
    let cards = (0..<HealthCards.maxCards).map { index in
      Card(
        id: "card_\(index)", spec: seedCards[0].spec!, position: "a\(index)", createdAt: 0,
        updatedAt: 0)
    }
    let store = try cardsStore(cards: cards)
    await store.send(.newCardButtonTapped)
    #expect(store.state.editor == nil)
  }

  @Test
  func deletingFromTheEditorAsksFirst() async throws {
    let store = try cardsStore()
    await store.send(.editCardButtonTapped(id: seedCards[0].id))
    await store.send(\.editor.deleteButtonTapped)
    #expect(
      store.state.editor?.alert == .confirmDeleteCard(named: "Steps", .confirmDelete))
    await store.send(\.editor.alert.presented.confirmDelete)
    await store.receive(\.editor.delegate.delete)
    await store.receive(\.deleteCard)
    #expect(store.state.editor == nil)
    #expect(store.state.cards[id: seedCards[0].id] == nil)
    await store.receive(\.pushFinished)
    #expect(pushed.value == [[seedCards[0].delete]])
  }

  @Test
  func deletingARowAsksFirst() async throws {
    let store = try cardsStore()
    await store.send(.deleteCardButtonTapped(id: seedCards[1].id))
    #expect(
      store.state.alert
        == .confirmDeleteCard(named: "Heart Rate", .confirmDelete(id: seedCards[1].id)))
    await store.send(\.alert.dismiss)
    #expect(store.state.cards.count == seedCards.count)

    await store.send(.deleteCardButtonTapped(id: seedCards[1].id))
    await store.send(\.alert.presented.confirmDelete, seedCards[1].id)
    await store.receive(\.deleteCard)
    #expect(store.state.cards[id: seedCards[1].id] == nil)
    await store.receive(\.pushFinished)
  }

  /// Deleting a card here closes its page, which would otherwise say it was deleted.
  @Test
  func deletingACardClosesItsPage() async throws {
    let database = try HealthDatabase.make()
    var state = AppFeature.State(
      isSignedIn: true, metricPath: [.card(seedCards[0].id), .metric(heartRate)])
    state.cards = CardsFeature.State(cards: seedCards)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [pushed] in
      $0.defaultDatabase = database
      $0.sync.push = { mutations in pushed.withValue { $0.append(mutations) } }
    }
    store.exhaustivity = .off
    await store.send(.cards(.deleteCard(id: seedCards[0].id)))
    #expect(store.state.metricPath == [.metric(heartRate)])
    await store.receive(\.cards.pushFinished)
  }
}
