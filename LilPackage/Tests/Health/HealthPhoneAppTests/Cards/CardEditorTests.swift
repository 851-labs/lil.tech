import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthCardStore
import HealthCards
import HealthKitAccess
import LilSync
import LilTestSupport
import SQLiteData
import Testing

@testable import HealthCardEditor
@testable import HealthPhoneApp

private let now = Date(timeIntervalSince1970: 1_760_500_000)
private let heartRate = "HKQuantityTypeIdentifierHeartRate"

/// The card editor on the iPhone (851-3213): the Mac's editor (`CardEditorFeature`), presented by
/// the iPhone's `CardsFeature`, saving and deleting through its writes, with the filters' choices
/// from HealthKit; swipe to delete asks first, and deleting from the editor closes the card's page.
@Suite(
  .dependencies {
    $0.date.now = now
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(FixedGenerator())
  })
@MainActor
struct CardEditorTests {
  /// What the cards pushed, in order.
  let pushed = LockIsolated<[[SyncMutation]]>([])

  private func store(cards: [Card] = seedCards) throws -> TestStoreOf<CardsFeature> {
    let database = try HealthCardStore.make()
    let store = TestStore(initialState: CardsFeature.State(cards: cards)) {
      CardsFeature.phone
    } withDependencies: { [pushed] in
      $0.defaultDatabase = database
      $0.continuousClock = ManualClock()
      $0.sync.push = { mutations in pushed.withValue { $0.append(mutations) } }
    }
    store.exhaustivity = .off
    return store
  }

  /// New Card: a type picked, then Save, adds the card at the end and closes the editor.
  @Test
  func newCardSavesACardAtTheEnd() async throws {
    let store = try store()
    await store.send(.newCardButtonTapped)
    #expect(store.state.editor?.isNew == true)
    await store.send(\.editor.typeChosen, (series: "a", type: heartRate))
    await store.send(\.editor.saveButtonTapped)
    await store.receive(\.editor.delegate.save)
    #expect(store.state.editor == nil)
    let added = try #require(store.state.cards.last)
    #expect(added.spec?.display.name == "Heart Rate" && added.spec?.series.first?.type == heartRate)
    await store.receive(\.pushFinished)
    #expect(pushed.value.map { $0.map(\.id) } == [[added.id]])
  }

  @Test
  func cancelClosesTheEditorWithoutWriting() async throws {
    let store = try store()
    await store.send(.editCardButtonTapped(id: seedCards[0].id))
    await store.send(\.editor.nameChanged, "Walking")
    await store.send(\.editor.cancelButtonTapped)
    await store.receive(\.editor.dismiss)
    #expect(store.state.editor == nil)
    #expect(pushed.value.isEmpty)
  }

  /// Another device changes the card's query while its editor is open: saving a new color keeps
  /// that query.
  @Test
  func savingKeepsAQueryChangedMeanwhile() async throws {
    let store = try store()
    await store.send(.editCardButtonTapped(id: seedCards[0].id))
    var changed = seedCards[0]
    changed.spec?.chart.goal = CardSpec.Goal(value: 10_000)
    await store.send(
      .cardsLoaded([changed] + seedCards.dropFirst(), isSynced: true))
    await store.send(\.editor.colorChosen, .mint)
    await store.send(\.editor.saveButtonTapped)
    await store.receive(\.editor.delegate.save)
    #expect(store.state.editor == nil)
    let saved = try #require(store.state.cards[id: seedCards[0].id]?.spec)
    #expect(saved.chart.goal == CardSpec.Goal(value: 10_000) && saved.display.color == .mint)
    await store.receive(\.pushFinished)
  }

  /// Another device brought the account to 100 cards while the editor was open: it stays open,
  /// saying why.
  @Test
  func aRefusedSaveKeepsTheEditorOpen() async throws {
    let cards = (0..<HealthCards.maxCards - 1).map { index in
      Card(
        id: "card_\(index)", spec: seedCards[0].spec!, position: "a\(index)", createdAt: 0,
        updatedAt: 0)
    }
    let store = try store(cards: cards)
    await store.send(.newCardButtonTapped)
    let another = Card(
      id: "card_more", spec: seedCards[0].spec!, position: "b0", createdAt: 0, updatedAt: 0)
    await store.send(.cardsLoaded(cards + [another], isSynced: true))
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
  func deletingFromTheEditorAsksFirst() async throws {
    let store = try store()
    await store.send(.editCardButtonTapped(id: seedCards[0].id))
    await store.send(\.editor.deleteButtonTapped)
    #expect(store.state.editor?.alert == .confirmDeleteCard(named: "Steps", .confirmDelete))
    await store.send(\.editor.alert.presented.confirmDelete)
    await store.receive(\.editor.delegate.delete)
    await store.receive(\.deleteCard)
    #expect(store.state.editor == nil && store.state.cards[id: seedCards[0].id] == nil)
    await store.receive(\.pushFinished)
    #expect(pushed.value == [[seedCards[0].delete]])
  }

  /// A row's swipe action asks first, and Cancel keeps the card.
  @Test
  func swipingToDeleteAsksFirst() async throws {
    let store = try store()
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

  /// A card of a later version can't be edited, only deleted.
  @Test
  func aLaterVersionsCardOpensNoEditor() async throws {
    var later = Card(
      id: "card_later", spec: seedCards[0].spec!, position: "b0", createdAt: 0, updatedAt: 0)
    later.spec = nil
    later.storedSpec = ["version": 2, "display": ["name": "Later"]]
    let store = try store(cards: seedCards + [later])
    await store.send(.editCardButtonTapped(id: later.id))
    #expect(store.state.editor == nil)
  }

  /// A series' filter offers the apps and devices this iPhone's HealthKit has for its type.
  @Test
  func filtersOfferHealthKitsSources() async throws {
    let choices = CardFilterChoices(
      apps: [CardFilterChoices.App(id: "com.apple.health.watch", name: "Apple Watch")],
      deviceModels: ["Watch"])
    let asked = LockIsolated<[String]>([])
    let store = try store()
    store.dependencies.healthKitCards = HealthKitCards(
      data: { _, _, _, _, _ in throw CancellationError() },
      headline: { _, _, _ in nil },
      filterChoices: { type in
        asked.withValue { $0.append(type) }
        return choices
      })
    await store.send(.editCardButtonTapped(id: seedCards[1].id))
    await store.send(\.editor.sourcesNeeded, heartRate)
    await store.receive(\.editor.sourcesLoaded)
    #expect(store.state.editor?.sources[heartRate] == choices)
    #expect(asked.value == [heartRate])
  }

  /// Deleting a card here closes its page, which would otherwise say it was deleted.
  @Test
  func deletingACardClosesItsPage() async throws {
    let database = try HealthCardStore.make()
    var state = AppFeature.State(isSignedIn: true)
    state.cards = CardsFeature.State(cards: seedCards)
    state.summaryPath = [.syncStatus, .card(seedCards[0].id)]
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [pushed] in
      $0.defaultDatabase = database
      $0.sync.push = { mutations in pushed.withValue { $0.append(mutations) } }
    }
    store.exhaustivity = .off
    await store.send(.cards(.deleteCard(id: seedCards[0].id)))
    #expect(store.state.summaryPath == [.syncStatus])
    await store.receive(\.cards.pushFinished)
  }
}
