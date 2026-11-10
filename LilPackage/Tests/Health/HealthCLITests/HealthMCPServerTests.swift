import Foundation
import GRDB
import HealthAgentAccess
import HealthCatalog
import HealthConformance
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
    _ directory: URL, now: Date = now, process: String = "claude", timeZone: String = "UTC",
    app: HealthCLI.AppConnection = .notInstalled,
    timing: HealthCLI.Timing = HealthCLI.Timing(claimWait: .seconds(10), cardWait: .seconds(10))
  ) async throws {
    server = await HealthMCPServer.makeServer(
      context: HealthCLI.Context(
        directory: directory, now: { now }, process: process, timeZone: timeZone, app: app,
        timing: timing))
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
      .appending(path: "../../../../Services/api/mcp-tools.json")
      .standardized
    let committed = try String(contentsOf: file, encoding: .utf8)
    #expect(
      committed == mcpToolsJSON + "\n",
      "MCPToolsJSON.swift is out of date. Run scripts/format to regenerate it.")

    let folder = try AppFolder()
    let connection = try await MCPConnection(folder.directory)
    let listed = try await connection.client.listTools().tools
    // As typed JSON, so a boolean that became a number shows.
    let roundTrip = try JSONDecoder().decode(
      ConformanceJSON.self, from: JSONEncoder().encode(listed))
    // Every tool in the file, the card tools' writes too (851-4014).
    let fileJSON = try JSONDecoder().decode(ConformanceJSON.self, from: Data(committed.utf8))
    guard case .array(let fileTools) = fileJSON else {
      Issue.record("mcp-tools.json isn't a list of tools")
      return
    }
    #expect(roundTrip == fileJSON)
    #expect(listed.map(\.name).count == 18)
    #expect(fileTools.count == 18)
    await connection.close()
  }

  @Test
  func refusesWhileAccessIsOffAndLogsNothing() async throws {
    let folder = try AppFolder()
    try folder.addSteps()
    let connection = try await MCPConnection(folder.directory)

    let result = try await connection.call("summary")
    #expect(result.isError == true && result.structuredContent == nil)
    #expect(result.text.contains("Allow access on this Mac"))
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

    // Without a time zone, the Mac's. Slashes aren't escaped, as in `--json`.
    let summary = try await connection.call("summary")
    #expect(summary.structuredContent?.objectValue?["timeZone"] == .string("Europe/London"))
    #expect(summary.text.contains(#""timeZone":"Europe/London""#))

    #expect(
      try folder.access.entries().map(\.command) == [
        "summary",
        #"metric {"range":"W","timeZone":"UTC","type":"Steps"}"#,
      ])
    #expect(try folder.access.entries().allSatisfy { $0.process == "claude" })
    await connection.close()
  }

  @Test
  func toolFailuresAndBadArgumentsAreErrorResults() async throws {
    let folder = try AppFolder()
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory)

    // The tool's own failures, which the agent reads.
    let unknown = try await connection.call("metric", ["type": "Nope", "range": "W"])
    #expect(unknown.isError == true && unknown.text.hasPrefix("Unknown type: Nope."))
    let zone = try await connection.call("summary", ["timeZone": "europe/london"])
    #expect(zone.isError == true && zone.text.contains("Did you mean Europe/London?"))

    // Arguments outside the input schema are the tool's errors too, in the remote server's words
    // (851-4034): each issue, where it is, in the schema's order.
    let ranges = #"Expected "D" | "W" | "M" | "6M" | "Y""#
    for (name, arguments, message): (String, [String: Value], String) in [
      ("metric", ["type": "Steps"], #"Missing key\#n  at ["range"]"#),
      ("metric", ["type": "Steps", "range": "w"], ranges + #"\#n  at ["range"]"#),
      (
        "metric", ["type": "Steps", "range": "W", "statistic": "median"],
        #"Expected "sum" | "average" | "minimum" | "maximum"\#n  at ["statistic"]"#
      ),
      (
        "metric", ["range": .null, "type": 1, "date": "2026-02-31"],
        #"Expected string\#n  at ["type"]\#n"# + ranges + #"\#n  at ["range"]"#
      ),
      (
        "samples", ["type": "Steps", "range": "D", "limit": 501],
        #"Expected a value between 1 and 500\#n  at ["limit"]"#
      ),
      (
        "samples", ["type": "Steps", "range": "D", "limit": 1.5],
        #"Expected an integer\#n  at ["limit"]"#
      ),
      (
        "samples", ["type": "Steps", "range": "D", "limit": -0.5],
        #"Expected an integer\#n  at ["limit"]\#nExpected a value between 1 and 500\#n  at ["limit"]"#
      ),
      (
        "samples", ["type": "Steps", "range": "D", "limit": 9_007_199_254_740_993],
        #"Expected an integer\#n  at ["limit"]\#nExpected a value between 1 and 500\#n  at ["limit"]"#
      ),
      (
        "samples", ["type": "Steps", "range": "D", "limit": "5"],
        #"Expected number\#n  at ["limit"]"#
      ),
      ("summary", ["timeZone": 1], #"Expected string\#n  at ["timeZone"]"#),
      (
        "search", ["query": ""],
        #"Expected a value with a length between 1 and 100\#n  at ["query"]"#
      ),
      // 100 UTF-16 code units, as JavaScript counts a string's length, is the most.
      (
        "search", ["query": .string(String(repeating: "🏃", count: 51))],
        #"Expected a value with a length between 1 and 100\#n  at ["query"]"#
      ),
    ] {
      let result = try await connection.call(name, arguments)
      #expect(result.isError == true, "\(name) \(arguments)")
      #expect(result.text == "Invalid parameters for tool '\(name)': " + message, "\(arguments)")
    }
    // A data URL is a string, though `Value` decodes it as data.
    let dataURL = try await connection.call(
      "metric", ["type": "data:text/plain;base64,QQ==", "range": "W"])
    #expect(dataURL.text.hasPrefix("Unknown type: data:text/plain;base64,QQ==."), "\(dataURL.text)")
    // A day that doesn't exist is the tool's own error, as on the remote server.
    let day = try await connection.call(
      "metric", ["type": "Steps", "range": "W", "date": "2026-02-31"])
    #expect(day.text == "Invalid date: 2026-02-31. Use a day that exists, as YYYY-MM-DD.")
    // Only a tool that doesn't exist is the request's error.
    await #expect(throws: MCPError.invalidParams("Tool 'frobnicate' not found")) {
      try await connection.call("frobnicate")
    }
    // Arguments a tool doesn't take are ignored, as the schemas allow, and aren't logged.
    #expect(try await connection.call("summary", ["extra": true]).isError == false)
    #expect(
      try await connection.call("search", ["query": "steps", "timeZone": 0]).isError == false)
    // Only the calls that reached a tool were logged.
    #expect(
      try folder.access.entries().map(\.command) == [
        #"search {"query":"steps"}"#, "summary",
        #"metric {"date":"2026-02-31","range":"W","type":"Steps"}"#,
        #"metric {"range":"W","type":"data:text/plain;base64,QQ=="}"#,
        #"summary {"timeZone":"europe/london"}"#, #"metric {"range":"W","type":"Nope"}"#,
      ])
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

  /// `workout` reads one by its ID (the conformance cases read the dataset's); one that isn't
  /// there is the tool's error, which the agent reads.
  @Test
  func workoutWithAnUnknownIDIsTheToolsError() async throws {
    let folder = try AppFolder()
    try folder.addSteps()
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory)
    let result = try await connection.call("workout", ["id": "not-a-workout"])
    #expect(result.isError == true)
    #expect(
      result.text == "No workout with ID not-a-workout. workouts lists them, with their IDs.")
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
