import Dependencies
import Foundation
import HealthCards
import LilAPI
import LilSync
import LilTestSupport
import OpenAPIRuntime
import SQLiteData
import Testing

@testable import HealthDatabase

private let now = Date(timeIntervalSince1970: 1_760_500_000)
private let nowMilliseconds = 1_760_500_000_000

/// The seed's six cards, as pulled.
private let seedCards = HealthCards.welcomeSeed.map {
  Card(
    id: $0.id, spec: $0.spec, position: $0.position, createdAt: 1_760_400_000_000,
    updatedAt: 1_760_400_000_000, seed: $0.seed)
}

private func spec(_ name: String, type: String = "HKQuantityTypeIdentifierHeartRate") -> CardSpec {
  try! CardSpec(input: [
    "version": 1, "display": ["name": .string(name)], "series": [["type": .string(type)]],
  ])
}

private func card(_ id: String, at position: String) -> Card {
  Card(
    id: id, spec: spec(id), position: position, createdAt: 1_760_400_000_000,
    updatedAt: 1_760_400_000_000)
}

/// Writing cards (851-3204): validated whole rows, the apps' limits, and one write per move.
struct CardWritesTests {
  @Test
  func aNewCardGoesAtTheEnd() throws {
    var generator = SplitMix64(seed: "cards")
    let id = CardID.make(at: now, using: &generator)
    let new = try Card.new(spec("Resting"), after: seedCards, id: id, now: now)
    #expect(new.position == "a6")
    #expect(new.createdAt == nowMilliseconds)
    #expect(new.updatedAt == nowMilliseconds)
    #expect(new.seed == nil)
    #expect(try Card.new(spec("First"), after: [], id: id, now: now).position == "a0")
  }

  @Test
  func aHundredAndFirstCardIsRefused() {
    let cards = (0..<HealthCards.maxCards).map { card("c\($0)", at: "a\($0)") }
    #expect(throws: CardWriteError.tooManyCards) {
      try Card.new(spec("One more"), after: cards, id: "card_x", now: now)
    }
    #expect(
      CardWriteError.tooManyCards.errorDescription
        == "You have 100 cards, the most lil health keeps. Delete one first.")
  }

  @Test
  func specsAreValidatedAsAppsWriteThem() throws {
    var invalid = spec("Heart")
    invalid.display.name = String(repeating: "x", count: 41)
    let error = try #require(
      #expect(throws: CardWriteError.self) {
        try Card.new(invalid, after: [], id: "card_x", now: now)
      })
    guard case .invalidSpec(let errors) = error else { throw error }
    #expect(errors.errors.map(\.code) == [.nameLength])

    // Over the apps' 8 KB, though the store would take it: four series, each filtered by ten
    // long sources.
    var large = spec("Heart")
    large.series = (0..<4).map { index in
      CardSpec.Series(
        id: ["a", "b", "c", "d"][index], type: "HKQuantityTypeIdentifierHeartRate",
        aggregation: .avg,
        filter: CardSpec.Filter(
          sources: (0..<10).map { String(repeating: "\($0)", count: 200) }))
    }
    let tooLarge = try #require(
      #expect(throws: CardWriteError.self) {
        try Card.new(large, after: [], id: "card_x", now: now)
      })
    guard case .invalidSpec(let sizes) = tooLarge else { throw tooLarge }
    #expect(sizes.errors.map(\.code) == [.tooLarge])
  }

  @Test
  func anEditKeepsTheCardsPlaceCreationAndSeed() throws {
    let edited = try seedCards[1].edited(spec("Heart, asleep"), now: now)
    #expect(edited.spec?.display.name == "Heart, asleep")
    #expect(edited.storedSpec == spec("Heart, asleep").json)
    #expect(edited.position == "a1")
    #expect(edited.createdAt == 1_760_400_000_000)
    #expect(edited.updatedAt == nowMilliseconds)
    #expect(edited.seed == "heart_rate")
  }

  @Test
  func aCardOfALaterVersionCantBeEditedButMovesAsItIs() throws {
    let later = #"{"version":2,"display":{"name":"From the future"},"series":[]}"#
    let card = Card(
      HealthCard(
        id: "card_seed_steps", spec: later, position: "a0", createdAt: 1, updatedAt: 1,
        seed: "steps"))
    #expect(card.spec == nil)
    #expect(throws: CardWriteError.unreadable) { try card.edited(spec("Steps"), now: now) }

    let moved = try Card.moving(
      [card, seedCards[1]], fromOffsets: [0], toOffset: 2, now: now)
    #expect(moved.map(\.id) == ["card_seed_steps"])
    let row = try #require(try moved[0].upsert().row)
    let stored = try JSONDecoder().decode(
      CardJSON.self,
      from: JSONEncoder().encode(OpenAPIValueContainer(unvalidatedValue: row.value["spec"] ?? nil)))
    #expect(stored == (try CardJSON(parsing: Data(later.utf8))))
  }

  @Test
  func anUpsertIsTheWholeRow() throws {
    for card in [seedCards[0], card("card_01JCARD0000000000000000000", at: "a6")] {
      let mutation = try card.upsert()
      #expect(mutation.entity == "health_card")
      #expect(mutation.op == .upsert)
      #expect(mutation.id == card.id)
      let row = try #require(mutation.row)
      #expect(Set(row.value.keys) == ["spec", "position", "createdAt", "updatedAt", "seed"])
      let text = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
      #expect(text.contains(card.seed.map { #""seed":"\#($0)""# } ?? #""seed":null"#))
    }
    #expect(seedCards[0].delete == .delete("health_card", id: "card_seed_steps"))
  }

  @Test
  func aMoveWritesOnlyTheMovedCards() throws {
    func move(_ source: IndexSet, _ destination: Int, in cards: [Card] = seedCards) throws
      -> [String: String]
    {
      let moved = try Card.moving(cards, fromOffsets: source, toOffset: destination, now: now)
      #expect(moved.allSatisfy { $0.updatedAt == nowMilliseconds })
      // The order they make, by position.
      var all = cards
      for card in moved { all[all.firstIndex { $0.id == card.id }!] = card }
      let order = all.sorted { $0.precedes($1) }.map(\.id)
      var expected = cards.map(\.id)
      let ids = source.map { expected[$0] }
      expected.removeAll { ids.contains($0) }
      expected.insert(contentsOf: ids, at: destination - source.count(where: { $0 < destination }))
      #expect(order == expected)
      return Dictionary(uniqueKeysWithValues: moved.map { ($0.id, $0.position) })
    }
    // Down one: between the next two.
    #expect(try move([0], 2) == ["card_seed_steps": "a1V"])
    // To the top, and to the end.
    #expect(try move([3], 0) == ["card_seed_walking_running_distance": "Zz"])
    #expect(try move([0], 6) == ["card_seed_steps": "a6"])
    // Several at once, together at the destination.
    #expect(
      try move([0, 2], 5)
        == ["card_seed_steps": "a4G", "card_seed_active_energy": "a4V"])
    // In place: nothing to write.
    #expect(try move([2], 2).isEmpty)
    #expect(try move([2], 3).isEmpty)

    // Two devices added a card at once, at the same position: a card moved between them goes
    // after both, and the second is rewritten after it, so the order is the one asked for.
    let tied = [
      card("card_a", at: "a0"), card("card_b", at: "a1"), card("card_c", at: "a1"),
      card("card_d", at: "a2"),
    ]
    #expect(try move([0], 2, in: tied) == ["card_a": "a1G", "card_c": "a1V"])
  }

  @Test
  func cardsComeInPositionOrderThenByID() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      for (id, position) in [
        ("card_b", "a1"), ("card_a", "a1"), ("card_c", "Zz"), ("card_d", "a0V"),
      ] {
        try HealthCard.insert {
          HealthCard(
            id: id, spec: spec(id).jsonText, position: position, createdAt: 1, updatedAt: 1)
        }
        .execute(db)
      }
    }
    let cards = try database.read { try HealthDatabase.cards($0) }
    #expect(cards.map(\.id) == ["card_c", "card_d", "card_a", "card_b"])
    #expect(cards.map(\.spec?.display.name) == ["card_c", "card_d", "card_a", "card_b"])
  }
}

/// Syncing cards (851-3204): pulled into `healthCards`, written through `LilSyncEngine.push` as
/// whole rows, the last writer winning per card, and caught up by a Mac synced before cards.
@Suite
struct CardSyncTests {
  let server = CardSyncServer()
  let database: any DatabaseWriter

  init() throws {
    database = try HealthDatabase.make()
  }

  private func engine() -> LilSyncEngine {
    withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.continuousClock = RecordingClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SplitMix64(seed: "cards"))
      $0.date.now = now
    } operation: {
      LilSyncEngine(
        entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema,
        partsDirectory: URL.temporaryDirectory.appending(path: "lilsync-\(UUID().uuidString)"))
    }
  }

  private func cards() throws -> [Card] {
    try database.read { try HealthDatabase.cards($0) }
  }

  /// A Mac signed in and synced: the seed's six cards at 1 to 6.
  private func synced() async throws -> LilSyncEngine {
    server.seed()
    let engine = engine()
    try await engine.bootstrap()
    try await engine.pull()
    #expect(try cards() == seedCards)
    server.state.withValue { $0.pushes = [] }
    return engine
  }

  /// An update to a release that stores cards: the Mac's database, synced by the release before,
  /// is migrated, and its first pull catches up `health_card` by itself (851-3222): the seed,
  /// skipped by the release before, then another device's edit, without a bootstrap.
  @Test
  func anUpgradedDatabaseCatchesUpCards() async throws {
    let database = try DatabaseQueue()
    let migrator = HealthDatabase.migrator
    try migrator.migrate(database, upTo: "Retire health pins")
    let before = HealthDatabase.syncEntities.map(\.name).filter { $0 != "health_card" }
    let sample = "6f1c2a40-0000-4000-8000-000000000001"
    server.state.withValue {
      $0.append(
        "health_sample", sample, op: "upsert",
        row: try? JSONDecoder().decode(
          OpenAPIObjectContainer.self,
          from: Data(
            #"""
            {"type": "HKQuantityTypeIdentifierStepCount", "startDate": 1760400000000,
             "endDate": 1760400600000, "value": 412, "unit": "count",
             "sourceName": "Test iPhone", "sourceBundleId": "com.example"}
            """#.utf8)))
    }
    server.seed()
    // The release before pulled to 7, storing the sample and skipping the cards.
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO "healthSamples" ("id", "type", "startDate", "endDate", "value", "unit",
            "sourceName", "sourceBundleID")
          VALUES (?, 'HKQuantityTypeIdentifierStepCount', 1760400000000, 1760400600000, 412,
            'count', 'Test iPhone', 'com.example')
          """, arguments: [sample])
      try db.execute(
        sql: """
          INSERT INTO "lilSyncState" ("id", "cursor", "epoch", "syncSchema", "entities")
          VALUES (1, 7, 1, ?, ?)
          """, arguments: [HealthDatabase.syncSchema, before.sorted().joined(separator: ",")])
    }
    try migrator.migrate(database)
    var steps = HealthCards.welcomeSeed[0].spec
    steps.display.name = "Daily Steps"
    server.write(("card_seed_steps", steps, "a0", nowMilliseconds, "steps"))

    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.continuousClock = RecordingClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SplitMix64(seed: "cards"))
      $0.date.now = now
    } operation: {
      LilSyncEngine(entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema)
    }
    try await engine.pull()

    let cards = try await database.read { try HealthDatabase.cards($0) }
    var expected = seedCards
    expected[0].spec = steps
    expected[0].storedSpec = steps.json
    expected[0].updatedAt = nowMilliseconds
    #expect(cards == expected)
    // Only the cards' changes up to the cursor, then the pull from it: no bootstrap, and the
    // sample stayed.
    #expect(server.state.snapshotRequests == 1)
    #expect(server.state.pulls.map(\.after) == [0, 7])
    #expect(server.state.pulls.map(\.entities) == ["health_card", nil])
    let (samples, entities) = try await database.read { db in
      (
        try HealthSample.fetchCount(db),
        try String.fetchOne(db, sql: #"SELECT "entities" FROM "lilSyncState""#)
      )
    }
    #expect(samples == 1)
    #expect(entities == HealthDatabase.syncEntities.map(\.name).sorted().joined(separator: ","))
  }

  /// A write shows at once, and reaches the server as the card's whole row with the next pull.
  @Test
  func aWriteIsLocalAtOnceThenPushedAsAWholeRow() async throws {
    let engine = try await synced()
    let new = try Card.new(
      spec("Resting"), after: seedCards, id: "card_01JCARD0000000000000000000", now: now)
    try await engine.push([try new.upsert()])
    #expect(try cards() == seedCards + [new])
    #expect(server.state.pushes.isEmpty)

    try await engine.pull()
    let pushed = try #require(server.state.pushes.first)
    #expect(pushed.map(\.id) == [new.id])
    #expect(pushed.map(\.op) == ["upsert"])
    #expect(
      Set(try #require(pushed.first?.row).value.keys)
        == ["spec", "position", "createdAt", "updatedAt", "seed"])
    #expect(try cards() == seedCards + [new])
  }

  /// Another device's edit that reaches the server after this Mac's wins: the server's order of
  /// arrival decides.
  @Test
  func anotherDevicesLaterWriteWins() async throws {
    let engine = try await synced()
    let mine = try seedCards[0].edited(
      spec("Mine", type: "HKQuantityTypeIdentifierStepCount"), now: now)
    var theirs = HealthCards.welcomeSeed[0].spec
    theirs.display.name = "Theirs"
    server.state.withValue { [theirs] state in
      state.afterPush = { state in
        state.append(
          "health_card", "card_seed_steps", op: "upsert",
          row: try? CardSyncServer.row(
            spec: theirs, position: "a0", createdAt: 1_760_400_000_000,
            updatedAt: nowMilliseconds + 1, seed: "steps"))
        state.afterPush = nil
      }
    }
    try await engine.push([try mine.upsert()])
    #expect(try cards()[0].spec?.display.name == "Mine")

    try await engine.pull()
    #expect(try cards()[0].spec?.display.name == "Theirs")
    #expect(try cards()[0].updatedAt == nowMilliseconds + 1)
  }

  /// This Mac's edit that reaches the server after another device's wins, also while the other
  /// device's is pulled first.
  @Test
  func thisMacsLaterWriteWins() async throws {
    let engine = try await synced()
    var theirs = HealthCards.welcomeSeed[0].spec
    theirs.display.name = "Theirs"
    server.write(("card_seed_steps", theirs, "a0", nowMilliseconds - 1, "steps"))
    let mine = try seedCards[0].edited(
      spec("Mine", type: "HKQuantityTypeIdentifierStepCount"), now: now)
    try await engine.push([try mine.upsert()])

    try await engine.pull()
    #expect(try cards()[0] == mine)
    #expect(server.state.changes.last?.id == "card_seed_steps")
  }

  /// An edit to a card another device deleted brings it back, whole, since every write is a whole
  /// row.
  @Test
  func anEditBringsBackACardAnotherDeviceDeleted() async throws {
    let engine = try await synced()
    server.state.withValue { $0.append("health_card", "card_seed_weight", op: "delete") }
    let mine = try seedCards[5].edited(
      spec("Morning Weight", type: "HKQuantityTypeIdentifierBodyMass"), now: now)
    try await engine.push([try mine.upsert()])

    try await engine.pull()
    #expect(try cards() == Array(seedCards.prefix(5)) + [mine])
  }

  /// A delete from another device goes, and so does one from this Mac.
  @Test
  func deletesSync() async throws {
    let engine = try await synced()
    server.state.withValue { $0.append("health_card", "card_seed_weight", op: "delete") }
    try await engine.push([seedCards[0].delete])
    #expect(try cards().map(\.id) == Array(seedCards.dropFirst()).map(\.id))

    try await engine.pull()
    #expect(try cards() == Array(seedCards[1..<5]))
    #expect(server.state.pushes.map { $0.map(\.op) } == [["delete"]])
  }

  /// Signing out deletes the cards with the rest of the account's data, and their writes still
  /// waiting for the server.
  @Test
  func signingOutDeletesCardsAndTheirQueuedWrites() async throws {
    let engine = try await synced()
    let new = try Card.new(
      spec("Resting"), after: seedCards, id: "card_01JCARD0000000000000000000", now: now)
    try await engine.push([try new.upsert()])

    try await engine.removeLocalData()
    let pending = try await database.read { db in
      try Int.fetchOne(db, sql: #"SELECT count(*) FROM "lilPendingMutations""#)
    }
    #expect(try cards().isEmpty)
    #expect(pending == 0)
  }
}
