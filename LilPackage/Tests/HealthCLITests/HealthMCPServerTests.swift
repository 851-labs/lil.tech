import Foundation
import GRDB
import HealthAgentAccess
import HealthCatalog
import HealthDatabase
import HealthTools
import MCP
import Testing

@testable import HealthCLI

/// Tuesday, October 20, 2026, 15:00 UTC.
private let now = Date(timeIntervalSince1970: 1_792_508_400)
private let steps = "HKQuantityTypeIdentifierStepCount"

/// A client connected to `lil-health mcp`'s server in memory, reading `folder`.
struct MCPConnection {
  let client: MCP.Client
  let server: Server

  init(
    _ directory: URL, now: Date = now, process: String = "claude", timeZone: String = "UTC"
  ) async throws {
    server = await HealthMCPServer.makeServer(
      context: HealthCLI.Context(
        directory: directory, now: { now }, process: process, timeZone: timeZone))
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    client = MCP.Client(name: "HealthMCPServerTests", version: "1")
    _ = try await client.connect(transport: clientTransport)
  }

  func call(_ name: String, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
    try await client.send(CallTool.request(.init(name: name, arguments: arguments))).value
  }

  func close() async {
    await client.disconnect()
    await server.stop()
  }
}

extension CallTool.Result {
  var text: String {
    content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }
      .joined()
  }
}

@Suite
struct HealthMCPServerTests {
  /// The tools come from the toolkit's definitions (`Services/api/mcp-tools.json`, via the Swift
  /// copy `scripts/format` writes), and list exactly as the file has them: nothing the SDK drops.
  @Test
  func listsTheToolkitsToolsExactly() async throws {
    let file = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "../../../Services/api/mcp-tools.json")
      .standardized
    let committed = try String(contentsOf: file, encoding: .utf8)
    #expect(
      committed == mcpToolsJSON + "\n",
      "MCPToolsJSON.swift is out of date. Run scripts/format to regenerate it.")

    let folder = try AppFolder()
    let connection = try await MCPConnection(folder.directory)
    let listed = try await connection.client.listTools().tools
    let encoder = JSONEncoder()
    let roundTrip = try JSONSerialization.jsonObject(with: encoder.encode(listed)) as? NSArray
    let original = try JSONSerialization.jsonObject(with: Data(committed.utf8)) as? NSArray
    #expect(roundTrip != nil && roundTrip == original)
    #expect(listed.map(\.name).count == 10)
    await connection.close()
  }

  @Test
  func refusesWhileAccessIsOffAndLogsNothing() async throws {
    let folder = try AppFolder()
    try folder.addSteps()
    let connection = try await MCPConnection(folder.directory)

    let result = try await connection.call("summary")
    #expect(result.isError == true && result.structuredContent == nil)
    #expect(result.text.contains("Allow command-line and agent access"))
    try folder.access.setEnabled(true, at: Date(timeIntervalSince1970: 0))
    try folder.access.setEnabled(false, at: Date(timeIntervalSince1970: 1))
    #expect(try await connection.call("metric", ["type": "Steps", "range": "W"]).isError == true)
    #expect(try folder.access.entries().isEmpty)
    await connection.close()
  }

  @Test
  func answersAsTheCommandsJSONAndLogsEachCall() async throws {
    let folder = try AppFolder()
    try folder.addSteps()
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory, timeZone: "Europe/London")

    let metric = try await connection.call(
      "metric", ["type": "Steps", "range": "W", "timeZone": "UTC"])
    #expect(metric.isError == false)
    let expected = try await folder.database.read { db in
      try HealthTools(now: now).metric(type: steps, range: .week, timeZone: "UTC", db)
    }
    let structured = try JSONDecoder().decode(
      HealthMetricResult.self, from: JSONEncoder().encode(metric.structuredContent))
    #expect(structured == expected)
    // The text is the same JSON, every field there, as the remote server sends it.
    #expect(
      try JSONDecoder().decode(HealthMetricResult.self, from: Data(metric.text.utf8)) == expected)
    #expect(metric.text.contains(#""value":null"#))

    // Without a time zone, the Mac's.
    let summary = try await connection.call("summary")
    #expect(summary.structuredContent?.objectValue?["timeZone"] == .string("Europe/London"))

    #expect(
      try folder.access.entries().map(\.command) == [
        "summary",
        #"metric {"range":"W","timeZone":"UTC","type":"Steps"}"#,
      ])
    #expect(try folder.access.entries().allSatisfy { $0.process == "claude" })
    await connection.close()
  }

  @Test
  func toolFailuresAreErrorResultsAndBadArgumentsAreInvalidParams() async throws {
    let folder = try AppFolder()
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory)

    // The tool's own failures, which the agent reads.
    let unknown = try await connection.call("metric", ["type": "Nope", "range": "W"])
    #expect(unknown.isError == true && unknown.text.hasPrefix("Unknown type: Nope."))
    let zone = try await connection.call("summary", ["timeZone": "europe/london"])
    #expect(zone.isError == true && zone.text.contains("Did you mean Europe/London?"))

    // Arguments outside the input schema.
    for (name, arguments): (String, [String: Value]) in [
      ("metric", ["type": "Steps"]),
      ("metric", ["type": "Steps", "range": "w"]),
      ("metric", ["type": "Steps", "range": "W", "statistic": "median"]),
      ("samples", ["type": "Steps", "range": "D", "limit": 501]),
      ("samples", ["type": "Steps", "range": "D", "limit": 1.5]),
      ("summary", ["timeZone": 1]),
      ("search", ["query": ""]),
      ("frobnicate", [:]),
    ] {
      await #expect(throws: MCPError.self, "\(name) \(arguments)") {
        try await connection.call(name, arguments)
      }
    }
    // Arguments a tool doesn't take are ignored, as the schemas allow.
    #expect(try await connection.call("summary", ["extra": true]).isError == false)
    // Only the calls that reached a tool were logged.
    #expect(try folder.access.entries().count == 3)
    await connection.close()
  }

  @Test
  func everyToolAnswers() async throws {
    let folder = try AppFolder()
    try folder.addSteps()
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory)
    for (name, arguments): (String, [String: Value]) in [
      ("summary", [:]), ("list_types", [:]), ("metric", ["type": "Steps", "range": "6M"]),
      ("samples", ["type": "HKQuantityTypeIdentifierHeartRate", "range": "D", "limit": 5]),
      ("workouts", ["range": "Y"]), ("sleep", ["range": "W"]), ("medications", [:]),
      ("health_details", [:]), ("search", ["query": "steps"]), ("sync_status", [:]),
    ] {
      let result = try await connection.call(name, arguments)
      #expect(result.isError == false, "\(name): \(result.text)")
      #expect(result.structuredContent?.objectValue != nil, "\(name)")
    }
    await connection.close()
  }

  @Test
  func servesTheCatalogWhetherOrNotAccessIsOn() async throws {
    let folder = try AppFolder()
    let connection = try await MCPConnection(folder.directory)
    let resources = try await connection.client.listResources().resources
    #expect(resources.map(\.uri) == ["health://catalog"])
    let contents = try await connection.client.readResource(uri: "health://catalog")
    #expect(contents.map(\.text) == [try HealthCatalog.json()])
    #expect(contents.map(\.mimeType) == ["application/json"])
    await #expect(throws: MCPError.self) {
      try await connection.client.readResource(uri: "health://nope")
    }
    await connection.close()
  }
}
