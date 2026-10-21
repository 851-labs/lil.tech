import Foundation
import GRDB
import SQLiteData

/// A table's upsert as one SQL statement, built once from the table's columns, with each
/// record's values bound in their order. GRDB caches the statement per connection, so every row
/// after the first skips both building a query and preparing it. A record with a value
/// StructuredQueries binds specially (a date, an empty blob) is upserted its usual way instead.
struct PreparedUpsert<Record: PrimaryKeyedTable>: Sendable where Record.QueryOutput == Record {
  let sql: String
  /// The columns and placeholders of an `INSERT` into a table with `Record`'s columns.
  private let columnList: String
  private let placeholders: String
  /// Each column's name, quoted, and the primary key's columns, by their place in `bindings`.
  private let columnNames: [String]
  private let primaryKey: [Int]
  /// Each column's value in a record, as StructuredQueries binds it, in the statement's order.
  private let bindings: [@Sendable (Record) -> QueryBinding]

  init() {
    let columns = Record.TableColumns.writableColumns
    let names = columns.map(\.name)
    let primaryKey = Record.columns.primaryKey._names
    let quoted = { (name: String) in "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    let updates = names.filter { !primaryKey.contains($0) }.map {
      "\(quoted($0)) = excluded.\(quoted($0))"
    }
    columnNames = names.map(quoted)
    self.primaryKey = names.indices.filter { primaryKey.contains(names[$0]) }
    columnList = names.map(quoted).joined(separator: ", ")
    placeholders = names.map { _ in "?" }.joined(separator: ", ")
    sql = """
      INSERT INTO \(quoted(Record.tableName)) (\(columnList))
      VALUES (\(placeholders))
      ON CONFLICT (\(primaryKey.map(quoted).joined(separator: ", "))) DO \
      \(updates.isEmpty ? "NOTHING" : "UPDATE SET \(updates.joined(separator: ", "))")
      """
    bindings = columns.map { column in
      func binding<Root, Member>(
        _ column: some WritableTableColumnExpression<Root, Member>
      ) -> @Sendable (Record) -> QueryBinding {
        // `Root` is `Record`: the cast is once per column, not once per row.
        nonisolated(unsafe) let keyPath = column.keyPath as! KeyPath<Record, Member.QueryOutput>
        return { record in Member(queryOutput: record[keyPath: keyPath]).queryBinding }
      }
      return binding(column)
    }
  }

  func execute(_ record: Record, _ db: Database) throws {
    guard let arguments = try arguments(record) else {
      return try Record.upsert { record }.execute(db)
    }
    let statement = try db.cachedStatement(sql: sql)
    // The arguments are the statement's columns, one each, so GRDB needn't count them.
    statement.setUncheckedArguments(arguments)
    try statement.execute()
  }

  /// Inserts `record` into `table`, a table with `Record`'s columns and no constraints, such as a
  /// snapshot's staging table (851-2859). A record with a value StructuredQueries binds specially
  /// is upserted into `Record`'s own table instead, with what was staged for its ID before it
  /// dropped, so it isn't moved over it later.
  func insert(_ record: Record, into table: String, _ db: Database) throws {
    let table = table.quotedDatabaseIdentifier
    guard let arguments = try arguments(record) else {
      try Record.upsert { record }.execute(db)
      let key = try primaryKey.map { index in
        try Self.databaseValue(bindings[index](record)) ?? .null
      }
      let condition = primaryKey.map { "\(columnNames[$0]) IS ?" }.joined(separator: " AND ")
      return try db.execute(
        sql: "DELETE FROM \(table) WHERE \(condition)", arguments: StatementArguments(key))
    }
    let statement = try db.cachedStatement(
      sql: "INSERT INTO \(table) (\(columnList)) VALUES (\(placeholders))")
    statement.setUncheckedArguments(arguments)
    try statement.execute()
  }

  /// `record`'s values in its table's column order, or `nil` if one needs StructuredQueries'
  /// own binding.
  func arguments(_ record: Record) throws -> StatementArguments? {
    var values: [DatabaseValue] = []
    values.reserveCapacity(bindings.count)
    for binding in bindings {
      guard let value = try Self.databaseValue(binding(record)) else { return nil }
      values.append(value)
    }
    return StatementArguments(values)
  }

  private static func databaseValue(_ binding: QueryBinding) throws -> DatabaseValue? {
    switch binding {
    case .blob(let bytes): bytes.isEmpty ? nil : Data(bytes).databaseValue
    case .bool(let bool): (bool ? 1 : 0).databaseValue
    case .double(let double): double.databaseValue
    case .int(let int): int.databaseValue
    case .null: .null
    case .text(let text): text.databaseValue
    case .uint(let uint): Int64(exactly: uint)?.databaseValue
    case .uuid(let uuid): uuid.uuidString.lowercased().databaseValue
    case .invalid(let error): throw error
    // ISO-8601 text in StructuredQueries' own format.
    case .date: nil
    }
  }
}
