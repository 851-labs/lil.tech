import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import HealthConformance
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
// `HealthToolkitConformanceTests` calls `lil-health mcp`'s tools. The cards' conformance cases
// (`CardConformanceTests`, 851-3198) sync their dataset, which extends this one, the same way.

/// The conformance files, read from the API's tests.
enum Conformance {
  static let directory = ConformanceFiles.tools

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
  /// batch. Then `pins`, as a Mac from before pins were retired (851-2990) writes them
  /// (`POST /v1/sync/mutations`): the server still takes them, and this Mac skips them.
  static func changes(
    _ batches: [ConformanceBatch], pins: [Case.Pin]? = nil
  ) -> [[String: Any]] {
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
      let device = batch.device
      let receivedAt = Int(batch.receivedAt.timeIntervalSince1970 * 1000)
      for line in batch.lines {
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

  /// Syncs the tools' dataset, with `pins`, into `database` as the app's sync engine pulls it.
  static func sync(into database: any DatabaseWriter, pins: [Case.Pin]?) async throws {
    try await sync(
      try ConformanceBatch.read(directory.appending(path: "dataset.json")), into: database,
      pins: pins)
  }

  /// Syncs `batches`, then `pins`, into `database` as the app's sync engine pulls them: one page
  /// of the change feed.
  static func sync(
    _ batches: [ConformanceBatch], into database: any DatabaseWriter, pins: [Case.Pin]? = nil
  ) async throws {
    let changes = changes(batches, pins: pins)
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
