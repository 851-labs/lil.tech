public import Foundation
import GRDB
import LilAPI
public import LilSync
import OpenAPIRuntime
public import SQLiteData

// The account's cards as both apps keep them (851-3204, 851-3205, docs/decisions/cards.md): the
// synced `healthCards` table, its `health_card` sync entity, and reading it in Summary's order.
// The Mac keeps the table in its health database; the iPhone, which syncs nothing else, in a
// database of its own (`HealthCardStore.make(at:)`).

/// One of Summary's cards (851-3204), a `health_card` record: synced, so every Mac and iPhone
/// shows the same cards, and written through ``SyncClient/push`` as whole rows. Features read
/// them as ``Card``s.
@Table
public struct HealthCard: Equatable, Identifiable, Sendable {
  /// `card_` and a ULID, or a seed card's fixed ID (`card_seed_steps`).
  public let id: String
  /// The card spec, as JSON text: canonical, of any version, since a later version's is kept
  /// and written back as it is.
  public var spec: String
  /// Summary's order: a fractional index (`CardPosition`), ascending by its bytes, ties by ID.
  public var position: String
  public var createdAt: Int
  public var updatedAt: Int
  /// The seed card it started as (`steps`), else `nil`.
  public var seed: String?

  public init(
    id: String, spec: String, position: String, createdAt: Int, updatedAt: Int,
    seed: String? = nil
  ) {
    self.id = id
    self.spec = spec
    self.position = position
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.seed = seed
  }
}

/// The cards' table, sync entity and queries, shared by the Mac and the iPhone.
public enum HealthCardStore {
  /// Registers the `healthCards` table's migration. The Mac's health database registers it among
  /// its own, where it shipped; the iPhone's card database after LilSync's (``migrator``).
  ///
  /// Ordered by `position` then `id`, each by its bytes (SQLite's BINARY collation), as every
  /// device orders them; a table of at most 200 needs no index for it.
  public static func registerMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("Create health cards") { db in
      try #sql(
        """
        CREATE TABLE "healthCards" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "spec" TEXT NOT NULL,
          "position" TEXT NOT NULL,
          "createdAt" INTEGER NOT NULL,
          "updatedAt" INTEGER NOT NULL,
          "seed" TEXT
        ) STRICT
        """
      )
      .execute(db)
    }
  }

  /// Every migration of a database that keeps only cards, as the iPhone's does: LilSync's, then
  /// the cards table.
  public static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    LilSyncEngine.registerMigrations(in: &migrator)
    registerMigrations(in: &migrator)
    return migrator
  }

  /// Opens and migrates a database that keeps only cards at `url`, or in memory without one
  /// (tests, catalogs).
  public static func make(at url: URL? = nil) throws -> any DatabaseWriter {
    let database: any DatabaseWriter =
      if let url {
        try DatabasePool(path: url.path(percentEncoded: false))
      } else {
        try DatabaseQueue()
      }
    try migrator.migrate(database)
    return database
  }

  /// `health_card`, stored in `healthCards`, for ``LilSyncEngine``. Its snapshots load record by
  /// record, without a staging table: an account keeps at most 200 cards.
  public static let syncEntity = SyncEntity.decoding(
    Card.entity, as: Components.Schemas.HealthCard.self,
    upsert: { row, db in
      let card = HealthCard(
        id: row.id, spec: try json(row.spec), position: row.position, createdAt: row.createdAt,
        updatedAt: row.updatedAt, seed: row.seed)
      try HealthCard.upsert { card }.execute(db)
    },
    delete: { id, db in try HealthCard.find(id).delete().execute(db) },
    clear: { db in try HealthCard.delete().execute(db) }
  )

  private static let encoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// A spec as JSON text, keys sorted, as the Mac stores JSON fields: `null` when it's missing.
  static func json(_ value: OpenAPIValueContainer?) throws -> String {
    guard let value, value.value != nil else { return "null" }
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  /// The account's cards, in Summary's order.
  public static func cards(_ db: Database) throws -> [Card] {
    try HealthCard.order { ($0.position, $0.id) }.fetchAll(db).map(Card.init)
  }

  /// The cards now, then each time they change: this device's writes, and other devices' and
  /// agents' as sync brings them.
  public static func cardUpdates(
    in database: any DatabaseReader
  ) -> AsyncThrowingStream<[Card], any Error> {
    updates(of: cards, in: database)
  }

  /// The cards and whether the local data holds them yet (`LilSyncEngine.holds(_:_:)`: before
  /// the first pull, an empty table doesn't mean the account has none), now and at each change.
  public static func syncedCardUpdates(
    in database: any DatabaseReader
  ) -> AsyncThrowingStream<SyncedCards, any Error> {
    updates(
      of: { db in
        SyncedCards(cards: try cards(db), isSynced: try LilSyncEngine.holds(Card.entity, db))
      }, in: database)
  }

  private static func updates<Value: Equatable & Sendable>(
    of fetch: @escaping @Sendable (Database) throws -> Value, in database: any DatabaseReader
  ) -> AsyncThrowingStream<Value, any Error> {
    let values = ValueObservation.tracking(fetch).removeDuplicates().values(in: database)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await value in values { continuation.yield(value) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

/// The cards as stored, and whether sync has brought them yet.
public struct SyncedCards: Equatable, Sendable {
  public var cards: [Card]
  /// Whether the local data holds the account's cards: sync has pulled since signing in. Until
  /// then, no cards means they haven't arrived, not that there are none.
  public var isSynced: Bool

  public init(cards: [Card], isSynced: Bool) {
    self.cards = cards
    self.isSynced = isSynced
  }
}
