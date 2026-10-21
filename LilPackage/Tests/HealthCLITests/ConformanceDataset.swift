import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import HealthDatabase
import LilAPI
import LilSync
import LilTestSupport
import OpenAPIRuntime
import SQLiteData

// The Health toolkit's conformance harness (851-2841), shared with the remote server:
// `Services/api/test/health/tools/conformance`. `dataset.json` is a synthetic account in upload
// form (each iPhone's batches) and `cases.json` tool calls on it, with the answers both MCP
// servers must give. This side syncs the dataset into the Mac's database as the app does, then
// `HealthToolkitConformanceTests` calls `lil-health mcp`'s tools.

/// The conformance files, read from the API's tests.
enum Conformance {
  static let directory = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "../../../Services/api/test/health/tools/conformance")
    .standardized

  struct Case: Decodable, Sendable {
    struct Pin: Decodable, Sendable {
      var id: String
      var position: Double
    }

    var name: String
    var tool: String
    var now: String
    var pins: [Pin]?
    var arguments: JSONValue
    var expected: JSONValue?
    var expectedError: Bool?
  }

  static func cases() throws -> [Case] {
    struct File: Decodable { var cases: [Case] }
    return try JSONDecoder().decode(
      File.self, from: Data(contentsOf: directory.appending(path: "cases.json"))
    )
    .cases
  }

  static func date(_ iso: String) throws -> Date {
    try Date(iso, strategy: .iso8601)
  }

  /// The dataset as the server's change feed has it after ingesting the batches, as
  /// `ingestHealthBatch` stores them (`Services/api/src/health/HealthIngestion.ts`): records an
  /// iPhone computes for itself (statistics, and its `self` statistics device) are keyed by the
  /// device and say which one it is, and a device's `reportedAt` is when the server applied its
  /// batch. Then `pins`, as the Mac writes them (`POST /v1/sync/mutations`).
  static func changes(pins: [Case.Pin]?) throws -> [[String: Any]] {
    let dataset = try JSONSerialization.jsonObject(
      with: Data(contentsOf: directory.appending(path: "dataset.json")))
    let batches = (dataset as? [String: Any])?["batches"] as? [[String: Any]] ?? []
    var changes: [[String: Any]] = []
    func append(_ entity: String, _ op: String, _ id: String, _ row: [String: Any]?, at: Int) {
      var change: [String: Any] = [
        "seq": changes.count + 1, "entity": entity, "id": id, "op": op, "at": at,
      ]
      if var row {
        row["id"] = id
        change["row"] = row
      }
      changes.append(change)
    }
    let deviceScoped = ["health_statistic", "health_statistics_device"]
    for batch in batches {
      let device = batch["device"] as? String ?? ""
      let receivedAt = Int(
        try date(batch["receivedAt"] as? String ?? "").timeIntervalSince1970 * 1000)
      for case let line as [String: Any] in batch["lines"] as? [Any] ?? [] {
        let entity = line["entity"] as? String ?? ""
        var id = line["id"] as? String ?? ""
        var row = line["row"] as? [String: Any]
        if deviceScoped.contains(entity) {
          id = id == "self" ? device : "\(device)/\(id)"
          row?["device"] = device
          if entity == "health_statistics_device" { row?["reportedAt"] = receivedAt }
        }
        append(entity, line["op"] as? String ?? "", id, row, at: receivedAt)
      }
    }
    for pin in pins ?? [] {
      append("health_pin", "upsert", pin.id, ["position": pin.position], at: 0)
    }
    return changes
  }

  /// Syncs the dataset, with `pins`, into `database` as the app's sync engine pulls it: one page
  /// of the change feed.
  static func sync(into database: any DatabaseWriter, pins: [Case.Pin]?) async throws {
    let changes = try changes(pins: pins)
    let page = try JSONSerialization.data(withJSONObject: [
      "epoch": 1, "changes": changes, "next": changes.count, "head": changes.count,
      "hasMore": false,
    ])
    let api = Client.mock { request, _ in
      guard request.path?.hasPrefix("/v1/sync/changes") == true else {
        return (HTTPResponse(status: .notFound), nil)
      }
      return (
        HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
        HTTPBody(page)
      )
    }
    try await database.write { db in
      try db.execute(
        sql: "INSERT INTO lilSyncState (id, cursor, epoch, syncSchema) VALUES (1, 0, 1, ?)",
        arguments: [HealthDatabase.syncSchema])
    }
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = api
      $0.continuousClock = RecordingClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
      $0.date.now = Date(timeIntervalSince1970: 0)
    } operation: {
      LilSyncEngine(entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema)
    }
    try await engine.pull()
  }
}

/// A JSON value, to compare outputs as the server's harness does.
enum JSONValue: Decodable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  /// Whether `self` matches `expected` as the server's harness has it: the same JSON, with
  /// numbers within a relative 1e-9, since sums may be added in another order.
  func matches(_ expected: JSONValue) -> Bool {
    switch (self, expected) {
    case (.number(let actual), .number(let expected)):
      return abs(actual - expected) <= 1e-9 * max(1, abs(expected))
    case (.array(let actual), .array(let expected)):
      return actual.count == expected.count
        && zip(actual, expected).allSatisfy { $0.matches($1) }
    case (.object(let actual), .object(let expected)):
      return actual.count == expected.count
        && expected.allSatisfy { key, value in actual[key]?.matches(value) == true }
    default:
      return self == expected
    }
  }
}
