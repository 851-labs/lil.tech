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

    await store.send(.createCard(spec("Resting"))) {
      $0.cards.append(new)
    }
    #expect(id.hasPrefix("card_") && CardID.isValid(id))
    #expect(pushed.value == [[try new.upsert()]])
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
    }
    #expect(pushed.value == [[seedCards[5].delete]])
  }

  @Test
  func editsACardInPlace() async throws {
    let store = store()
    let edited = try seedCards[1].edited(spec("Heart, asleep"), now: now)

    await store.send(.updateCard(id: "card_seed_heart_rate", spec: spec("Heart, asleep"))) {
      $0.cards[id: "card_seed_heart_rate"] = edited
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
    }
    #expect(pushed.value == [[try steps.upsert()]])

    // At the edges, nothing moves.
    await store.send(.moveCardUp(id: "card_seed_heart_rate"))
    await store.send(.moveCardDown(id: "card_seed_weight"))

    // Dragged to the top, before Heart Rate's a1.
    await store.send(.moveCards(fromOffsets: [5], toOffset: 0)) {
      var weight = seedCards[5]
      weight.position = "a0"
      weight.updatedAt = nowMilliseconds
      $0.cards.remove(id: "card_seed_weight")
      $0.cards.insert(weight, at: 0)
    }
    #expect(pushed.value.count == 2)
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
    await store.receive(\.moveCards) {
      var steps = seedCards[0]
      steps.position = "a1V"
      steps.updatedAt = nowMilliseconds
      $0.cards = IdentifiedArray(uniqueElements: [seedCards[1], steps] + seedCards[2...])
    }
    await store.finish()
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
