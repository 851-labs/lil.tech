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
  /// The app's `syncSchema` when the local data was bootstrapped; `nil` (from before it was
  /// recorded) counts as 1.
  var syncSchema: Int?
  /// The entities the local data holds, sorted and joined with commas, or `nil` from before they
  /// were recorded (taken to be the app's current ones).
  var entities: String?
  /// A catch-up of entities this release stores and the local data doesn't hold yet, in
  /// progress (851-3222): their names, sorted and joined with commas, or `nil` when there's none.
  /// Their records from a snapshot are loaded, and the changes after it, up to `catchUpUntil`,
  /// are being pulled for them.
  var catchUpEntities: String? = nil
  /// The `seq` of the last change the catch-up has pulled.
  var catchUpAfter: Int? = nil
  /// The cursor when the catch-up started, where it ends. If the cursor isn't there any more
  /// (an older release pulled meanwhile), the catch-up starts over.
  var catchUpUntil: Int? = nil
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
    migrator.registerMigration("Add syncSchema to lilSyncState") { db in
      try #sql(#"ALTER TABLE "lilSyncState" ADD COLUMN "syncSchema" INTEGER"#).execute(db)
      try #sql(#"ALTER TABLE "lilSyncState" ADD COLUMN "entities" TEXT"#).execute(db)
    }
    registerPendingMutations(in: &migrator)
    // After every migration before it, in the order they shipped.
    migrator.registerMigration("Add catch-up to lilSyncState") { db in
      try #sql(#"ALTER TABLE "lilSyncState" ADD COLUMN "catchUpEntities" TEXT"#).execute(db)
      try #sql(#"ALTER TABLE "lilSyncState" ADD COLUMN "catchUpAfter" INTEGER"#).execute(db)
      try #sql(#"ALTER TABLE "lilSyncState" ADD COLUMN "catchUpUntil" INTEGER"#).execute(db)
    }
  }
}

extension SyncState {
  static func fetch(_ db: Database) throws -> SyncState {
    try SyncState.find(singletonID).fetchOne(db)
      ?? SyncState(id: singletonID, cursor: 0, epoch: nil, syncSchema: nil, entities: nil)
  }

  func save(_ db: Database) throws {
    try SyncState.upsert { self }.execute(db)
  }
}

extension LilSyncEngine {
  /// Whether the local data holds `entity`'s records: it has pulled a change, and `entity` isn't
  /// one this release added that a catch-up hasn't loaded yet (851-3222). Until then, an entity
  /// without local records may have records on the server, so an app shows it loading rather
  /// than empty. (A new account's store has changes from the start: its welcome cards.)
  public static func holds(_ entity: String, _ db: Database) throws -> Bool {
    let state = try SyncState.fetch(db)
    guard state.epoch != nil, state.cursor > 0 else { return false }
    // Unrecorded, from before entities were: the app's current ones, as pulling takes them.
    guard let entities = state.entities else { return true }
    return entities.split(separator: ",").contains { $0 == entity }
  }
}
