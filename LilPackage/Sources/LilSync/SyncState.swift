public import SQLiteData

/// Where the local copy is in the server's change log. One row, kept in the same database as
/// the synced tables, so a page and its cursor commit together.
@Table("lilSyncState")
struct SyncState: Equatable {
  static let singletonID = 1

  let id: Int
  /// The `seq` of the last change applied.
  var cursor: Int
  /// The store's epoch the local data belongs to, or `nil` before the first pull.
  var epoch: Int?
}

extension LilSyncEngine {
  /// Registers LilSync's own tables. Call it from the app's migrator, before its synced tables'
  /// migrations.
  public static func registerMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("Create lilSyncState") { db in
      try #sql(
        """
        CREATE TABLE "lilSyncState" (
          "id" INTEGER PRIMARY KEY CHECK ("id" = 1),
          "cursor" INTEGER NOT NULL,
          "epoch" INTEGER
        ) STRICT
        """
      )
      .execute(db)
    }
  }
}

extension SyncState {
  static func fetch(_ db: Database) throws -> SyncState {
    try SyncState.find(singletonID).fetchOne(db)
      ?? SyncState(id: singletonID, cursor: 0, epoch: nil)
  }

  func save(_ db: Database) throws {
    try SyncState.upsert { self }.execute(db)
  }
}
