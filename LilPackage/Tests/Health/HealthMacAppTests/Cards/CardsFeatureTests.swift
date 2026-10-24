import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HTTPTypes
import HealthCards
import HealthDatabase
import LilAPI
import LilSync
import LilTestSupport
import OpenAPIRuntime
import SQLiteData
import Testing

@testable import HealthMacApp

private let now = Date(timeIntervalSince1970: 1_760_500_000)
private let nowMilliseconds = 1_760_500_000_000

private let seedCards = HealthCards.welcomeSeed.map {
  Card(
    id: $0.id, spec: $0.spec, position: $0.position, createdAt: 1_760_400_000_000,
    updatedAt: 1_760_400_000_000, seed: $0.seed)
}

private func spec(_ name: String) -> CardSpec {
  try! CardSpec(
    input: [
      "version": 1, "display": ["name": .string(name)],
      "series": [["type": "HKQuantityTypeIdentifierHeartRate"]],
    ])
}

/// A generator whose numbers are always the same.
private struct FixedGenerator: RandomNumberGenerator {
  var value: UInt64 = 0
  mutating func next() -> UInt64 {
    value &+= 0x9e37_79b9_7f4a_7c15
    return value
  }
}

/// The account's cards on the Mac (851-3204): read in Summary's order and followed, and written
/// through sync, a card's whole row at a time.
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
    database = try HealthDatabase.make()
  }

  private func store(cards: [Card]? = seedCards) -> TestStoreOf<CardsFeature> {
    TestStore(initialState: CardsFeature.State(cards: cards)) {
      CardsFeature()
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

  @Test
  func readsTheCardsThenFollowsThem() async throws {
    try insert(seedCards)
    let store = store(cards: nil)
    #expect(!store.state.canCreateCard)

    let task = await store.send(.task)
    await store.receive(\.cardsLoaded) {
      $0.cards = IdentifiedArray(uniqueElements: seedCards)
      $0.isLoading = false
    }
    #expect(store.state.canCreateCard)
    // Another device's card arrives with sync, at the top.
    let pulled = Card(
      id: "card_01JCARD0000000000000000000", spec: spec("Pulled"), position: "Zz",
      createdAt: nowMilliseconds, updatedAt: nowMilliseconds)
    try insert([pulled])
    await store.receive(\.cardsLoaded) {
      $0.cards.insert(pulled, at: 0)
    }
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
    #expect(id.hasPrefix("card_") && CardID.isValid(id))
    #expect(pushed.value == [write.mutations])
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

    let store = store()
    var invalid = spec("Heart")
    invalid.series[0].aggregation = .sum
    await store.send(.updateCard(id: "card_seed_heart_rate", spec: invalid)) {
      $0.writeError = .invalidSpec(
        CardSpecValidationError([
          CardSpecError(
            path: "series[0].aggregation", code: .aggregationNotAllowed,
            message:
              "Heart Rate doesn't add up: use avg, min, max, first, latest or count, not sum.")
        ]))
    }
    // A write that works clears it.
    await store.send(.deleteCard(id: "card_seed_weight")) {
      $0.cards.remove(id: "card_seed_weight")
      $0.writeError = nil
      $0.unsaved = [.init(mutations: [seedCards[5].delete], deleted: ["card_seed_weight"])]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(pushed.value == [[seedCards[5].delete]])
  }

  @Test
  func editsACardInPlace() async throws {
    let store = store()
    let edited = try seedCards[1].edited(spec("Heart, asleep"), now: now)

    await store.send(.updateCard(id: "card_seed_heart_rate", spec: spec("Heart, asleep"))) {
      $0.cards[id: "card_seed_heart_rate"] = edited
      $0.unsaved = [.init(mutations: [try edited.upsert()], upserted: [edited])]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(edited.seed == "heart_rate")
    #expect(edited.position == "a1")
    #expect(pushed.value == [[try edited.upsert()]])

    // One another device deleted meanwhile.
    await store.send(.updateCard(id: "card_gone", spec: spec("Gone"))) {
      $0.writeError = .notFound
    }
  }

  @Test
  func movesACardWritingOnlyIt() async throws {
    let store = store()

    await store.send(.moveCardDown(id: "card_seed_steps"))
    var steps = seedCards[0]
    steps.position = "a1V"
    steps.updatedAt = nowMilliseconds
    await store.receive(\.moveCards) {
      $0.cards = IdentifiedArray(uniqueElements: [seedCards[1], steps] + seedCards[2...])
      $0.unsaved = [.init(mutations: [try steps.upsert()], upserted: [steps])]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(pushed.value == [[try steps.upsert()]])

    // At the edges, nothing moves.
    await store.send(.moveCardUp(id: "card_seed_heart_rate"))
    await store.send(.moveCardDown(id: "card_seed_weight"))

    // Dragged to the top, before Heart Rate's a1.
    var weight = seedCards[5]
    weight.position = "a0"
    weight.updatedAt = nowMilliseconds
    await store.send(.moveCards(fromOffsets: [5], toOffset: 0)) {
      $0.cards.remove(id: "card_seed_weight")
      $0.cards.insert(weight, at: 0)
      $0.unsaved = [.init(mutations: [try weight.upsert()], upserted: [weight])]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(pushed.value.count == 2)
  }

  /// The server keeps the write that arrives last, so writes go to sync one at a time, in the
  /// order they were made, each shown over what's read until it's stored.
  @Test(.timeLimit(.minutes(1)))
  func writesArePushedInOrderAndShownUntilStored() async throws {
    let clock = ManualClock()
    let store = TestStore(initialState: CardsFeature.State(cards: seedCards)) {
      CardsFeature()
    } withDependencies: { [database, pushed] in
      $0.defaultDatabase = database
      // Each push waits, as behind a pull in progress.
      $0.sync.push = { mutations in
        pushed.withValue { $0.append(mutations) }
        try await clock.sleep(for: .seconds(1))
      }
    }

    // Weight up twice, quickly.
    var first = seedCards[5]
    first.position = "a3V"
    first.updatedAt = nowMilliseconds
    await store.send(.moveCardUp(id: "card_seed_weight"))
    await store.receive(\.moveCards) {
      $0.cards = IdentifiedArray(uniqueElements: Array(seedCards[0..<4]) + [first, seedCards[4]])
      $0.unsaved = [.init(mutations: [try first.upsert()], upserted: [first])]
    }
    var second = first
    second.position = "a2V"
    await store.send(.moveCardUp(id: "card_seed_weight"))
    await store.receive(\.moveCards) {
      $0.cards = IdentifiedArray(
        uniqueElements: Array(seedCards[0..<3]) + [second, seedCards[3], seedCards[4]])
      $0.unsaved.append(.init(mutations: [try second.upsert()], upserted: [second]))
    }
    // Only the first is on its way.
    try await clock.waitUntilAsleep(endingIn: .seconds(1))
    #expect(pushed.value == [[try first.upsert()]])

    // Cards read meanwhile, from before either is stored, don't undo them.
    await store.send(.cardsLoaded(seedCards))

    clock.advance(by: .seconds(1))
    await store.receive(\.pushFinished) {
      $0.unsaved.removeFirst()
    }
    try await clock.waitUntilAsleep(endingIn: .seconds(1))
    #expect(pushed.value == [[try first.upsert()], [try second.upsert()]])
    clock.advance(by: .seconds(1))
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
  }

  /// Cards that couldn't be read can't be written: there'd be no end to add one at, nor a limit.
  @Test
  func writesWaitForTheCardsToBeRead() async throws {
    var state = CardsFeature.State()
    state.isLoading = false
    state.loadFailure = "The cards couldn't be read."
    let store = TestStore(initialState: state) {
      CardsFeature()
    }
    #expect(!store.state.canCreateCard)
    await store.send(.createCard(spec("New")))
    await store.send(.updateCard(id: "card_seed_steps", spec: spec("Steps")))
    await store.send(.moveCards(fromOffsets: [0], toOffset: 2))

    let loading = TestStore(initialState: CardsFeature.State()) {
      CardsFeature()
    }
    await loading.send(.createCard(spec("New")))
    await loading.send(.updateCard(id: "card_seed_steps", spec: spec("Steps")))
  }

  /// With the real sync engine and the API's client: a write is in the local table at once, and
  /// the next pull sends the card's whole row.
  @Test
  func writesGoThroughSyncAsWholeRows() async throws {
    try insert(seedCards)
    try await database.write { db in
      try db.execute(
        sql:
          #"INSERT INTO "lilSyncState" ("id", "cursor", "epoch", "syncSchema", "entities") VALUES (1, 6, 1, ?, ?)"#,
        arguments: [
          HealthDatabase.syncSchema,
          HealthDatabase.syncEntities.map(\.name).sorted().joined(separator: ","),
        ])
    }
    let bodies = LockIsolated<[String]>([])
    let api = Client.mock { request, body in
      let json = HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"])
      if request.path == "/v1/sync/mutations" {
        let data = try await Data(collecting: try #require(body), upTo: 1 << 20)
        bodies.withValue { $0.append(String(decoding: data, as: UTF8.self)) }
        return (json, HTTPBody(#"{"seq": 7}"#))
      }
      #expect(request.path?.hasPrefix("/v1/sync/changes?after=6") == true)
      return (
        json,
        HTTPBody(
          try JSONEncoder().encode(
            Components.Schemas.ChangesPage(epoch: 1, changes: [], next: 6, head: 6, hasMore: false))
        )
      )
    }
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = api
      $0.continuousClock = RecordingClock()
    } operation: {
      LilSyncEngine(entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema)
    }
    let store = TestStore(initialState: CardsFeature.State(cards: seedCards)) {
      CardsFeature()
    } withDependencies: { [database] in
      $0.defaultDatabase = database
      $0.sync.push = { try await engine.push($0) }
    }

    await store.send(.moveCardDown(id: "card_seed_steps"))
    var steps = seedCards[0]
    steps.position = "a1V"
    steps.updatedAt = nowMilliseconds
    await store.receive(\.moveCards) {
      $0.cards = IdentifiedArray(uniqueElements: [seedCards[1], steps] + seedCards[2...])
      $0.unsaved = [.init(mutations: [try steps.upsert()], upserted: [steps])]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    let stored = try await database.read { try HealthDatabase.cards($0) }
    #expect(stored == Array(store.state.cards))

    // The pull sends it first. Until the cursor passes its change, it stays over what's pulled.
    try await engine.pull()
    let body = try #require(bodies.value.first)
    let push = try JSONDecoder().decode(
      [String: OpenAPIValueContainer].self, from: Data(body.utf8))
    let mutations = try #require(push["mutations"]?.value as? [(any Sendable)?])
    #expect(mutations.count == 1)
    let mutation = try #require(mutations.first as? [String: (any Sendable)?])
    #expect(mutation["entity"] as? String == "health_card")
    #expect(mutation["id"] as? String == "card_seed_steps")
    let row = try #require(mutation["row"] as? [String: (any Sendable)?])
    #expect(Set(row.keys) == ["spec", "position", "createdAt", "updatedAt", "seed"])
    #expect(row["position"] as? String == "a1V")
    #expect(row["seed"] as? String == "steps")
    #expect(try await database.read { try HealthDatabase.cards($0) } == stored)
  }
}
