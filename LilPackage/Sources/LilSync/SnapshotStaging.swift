import Foundation
import SQLiteData

/// Loading a snapshot through staging tables (851-2859). A snapshot's records arrive in the
/// server's order, not the local table's: a store sends samples by type and time, with random
/// HealthKit IDs. Upserted straight into the table, each one landed somewhere random in its
/// primary key's index, so a batch of 5,000 rewrote thousands of the index's pages, read most of
/// them back from disk first, and checkpointed them all. At 1,000,000 records that was 1 page
/// read and 0.7 pages written a record, against 0.09 and 0.27 at 200,000, and loading took
/// twice as long a record.
///
/// So the records go to a staging table first, one per entity's table, in the connection's
/// temporary schema: no indexes and no constraints, so every insert appends, and nothing is
/// synced to disk. Then one transaction moves them into the table in its primary key's order,
/// which appends to the table and its key's index, with the table's other indexes dropped first
/// and built again afterwards, which sorts once. The indexes are dropped and built in that one
/// transaction, so the table never lacks them: an interrupted bootstrap rolls back to the
/// emptied tables, with every index, and the next one starts over.
enum SnapshotStaging {
  /// The staging table for `table`.
  static func name(for table: String) -> String { "lilSyncStaging_\(table)" }

  /// Creates `table`'s staging table, empty, with its columns, without types (so values are
  /// stored as they're bound) or constraints. Replaces one an interrupted bootstrap left.
  static func create(for table: String, _ db: Database) throws {
    let columns = try self.columns(of: table, db).map(\.name.quotedDatabaseIdentifier)
    try discard(table, db)
    try db.execute(
      sql: """
        CREATE TEMP TABLE \(name(for: table).quotedDatabaseIdentifier) \
        (\(columns.joined(separator: ", ")))
        """
    )
  }

  /// Moves the staged records into `table`, in the order of its primary key, and drops the
  /// staging table. They're upserted as the records were before staging: a record staged twice
  /// is stored as it was staged last, and one the table refuses fails the transaction.
  static func finish(_ table: String, _ db: Database) throws {
    let columns = try self.columns(of: table, db)
    let key = columns.filter { $0.primaryKey > 0 }.sorted { $0.primaryKey < $1.primaryKey }
      .map(\.name.quotedDatabaseIdentifier)
    let names = columns.map(\.name.quotedDatabaseIdentifier)
    let updates = columns.filter { $0.primaryKey == 0 }.map(\.name.quotedDatabaseIdentifier)
      .map { "\($0) = excluded.\($0)" }
    // As `PreparedUpsert`'s, so the same records succeed and fail. (`WHERE true` tells SQLite
    // the `ON CONFLICT` isn't a join's.)
    let conflict =
      key.isEmpty
      ? ""
      : """
      ON CONFLICT (\(key.joined(separator: ", "))) DO \
      \(updates.isEmpty ? "NOTHING" : "UPDATE SET \(updates.joined(separator: ", "))")
      """
    // Indexes the schema declares; the primary key's own (`sql IS NULL`) can't be dropped.
    let indexes = try #sql(
      """
      SELECT "name", "sql" FROM main.sqlite_master
      WHERE "type" = 'index' AND "tbl_name" = \(bind: table) AND "sql" IS NOT NULL
      """,
      as: (String, String).self
    )
    .fetchAll(db)
    for (index, _) in indexes {
      try db.execute(sql: "DROP INDEX main.\(index.quotedDatabaseIdentifier)")
    }
    try db.execute(
      sql: """
        INSERT INTO main.\(table.quotedDatabaseIdentifier) (\(names.joined(separator: ", ")))
        SELECT \(names.joined(separator: ", ")) FROM temp.\(name(for: table).quotedDatabaseIdentifier)
        WHERE true ORDER BY \((key + ["rowid"]).joined(separator: ", "))
        \(conflict)
        """
    )
    for (_, sql) in indexes {
      try db.execute(sql: sql)
    }
    try discard(table, db)
  }

  /// Drops `table`'s staging table, if there is one.
  static func discard(_ table: String, _ db: Database) throws {
    try db.execute(sql: "DROP TABLE IF EXISTS temp.\(name(for: table).quotedDatabaseIdentifier)")
  }

  /// `table`'s columns in order, with their place in its primary key (0 if they're not in it).
  private static func columns(
    of table: String, _ db: Database
  ) throws -> [(name: String, primaryKey: Int)] {
    try #sql(
      """
      SELECT "name", "pk" FROM pragma_table_info(\(bind: table), 'main') ORDER BY "cid"
      """,
      as: (String, Int).self
    )
    .fetchAll(db)
    .map { name, primaryKey in (name: name, primaryKey: primaryKey) }
  }
}
