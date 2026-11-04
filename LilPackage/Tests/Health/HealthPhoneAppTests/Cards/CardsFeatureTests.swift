import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthCardStore
import HealthCards
import HealthKitAccess
import HealthUpload
import LilAuth
import LilSync
import LilTestSupport
import SQLiteData
import Testing

@testable import HealthCardEditor
@testable import HealthPhoneApp

private let now = Date(timeIntervalSince1970: 1_760_500_000)
private let nowMilliseconds = 1_760_500_000_000

private func spec(_ name: String) -> CardSpec {
  try! CardSpec(
    input: [
      "version": 1, "display": ["name": .string(name)],
      "series": [["type": "HKQuantityTypeIdentifierHeartRate"]],
    ])
}

/// The account's cards on the iPhone (851-3205): loading until sync has pulled them, then read
/// in Summary's order and followed, and written through sync, a card's whole row at a time.
@Suite(
  .dependencies {
    $0.date.now = now
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(FixedGenerator())
  })
@MainActor
struct CardsFeatureTests {
  let database: any DatabaseWriter
  /// What the feature pushed, in order.
  let pushed = LockIsolated<[[SyncMutation]]>([])

  init() throws {
    database = try HealthCardStore.make()
  }

  private func store(cards: [Card]? = seedCards) -> TestStoreOf<CardsFeature> {
    TestStore(initialState: CardsFeature.State(cards: cards)) {
      CardsFeature.phone
    } withDependencies: { [database, pushed] in
      $0.defaultDatabase = database
      $0.sync.push = { mutations in pushed.withValue { $0.append(mutations) } }
    }
  }

  private func insert(_ cards: [Card]) throws {
    try database.write { db in
      try HealthCard.insert {
        for card in cards {
          HealthCard(
            id: card.id, spec: card.storedSpec.text(), position: card.position,
            createdAt: card.createdAt, updatedAt: card.updatedAt, seed: card.seed)
        }
      }
      .execute(db)
    }
  }

  /// Sync's first pull since signing in, as far as `LilSyncEngine.holds(_:_:)` can tell.
  private func markPulled() throws {
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO "lilSyncState" ("id", "cursor", "epoch", "syncSchema", "entities")
          VALUES (1, 6, 1, 1, 'health_card')
          """)
    }
  }

  /// Before sync's first pull, no cards means they haven't arrived: the cards stay loading, and
  /// can't be written. The seed, pulled, loads them.
  @Test
  func loadsOnceSyncHasPulledTheCards() async throws {
    let store = store(cards: nil)
    let task = await store.send(.task)
    await store.receive(\.cardsLoaded)
    #expect(store.state.isLoading)
    #expect(!store.state.canCreateCard)
    await store.send(.createCard(spec("Too soon")))
    #expect(pushed.value.isEmpty)

    // A bootstrap loading the snapshot's cards: they show, still loading, until it's done.
    try insert(seedCards)
    await store.receive(\.cardsLoaded) {
      $0.cards = IdentifiedArray(uniqueElements: seedCards)
    }
    #expect(store.state.isLoading)
    try markPulled()
    await store.receive(\.cardsLoaded) {
      $0.isLoading = false
    }
    #expect(store.state.canCreateCard)
    await task.cancel()
  }

  /// An account whose cards were all deleted shows none once pulled, rather than loading.
  @Test
  func anAccountWithoutCardsIsLoadedEmpty() async throws {
    try markPulled()
    let store = store(cards: nil)
    let task = await store.send(.task)
    await store.receive(\.cardsLoaded) {
      $0.isLoading = false
    }
    #expect(store.state.cards.isEmpty)
    await task.cancel()
  }

  @Test
  func createsACardAtTheEnd() async throws {
    let store = store()
    var generator = FixedGenerator()
    let id = CardID.make(at: now, using: &generator)
    let new = Card(
      id: id, spec: spec("Resting"), position: "a6", createdAt: nowMilliseconds,
      updatedAt: nowMilliseconds)
    let write = CardsFeature.State.Write(mutations: [try new.upsert()], upserted: [new])

    await store.send(.createCard(spec("Resting"))) {
      $0.cards.append(new)
      $0.unsaved = [write]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(CardID.isValid(id))
    #expect(pushed.value == [write.mutations])
  }

  @Test
  func editsMovesAndDeletesOneCardAtATime() async throws {
    let store = store()
    let edited = try seedCards[1].edited(spec("Heart, asleep"), now: now)
    await store.send(.updateCard(id: seedCards[1].id, spec: spec("Heart, asleep"))) {
      $0.cards[id: edited.id] = edited
      $0.unsaved = [.init(mutations: [try edited.upsert()], upserted: [edited])]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }

    // Steps, moved below Heart Rate: one write, of Steps alone.
    var steps = seedCards[0]
    steps.position = "a1V"
    steps.updatedAt = nowMilliseconds
    await store.send(.moveCards(fromOffsets: [0], toOffset: 2)) {
      $0.cards = IdentifiedArray(
        uniqueElements: [edited, steps] + seedCards[2...])
      $0.unsaved = [.init(mutations: [try steps.upsert()], upserted: [steps])]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }

    await store.send(.deleteCard(id: "card_seed_weight")) {
      $0.cards.remove(id: "card_seed_weight")
      $0.unsaved = [.init(mutations: [seedCards[5].delete], deleted: ["card_seed_weight"])]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(pushed.value.map { $0.map(\.id) } == [[edited.id], [steps.id], ["card_seed_weight"]])
  }

  @Test
  func refusesAHundredAndFirstCardAndInvalidSpecs() async throws {
    let cards = (0..<HealthCards.maxCards).map { index in
      Card(
        id: "card_\(index)", spec: spec("\(index)"), position: "a\(index)", createdAt: 1,
        updatedAt: 1)
    }
    let full = store(cards: cards)
    #expect(!full.state.canCreateCard)
    await full.send(.createCard(spec("One more"))) {
      $0.writeError = .tooManyCards
    }
    await full.send(.writeErrorDismissed) {
      $0.writeError = nil
    }

    var invalid = spec("Heart")
    invalid.display.name = String(repeating: "x", count: 41)
    let store = store()
    await store.send(.updateCard(id: seedCards[1].id, spec: invalid)) {
      $0.writeError = .invalidSpec(
        try #require(
          #expect(throws: CardSpecValidationError.self) { try CardSpec(input: invalid.json) }))
    }
    await store.send(.updateCard(id: "card_gone", spec: spec("Gone"))) {
      $0.writeError = .notFound
    }
    #expect(pushed.value.isEmpty)
  }
}

/// The iPhone syncs the account's cards while signed in (851-3205), whatever Health consent and
/// access are, and deletes them when it signs out.
@MainActor
@Suite(.dependencies)
struct AppFeatureCardSyncTests {
  @Test
  func syncsCardsWhileSignedInAndDeletesThemOnSigningOut() async throws {
    let events = LockIsolated<[String]>([])
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.accountDevices = AccountDevices { 0 }
      $0.healthAuthorization.isAvailable = { false }
      // Not given: cards sync all the same.
      $0.healthConsent.isGiven = { false }
      $0.sync.run = {
        events.withValue { $0.append("run") }
        try? await Task.never()
        events.withValue { $0.append("run stopped") }
      }
      $0.sync.listen = { _ in
        events.withValue { $0.append("listen") }
        try? await Task.never()
        events.withValue { $0.append("listen stopped") }
      }
      $0.sync.removeLocalData = { events.withValue { $0.append("removed") } }
    }
    // Only what's about cards: consent and the other checks have their own tests.
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.signedInChanged(true))
    try await eventually { events.value.sorted() == ["listen", "run"] }
    // Signed in again (the session's updates repeat it): sync carries on, rather than starting
    // over.
    await store.send(.signedInChanged(true))
    #expect(events.value.count(where: { $0 == "run" }) == 1)
    // Back in front: a new pull, which a failure's backoff in the last one can't hold up.
    await store.send(.returnedToForeground)
    try await eventually {
      events.value.count(where: { $0 == "run" }) == 2 && events.value.contains("run stopped")
    }
    #expect(events.value.count(where: { $0 == "listen" }) == 1)

    await store.send(.cards(.cardsLoaded(seedCards, isSynced: true))) {
      $0.cards.cards = IdentifiedArray(uniqueElements: seedCards)
      $0.cards.isLoading = false
    }
    await store.send(.signedInChanged(false)) {
      $0.cards = CardsFeature.State()
    }
    await store.receive(\.signIn.readyToSignIn)
    #expect(events.value.contains("removed"))
    try await eventually {
      events.value.contains("run stopped") && events.value.contains("listen stopped")
    }
  }
}
