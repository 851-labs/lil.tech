import Foundation
public import OpenAPIRuntime
public import SQLiteData

/// How an app stores one synced entity locally: what to do with an upserted row and with a
/// delete. Apps register their entities with ``LilSyncEngine``; changes to entities nobody
/// registered are skipped (`docs/SYNC.md`).
public struct SyncEntity: Sendable {
  /// The server's entity name, e.g. `health_sample`.
  public let name: String
  let upsert: @Sendable (_ id: String, _ row: OpenAPIObjectContainer, _ db: Database) throws -> Void
  let delete: @Sendable (_ id: String, _ db: Database) throws -> Void

  public init(
    name: String,
    upsert:
      @escaping @Sendable (_ id: String, _ row: OpenAPIObjectContainer, _ db: Database) throws ->
      Void,
    delete: @escaping @Sendable (_ id: String, _ db: Database) throws -> Void
  ) {
    self.name = name
    self.upsert = upsert
    self.delete = delete
  }

  /// An entity whose rows decode as `Row`, usually a generated type such as
  /// `Components.Schemas.HealthSample`. Fields `Row` doesn't know are ignored.
  public static func decoding<Row: Decodable & SendableMetatype>(
    _ name: String,
    as _: Row.Type,
    upsert: @escaping @Sendable (_ row: Row, _ db: Database) throws -> Void,
    delete: @escaping @Sendable (_ id: String, _ db: Database) throws -> Void
  ) -> Self {
    Self(
      name: name,
      upsert: { _, row, db in
        let data = try JSONEncoder().encode(row)
        try upsert(JSONDecoder().decode(Row.self, from: data), db)
      },
      delete: delete
    )
  }
}
