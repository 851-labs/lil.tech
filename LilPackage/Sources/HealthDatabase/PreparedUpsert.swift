import Foundation
import GRDB
import SQLiteData

/// A table's upsert as one SQL statement, built once from the table's columns, with each
/// record's values bound in their order. GRDB caches the statement per connection, so every row
/// after the first skips both building a query and preparing it.
struct PreparedUpsert<Record: PrimaryKeyedTable>: Sendable {
  let sql: String
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
    sql = """
      INSERT INTO \(quoted(Record.tableName)) (\(names.map(quoted).joined(separator: ", ")))
      VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))
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
    try db.cachedStatement(sql: sql).execute(arguments: try arguments(record))
  }

  /// `record`'s values in its table's column order.
  func arguments(_ record: Record) throws -> StatementArguments {
    var values: [DatabaseValue] = []
    values.reserveCapacity(bindings.count)
    for binding in bindings {
      values.append(try Self.databaseValue(binding(record)))
    }
    return StatementArguments(values)
  }

  private static func databaseValue(_ binding: QueryBinding) throws -> DatabaseValue {
    switch binding {
    case .blob(let bytes): return Data(bytes).databaseValue
    case .bool(let bool): return (bool ? 1 : 0).databaseValue
    case .double(let double): return double.databaseValue
    case .int(let int): return int.databaseValue
    case .null: return .null
    case .text(let text): return text.databaseValue
    case .uint(let uint):
      guard let int = Int64(exactly: uint) else { throw UnsupportedValue(binding: binding) }
      return int.databaseValue
    case .uuid(let uuid): return uuid.uuidString.lowercased().databaseValue
    case .invalid(let error): throw error
    // No health table has a date column (times are Unix milliseconds).
    case .date: throw UnsupportedValue(binding: binding)
    }
  }

  struct UnsupportedValue: Error {
    let binding: QueryBinding
  }
}
