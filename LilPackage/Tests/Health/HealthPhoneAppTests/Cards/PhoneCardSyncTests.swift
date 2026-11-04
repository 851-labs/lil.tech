import Dependencies
import Foundation
import GRDB
import HealthCardStore
import HealthCards
import LilAPI
import LilSync
import LilTestSupport
import OpenAPIRuntime
import SQLiteData
import Testing

@testable import HealthPhoneApp

private let now = Date(timeIntervalSince1970: 1_760_500_000)
private let nowMilliseconds = 1_760_500_000_000

private func spec(_ name: String, type: String = "HKQuantityTypeIdentifierHeartRate") -> CardSpec {
  try! CardSpec(input: [
    "version": 1, "display": ["name": .string(name)], "series": [["type": .string(type)]],
  ])
}

/// The iPhone syncing the account's cards alone (851-3205): `health_card` pulled through the
/// change feed's `entities` filter and only its snapshot parts, never the Health records the
/// iPhone uploads; its writes pushed as whole rows, the last to reach the server winning; and
/// deleted on signing out.
@Suite
struct PhoneCardSyncTests {
  let server = PhoneCardServer()
  let database: any DatabaseWriter
  let partsDirectory = URL.temporaryDirectory.appending(path: "lilsync-\(UUID().uuidString)")

  init() throws {
    database = try HealthCardStore.make()
  }

  /// The iPhone's engine, as `prepareCardSync()` makes it.
  private func engine() -> LilSyncEngine {
    withDependencies {
      $0.defaultDatabase = database
      $0.api = server.client
      $0.snapshotDownloader = server.downloader
      $0.continuousClock = RecordingClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(FixedGenerator())
      $0.date.now = now
    } operation: {
      LilSyncEngine(
        entities: PhoneCards.syncEntities, syncSchema: PhoneCards.syncSchema,
        partsDirectory: partsDirectory, filtersChanges: true)
    }
  }

  private func cards() throws -> [Card] {
    try database.read { try HealthCardStore.cards($0) }
  }

  private func holdsCards() throws -> Bool {
    try database.read { try LilSyncEngine.holds(Card.entity, $0) }
  }

  private func cursor() throws -> Int? {
    try database.read { try Int.fetchOne($0, sql: #"SELECT "cursor" FROM "lilSyncState""#) }
  }

  /// Every request for changes asked for cards alone.
  private func expectOnlyCardsPulled(sourceLocation: SourceLocation = #_sourceLocation) {
    let filters = server.state.pulls.map(\.entities)
    #expect(!filters.isEmpty, sourceLocation: sourceLocation)
    #expect(filters.allSatisfy { $0 == Card.entity }, sourceLocation: sourceLocation)
  }

  /// An iPhone that started as a new device does, and pulled the seed among uploads: cards at 4
  /// to 9, samples around them.
  private func synced() async throws -> LilSyncEngine {
    server.uploadSamples(3)
    server.seed()
    server.uploadSamples(2)
    let engine = engine()
    try await engine.bootstrap()
    try await engine.pull()
    #expect(try cards() == seedCards)
    server.state.withValue {
      $0.pulls = []
      $0.pushes = []
    }
    return engine
  }

  /// A new iPhone's first pull: the seed the server wrote, the account's only cards, and none of
  /// its Health records. Before it, the iPhone holds no cards, so Summary shows them loading.
  @Test
  func aNewIPhonesFirstPullReceivesTheSeed() async throws {
    server.uploadSamples(3)
    server.seed()
    server.uploadSamples(2)
    let engine = engine()
    #expect(try !holdsCards())
    // A new device starts from the snapshot (here, the store has none yet), then pulls.
    await #expect(throws: SyncError.needsBootstrap) { try await engine.pull() }
    try await engine.bootstrap()
    #expect(try !holdsCards())
    try await engine.pull()

    #expect(try cards() == seedCards)
    #expect(try holdsCards())
    #expect(try cursor() == 11)
    // One page: the filter skipped the samples, and moved `next` to the head.
    #expect(server.state.pulls.map(\.after) == [0])
    expectOnlyCardsPulled()
  }

  /// A bootstrap downloads only the cards' parts of a snapshot, then pulls only cards after it.
  @Test
  func aBootstrapDownloadsOnlyTheCardsParts() async throws {
    server.uploadSamples(4)
    server.seed()
    try server.publishSnapshot(cards: seedCards, samples: 4)
    server.uploadSamples(3)
    var steps = seedCards[0]
    steps.spec = spec("Daily Steps", type: "HKQuantityTypeIdentifierStepCount")
    steps.storedSpec = steps.spec!.json
    steps.updatedAt = nowMilliseconds
    server.write(steps)

    let engine = engine()
    try await engine.bootstrap()
    #expect(server.state.downloads == ["https://parts.test/health_card"])
    #expect(try cards() == seedCards)
    #expect(try cursor() == 10)

    try await engine.pull()
    #expect(try cards() == [steps] + seedCards.dropFirst())
    #expect(try cursor() == 14)
    #expect(server.state.pulls.map(\.after) == [10])
    expectOnlyCardsPulled()
  }

  /// Later pulls bring only cards: another device's new card, edit and delete, among uploads,
  /// and the cursor still reaches the head.
  @Test
  func pullsOnlyCardsChanges() async throws {
    let engine = try await synced()
    let theirs = Card(
      id: "card_01JCARD0000000000000000000", spec: spec("Sleeping Heart Rate"), position: "a6",
      createdAt: nowMilliseconds, updatedAt: nowMilliseconds)
    server.uploadSamples(3)
    server.write(theirs)
    server.uploadSamples(2)
    server.state.withValue { $0.append(Card.entity, "card_seed_weight", op: "delete") }
    server.uploadSamples(1)

    try await engine.pull()
    #expect(try cards() == Array(seedCards.prefix(5)) + [theirs])
    #expect(try cursor() == server.state.head)
    #expect(server.state.pulls.map(\.after) == [11])
    expectOnlyCardsPulled()
  }

  /// A server from before the filter sends every change: the iPhone skips the Health records,
  /// and keeps up all the same.
  @Test
  func aServerWithoutTheFilterStillSyncsCards() async throws {
    server.state.withValue { $0.ignoresEntities = true }
    let engine = try await synced()
    var heart = seedCards[1]
    heart.spec = spec("Heart, asleep")
    heart.storedSpec = heart.spec!.json
    server.uploadSamples(2)
    server.write(heart)

    try await engine.pull()
    #expect(try cards()[1] == heart)
    #expect(try cursor() == server.state.head)
  }

  /// The iPhone's write shows at once, and reaches the server as the card's whole row.
  @Test
  func aWriteIsLocalAtOnceThenPushedAsAWholeRow() async throws {
    let engine = try await synced()
    let new = try Card.new(
      spec("Resting"), after: seedCards, id: "card_01JCARD0000000000000000000", now: now)
    try await engine.push([try new.upsert()])
    #expect(try cards() == seedCards + [new])

    try await engine.pull()
    let pushed = try #require(server.state.pushes.first)
    #expect(pushed.map(\.id) == [new.id])
    #expect(pushed.map(\.op) == ["upsert"])
    #expect(
      Set(try #require(pushed.first?.row).value.keys)
        == ["spec", "position", "createdAt", "updatedAt", "seed"])
    #expect(try cards() == seedCards + [new])
    expectOnlyCardsPulled()
  }

  /// Another device's edit that reaches the server after the iPhone's wins: the server's order
  /// of arrival decides, not the times the cards carry.
  @Test
  func anotherDevicesLaterWriteWins() async throws {
    let engine = try await synced()
    let mine = try seedCards[0].edited(
      spec("Mine", type: "HKQuantityTypeIdentifierStepCount"), now: now)
    var theirs = seedCards[0]
    theirs.spec = spec("Theirs", type: "HKQuantityTypeIdentifierStepCount")
    theirs.storedSpec = theirs.spec!.json
    theirs.updatedAt = nowMilliseconds - 1
    server.state.withValue { [theirs] state in
      state.afterPush = { state in
        state.append(Card.entity, theirs.id, op: "upsert", row: PhoneCardServer.row(theirs))
        state.afterPush = nil
      }
    }
    try await engine.push([try mine.upsert()])
    #expect(try cards()[0].spec?.display.name == "Mine")

    try await engine.pull()
    #expect(try cards()[0] == theirs)
  }

  /// The iPhone's edit that reaches the server after another device's wins, though the other
  /// device's is pulled first; and an edit to a card another device deleted brings it back,
  /// whole, since every write is a whole row.
  @Test
  func theIPhonesLaterWriteWins() async throws {
    let engine = try await synced()
    var theirs = seedCards[0]
    theirs.spec = spec("Theirs", type: "HKQuantityTypeIdentifierStepCount")
    theirs.storedSpec = theirs.spec!.json
    server.write(theirs)
    server.state.withValue { $0.append(Card.entity, "card_seed_weight", op: "delete") }
    let steps = try seedCards[0].edited(
      spec("Mine", type: "HKQuantityTypeIdentifierStepCount"), now: now)
    let weight = try seedCards[5].edited(
      spec("Morning Weight", type: "HKQuantityTypeIdentifierBodyMass"), now: now)
    try await engine.push([try steps.upsert(), try weight.upsert()])

    try await engine.pull()
    #expect(try cards() == [steps] + seedCards[1..<5] + [weight])
  }

  /// Signing out deletes the account's cards, where sync was, and writes not yet sent, so the
  /// next account's iPhone starts as a new device and gets only its own cards.
  @Test
  func signingOutDeletesTheCardsAndUnsentWrites() async throws {
    let engine = try await synced()
    server.state.withValue { $0.failingPushes = true }
    let new = try Card.new(
      spec("Unsent"), after: seedCards, id: "card_01JCARD0000000000000000000", now: now)
    try await engine.push([try new.upsert()])
    await #expect(throws: SyncError.unavailable) { try await engine.pull() }
    #expect(try cards() == seedCards + [new])

    try await engine.removeLocalData()
    #expect(try cards().isEmpty)
    #expect(try !holdsCards())
    #expect(try cursor() == nil)
    let unsent = try await database.read {
      try Int.fetchOne($0, sql: #"SELECT count(*) FROM "lilPendingMutations""#)
    }
    #expect(unsent == 0)

    // The next account has no cards yet, and nothing of the last one's is pushed to it.
    server.state.withValue {
      $0.changes = []
      $0.failingPushes = false
      $0.pushes = []
    }
    let next = Card(
      id: "card_01JNEXT0000000000000000000", spec: spec("Next"), position: "a0",
      createdAt: nowMilliseconds, updatedAt: nowMilliseconds)
    server.write(next)
    try await engine.bootstrap()
    try await engine.pull()
    #expect(try cards() == [next])
    #expect(server.state.pushes.isEmpty)
  }

  /// Each server's cards are kept apart on a simulator, as its other local data is, and a
  /// device's, which only uses prod, in one folder.
  @Test
  func theDatabaseIsKeptPerServer() {
    let support = URL(filePath: "/support", directoryHint: .isDirectory)
    func path(_ environment: APIEnvironment, allowsOverride: Bool) -> String {
      PhoneCards.directory(
        for: environment, allowsOverride: allowsOverride, applicationSupport: support
      )
      .path(percentEncoded: false)
    }
    #expect(path(.prod, allowsOverride: false) == "/support/Cards/")
    #expect(path(.staging, allowsOverride: true) == "/support/Cards/Servers/api.staging.lil.tech/")
  }

  /// A newer release's database (after a downgrade) starts over too, since GRDB would leave its
  /// migrations alone; a failure that isn't the file's fault doesn't delete it.
  @Test
  func aNewerReleasesDatabaseStartsOver() throws {
    let directory = URL.temporaryDirectory.appending(path: "cards-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let newer = try HealthCardStore.make(at: directory.appending(path: "Cards.sqlite"))
    var migrator = HealthCardStore.migrator
    migrator.registerMigration("From a later release") { db in
      try db.execute(sql: #"CREATE TABLE "later" ("id" INTEGER PRIMARY KEY)"#)
    }
    try migrator.migrate(newer)
    try newer.close()

    let database = PhoneCards.open(in: directory)
    #expect(
      try database.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        .contains("From a later release") == false)
    #expect(PhoneCards.startsOver(after: PhoneCards.NewerSchema()))
    #expect(!PhoneCards.startsOver(after: DatabaseError(resultCode: .SQLITE_FULL)))
    #expect(PhoneCards.startsOver(after: DatabaseError(resultCode: .SQLITE_NOTADB)))
  }

  /// A damaged database is only a copy of the server's cards: it starts over.
  @Test
  func aDamagedDatabaseStartsOver() throws {
    let directory = URL.temporaryDirectory.appending(path: "cards-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not a database".utf8).write(to: directory.appending(path: "Cards.sqlite"))
    let database = PhoneCards.open(in: directory)
    #expect(try database.read { try HealthCardStore.cards($0) }.isEmpty)
    #expect(try database.read { try LilSyncEngine.holds(Card.entity, $0) } == false)
  }
}
