import Foundation
public import OpenAPIRuntime
public import SQLiteData

/// How an app stores one synced entity locally: what to do with an upserted row, a delete, and a
/// bootstrap that replaces everything. Apps register their entities with ``LilSyncEngine``;
/// changes to entities nobody registered are skipped (`docs/SYNC.md`).
public struct SyncEntity: Sendable {
  /// The server's entity name, e.g. `health_sample`.
  public let name: String
  let upsert: @Sendable (_ id: String, _ row: OpenAPIObjectContainer, _ db: Database) throws -> Void
  let delete: @Sendable (_ id: String, _ db: Database) throws -> Void
  /// Deletes every local record of the entity, before a snapshot is loaded.
  let clear: @Sendable (_ db: Database) throws -> Void
  /// Stores one record of a snapshot: a JSON line with `id` and the row's fields.
  let load: @Sendable (_ record: Data, _ db: Database) throws -> Void

  public init(
    name: String,
    upsert:
      @escaping @Sendable (_ id: String, _ row: OpenAPIObjectContainer, _ db: Database) throws ->
      Void,
    delete: @escaping @Sendable (_ id: String, _ db: Database) throws -> Void,
    clear: @escaping @Sendable (_ db: Database) throws -> Void
  ) {
    self.name = name
    self.upsert = upsert
    self.delete = delete
    self.clear = clear
    let decoder = JSONDecoder()
    self.load = { record, db in
      let row = try decoder.decode(OpenAPIObjectContainer.self, from: record)
      guard let id = row.value["id"] as? String else {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No id"))
      }
      try upsert(id, row, db)
    }
  }

  /// An entity whose rows decode as `Row`, usually a generated type such as
  /// `Components.Schemas.HealthSample`. Fields `Row` doesn't know are ignored.
  public static func decoding<Row: Decodable & SendableMetatype>(
    _ name: String,
    as _: Row.Type,
    upsert: @escaping @Sendable (_ row: Row, _ db: Database) throws -> Void,
    delete: @escaping @Sendable (_ id: String, _ db: Database) throws -> Void,
    clear: @escaping @Sendable (_ db: Database) throws -> Void
  ) -> Self {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    var entity = Self(
      name: name,
      upsert: { _, row, db in
        try upsert(decoder.decode(Row.self, from: encoder.encode(row)), db)
      },
      delete: delete,
      clear: clear
    )
    // Snapshot records decode straight into `Row`, without going through a container.
    entity.loadDecoding = { record, db in try upsert(decoder.decode(Row.self, from: record), db) }
    return entity
  }

  /// Like ``decoding(_:as:upsert:delete:clear:)``, for an entity kept in one table, `table`,
  /// whose snapshots load faster (851-2859): their records go to a staging table without indexes
  /// first, with `insert`, then into `table` all at once, in its primary key's order, with its
  /// other indexes built afterwards. Loaded one at a time instead, records with random IDs land
  /// all over the primary key's index, so each batch rewrote most of it, and loading slowed down
  /// as the table grew.
  ///
  /// - Parameter insert: Inserts a row into the table named by its second argument, which has
  ///   `table`'s columns and no constraints, or upserts it into `table` itself.
  public static func decoding<Row: Decodable & SendableMetatype>(
    _ name: String,
    as _: Row.Type,
    table: String,
    insert: @escaping @Sendable (_ row: Row, _ staging: String, _ db: Database) throws -> Void,
    upsert: @escaping @Sendable (_ row: Row, _ db: Database) throws -> Void,
    delete: @escaping @Sendable (_ id: String, _ db: Database) throws -> Void,
    clear: @escaping @Sendable (_ db: Database) throws -> Void
  ) -> Self {
    var entity = decoding(name, as: Row.self, upsert: upsert, delete: delete, clear: clear)
    let decoder = JSONDecoder()
    entity.table = table
    entity.stageDecoding = { record, staging, db in
      try insert(decoder.decode(Row.self, from: record), staging, db)
    }
    return entity
  }

  private var loadDecoding: (@Sendable (_ record: Data, _ db: Database) throws -> Void)?

  /// The entity's table, if its snapshots load through a staging table.
  private(set) var table: String?
  private var stageDecoding:
    (@Sendable (_ record: Data, _ staging: String, _ db: Database) throws -> Void)?

  func loadRecord(_ record: Data, _ db: Database) throws {
    try (loadDecoding ?? load)(record, db)
  }

  /// Stores a snapshot record in `staging`, the entity's staging table.
  func stageRecord(_ record: Data, in staging: String, _ db: Database) throws {
    guard let stageDecoding else { return try loadRecord(record, db) }
    try stageDecoding(record, staging, db)
  }
}
