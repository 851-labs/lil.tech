import Foundation
import IssueReporting
import LilAPI
public import OpenAPIRuntime
import SQLiteData

/// One write an app makes to an entity apps may write, such as a pin (`docs/SYNC.md`).
public struct SyncMutation: Codable, Equatable, Sendable {
  public enum Operation: String, Codable, Sendable {
    case upsert, delete
  }

  /// The server's entity name, e.g. `health_pin`.
  public var entity: String
  public var op: Operation
  public var id: String
  /// An upsert's fields. The whole record, since it's also written to the local table as it is,
  /// though the server merges what's missing.
  public var row: OpenAPIObjectContainer?

  public static func upsert(_ entity: String, id: String, row: OpenAPIObjectContainer) -> Self {
    Self(entity: entity, op: .upsert, id: id, row: row)
  }

  public static func delete(_ entity: String, id: String) -> Self {
    Self(entity: entity, op: .delete, id: id, row: nil)
  }
}

/// Writes waiting for the server, oldest first by row ID (`docs/SYNC.md`). Outside the synced
/// tables, so a bootstrap keeps them. `seq` is set once the server applied them: they're
/// written over pulled changes until the cursor reaches it, so a pull from before doesn't undo
/// them.
@Table("lilPendingMutations")
struct PendingMutation: Equatable {
  /// The `mutationId` sent with them, so a retry isn't applied twice.
  let id: String
  /// The mutations, as JSON.
  var mutations: String
  var seq: Int?
}

extension PendingMutation {
  /// In the order they were made.
  static let oldestFirst = PendingMutation.order { _ in #sql("rowid", as: Int.self) }

  func decoded() throws -> [SyncMutation] {
    try JSONDecoder().decode([SyncMutation].self, from: Data(mutations.utf8))
  }

  /// Writes every pending mutation to the local tables again, in order: after pulled changes
  /// overwrote them, or a bootstrap replaced the tables. Acknowledged ones the cursor has passed
  /// are done, so they're deleted first.
  static func reapply(after cursor: Int, entities: [String: SyncEntity], _ db: Database) throws {
    try PendingMutation.where { $0.seq.lte(Int?.some(cursor)) }.delete().execute(db)
    for pending in try PendingMutation.oldestFirst.fetchAll(db) {
      try apply(try pending.decoded(), entities: entities, db)
    }
  }

  /// Writes `mutations` to the local tables of the entities they're for.
  static func apply(_ mutations: [SyncMutation], entities: [String: SyncEntity], _ db: Database)
    throws
  {
    for mutation in mutations {
      guard let entity = entities[mutation.entity] else {
        reportIssue("No SyncEntity is registered for \(mutation.entity)")
        continue
      }
      switch mutation.op {
      case .upsert:
        // With its ID, as rows come from the server.
        var row = mutation.row?.value ?? [:]
        row["id"] = mutation.id
        try entity.upsert(mutation.id, try OpenAPIObjectContainer(unvalidatedValue: row), db)
      case .delete:
        try entity.delete(mutation.id, db)
      }
    }
  }

  /// The request body for the server.
  func body() throws -> Components.Schemas.PushMutations {
    Components.Schemas.PushMutations(
      mutationId: id,
      mutations: try decoded().map { mutation in
        switch mutation.op {
        case .upsert:
          .init(
            value1: .init(
              entity: mutation.entity, op: .upsert, id: mutation.id,
              row: mutation.row ?? OpenAPIObjectContainer()))
        case .delete:
          .init(value2: .init(entity: mutation.entity, op: .delete, id: mutation.id))
        }
      })
  }
}

extension LilSyncEngine {
  static func registerPendingMutations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("Create lilPendingMutations") { db in
      try #sql(
        """
        CREATE TABLE "lilPendingMutations" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "mutations" TEXT NOT NULL,
          "seq" INTEGER
        )
        """
      )
      .execute(db)
    }
  }
}
