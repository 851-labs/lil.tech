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
    let columns = try String.fetchAll(
      db, sql: "SELECT name FROM pragma_table_info(?, 'main') ORDER BY cid", arguments: [table])
    try discard(table, db)
    try db.execute(
      sql: """
        CREATE TEMP TABLE \(quoted(name(for: table))) \
        (\(columns.map(quoted).joined(separator: ", ")))
        """
    )
  }

  /// Moves the staged records into `table`, in the order of its primary key, and drops the
  /// staging table. A record staged twice is stored as it was staged last, as upserting it would.
  static func finish(_ table: String, _ db: Database) throws {
    let columns = try String.fetchAll(
      db, sql: "SELECT name FROM pragma_table_info(?, 'main') ORDER BY cid", arguments: [table]
    )
    .map(quoted).joined(separator: ", ")
    let key = try String.fetchAll(
      db, sql: "SELECT name FROM pragma_table_info(?, 'main') WHERE pk > 0 ORDER BY pk",
      arguments: [table]
    )
    // Indexes the schema declares; the primary key's own (`sql IS NULL`) can't be dropped.
    let declared =
      "FROM main.sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL"
    let indexes = try zip(
      String.fetchAll(db, sql: "SELECT name \(declared) ORDER BY name", arguments: [table]),
      String.fetchAll(db, sql: "SELECT sql \(declared) ORDER BY name", arguments: [table])
    )
    .map { (name: $0, sql: $1) }
    for index in indexes {
      try db.execute(sql: "DROP INDEX main.\(quoted(index.name))")
    }
    try db.execute(
      sql: """
        INSERT OR REPLACE INTO main.\(quoted(table)) (\(columns))
        SELECT \(columns) FROM temp.\(quoted(name(for: table)))
        ORDER BY \((key.map(quoted) + ["rowid"]).joined(separator: ", "))
        """
    )
    for index in indexes {
      try db.execute(sql: index.sql)
    }
    try discard(table, db)
  }

  /// Drops `table`'s staging table, if there is one.
  static func discard(_ table: String, _ db: Database) throws {
    try db.execute(sql: "DROP TABLE IF EXISTS temp.\(quoted(name(for: table)))")
  }

  private static func quoted(_ name: String) -> String {
    "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}
