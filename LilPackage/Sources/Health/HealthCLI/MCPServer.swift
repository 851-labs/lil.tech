import Foundation
import GRDB
import HealthAgentAccess
import HealthCatalog
import HealthDatabase
import HealthTools
import MCP

/// `lil-health mcp` (851-2844): the Health toolkit as a local MCP server on standard input and
/// output, for agents (Claude Code, Codevisor…) to read the Mac's synced Health data offline.
///
/// It lists the tools exactly as `Services/api/mcp-tools.json` has them, so names, descriptions
/// and schemas match the remote server's, and answers each call with `HealthTools`, as the
/// commands' `--json` does. Like the commands, every call checks access on this Mac
/// and logs itself first (851-2840): with access off, a call answers with the error that says
/// where to turn it on. It also serves the catalog of categories and types as a resource.
enum HealthMCPServer {
  /// The tools, decoded from the toolkit's definitions. `HealthMCPServerTests` checks they decode
  /// and list exactly as the file has them.
  static let tools: [Tool] = {
    do {
      return try JSONDecoder().decode([Tool].self, from: Data(mcpToolsJSON.utf8))
    } catch {
      fatalError("MCPToolsJSON.swift doesn't decode as MCP tools: \(error)")
    }
  }()

  /// The tools' input properties by name: what a call's log entry keeps of its arguments.
  static let toolArguments: [String: Set<String>] = Dictionary(
    uniqueKeysWithValues: tools.map { tool in
      (tool.name, Set((tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]).keys))
    })

  /// The catalog of categories and types, with workout activities' names: what `list_types`
  /// and `search` name, as a file agents can read whole. Not the person's data, so it's served
  /// whether or not access is on.
  static let catalog = Resource(
    name: "catalog", uri: "health://catalog", title: "Health Data Types",
    description: """
      Every category and data type lil health knows, with its HealthKit identifier, name, kind, \
      unit and aggregation, and the names of workout activities. Not the person's data: use the \
      tools for that.
      """,
    mimeType: "application/json")

  /// The catalog's contents, made once: it doesn't change while the server runs.
  static let catalogJSON = Result { try HealthCatalog.json() }

  /// What the server tells agents when they connect.
  static let instructions = """
    Reads the person's Apple Health data that lil health has synced to this Mac, read-only and \
    offline. Start with summary; find types with list_types or search. Every call is logged in \
    lil health › Settings… › Agents, and fails while the person has command-line and agent \
    access turned off there.
    """

  /// Serves on standard input and output until the client closes them, then exits.
  static func serve(context: HealthCLI.Context) -> Never {
    Task {
      do {
        let server = await makeServer(context: context)
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("lil-health: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
    }
    dispatchMain()
  }

  /// A server with the tools and the catalog, reading from `context`.
  static func makeServer(context: HealthCLI.Context) async -> Server {
    let server = Server(
      name: "lil-health",
      // Inside the app, `Bundle.main` is the app's bundle, so this is lil health's version.
      version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
      title: "lil health",
      instructions: instructions,
      capabilities: Server.Capabilities(
        resources: .init(subscribe: false, listChanged: false),
        tools: .init(listChanged: false)))
    await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
    await server.withMethodHandler(CallTool.self) { parameters in
      try call(parameters.name, arguments: parameters.arguments ?? [:], context: context)
    }
    await server.withMethodHandler(ListResources.self) { _ in
      ListResources.Result(resources: [catalog])
    }
    await server.withMethodHandler(ReadResource.self) { parameters in
      guard parameters.uri == catalog.uri else {
        throw MCPError.invalidParams("Unknown resource: \(parameters.uri)")
      }
      return ReadResource.Result(contents: [
        .text(try catalogJSON.get(), uri: catalog.uri, mimeType: catalog.mimeType)
      ])
    }
    return server
  }

  /// Answers a tool call as the remote server does: the output as structured content and as JSON
  /// text, or for the tool's own failure (an unknown type, access off) an error result with its
  /// message. Arguments that don't fit the tool's input schema are the request's error.
  static func call(
    _ name: String, arguments: [String: Value], context: HealthCLI.Context
  ) throws -> CallTool.Result {
    let query = try ToolCall(name: name, arguments: arguments).query
    do {
      // Before every call, not once: turning access off stops the next one.
      try AgentAccessStore(directory: context.directory)
        .authorize(
          command: logEntry(
            name, arguments.filter { toolArguments[name]?.contains($0.key) == true }),
          process: context.process)
      // The Mac's time zone as it is now, not when the server started: it may run for days, and
      // the Mac may move.
      NSTimeZone.resetSystemTimeZone()
      // Opened for each call, so a server that has run since before an update reads the
      // database once the app has migrated it.
      let database = try HealthDatabase.openForReading(
        at: context.directory.appending(path: "Health.sqlite"))
      let tools = HealthTools(now: context.now(), defaultTimeZone: context.timeZone)
      let output = try database.read { db in try query(tools, db) }
      // As the commands' `--json` and the remote server write it: `Europe/London`, not
      // `Europe\/London`.
      let encoder = JSONEncoder()
      encoder.outputFormatting = .withoutEscapingSlashes
      let json = try encoder.encode(output)
      let structured: Value? = try JSONDecoder().decode(Value.self, from: json)
      return CallTool.Result(
        content: [.text(text: String(decoding: json, as: UTF8.self), annotations: nil, _meta: nil)],
        structuredContent: structured, isError: false)
    } catch {
      return CallTool.Result(
        content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
        isError: true)
    }
  }

  /// The access log's entry for a call: the tool and the arguments it takes as JSON, e.g.
  /// `metric {"range":"W","type":"Steps"}`.
  static func logEntry(_ name: String, _ arguments: [String: Value]) -> String {
    guard !arguments.isEmpty else { return name }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let json = try? encoder.encode(arguments) else { return name }
    return name + " " + String(decoding: json, as: UTF8.self)
  }
}

/// A tool call's arguments, checked against the tool's input schema as the remote server's
/// toolkit decodes them: required ones there, each of its type, enums and bounds respected.
/// Arguments a tool doesn't take are ignored (the schemas allow additional properties).
private struct ToolCall {
  typealias Query = @Sendable (HealthTools, Database) throws -> any HealthToolOutput

  let query: Query

  init(name: String, arguments: [String: Value]) throws {
    let arguments = Arguments(values: arguments)
    // Every tool but `search` takes one.
    let timeZone = { try arguments.string("timeZone") }
    switch name {
    case "summary":
      let timeZone = try timeZone()
      query = { tools, db in try tools.summary(timeZone: timeZone, db) }
    case "list_types":
      let timeZone = try timeZone()
      query = { tools, db in try tools.listTypes(timeZone: timeZone, db) }
    case "metric":
      let type = try arguments.required("type", arguments.string)
      let range = try arguments.required("range", arguments.range)
      let statistic = try arguments.oneOf(
        "statistic", HealthTools.Statistic.allCases.map(\.rawValue)
      )
      .flatMap(HealthTools.Statistic.init(rawValue:))
      let date = try arguments.string("date")
      let timeZone = try timeZone()
      query = { tools, db in
        try tools.metric(
          type: type, range: range, statistic: statistic, date: date, timeZone: timeZone, db)
      }
    case "samples":
      let type = try arguments.required("type", arguments.string)
      let range = try arguments.required("range", arguments.range)
      let date = try arguments.string("date")
      let cursor = try arguments.string("cursor")
      let limit = try arguments.integer("limit", in: 1...HealthTools.samplesLimit)
      let timeZone = try timeZone()
      query = { tools, db in
        try tools.samples(
          type: type, range: range, date: date, timeZone: timeZone, cursor: cursor, limit: limit,
          db)
      }
    case "workouts":
      let range = try arguments.required("range", arguments.range)
      let date = try arguments.string("date")
      let timeZone = try timeZone()
      query = { tools, db in try tools.workouts(range: range, date: date, timeZone: timeZone, db) }
    case "sleep":
      let range = try arguments.required("range", arguments.range)
      let date = try arguments.string("date")
      let timeZone = try timeZone()
      query = { tools, db in try tools.sleep(range: range, date: date, timeZone: timeZone, db) }
    case "medications":
      let timeZone = try timeZone()
      query = { tools, db in try tools.medications(timeZone: timeZone, db) }
    case "health_details":
      let timeZone = try timeZone()
      query = { tools, db in try tools.healthDetails(timeZone: timeZone, db) }
    case "search":
      let text = try arguments.required("query", arguments.string)
      guard (1...100).contains(text.utf16.count) else {
        throw MCPError.invalidParams("query must be 1 to 100 characters long")
      }
      query = { tools, db in try tools.search(query: text, db) }
    case "sync_status":
      let timeZone = try timeZone()
      query = { tools, db in try tools.syncStatus(timeZone: timeZone, db) }
    default:
      throw MCPError.invalidParams("Unknown tool: \(name)")
    }
  }
}

/// Reads arguments by name, failing as invalid parameters when one has the wrong type.
private struct Arguments {
  let values: [String: Value]

  func string(_ name: String) throws -> String? {
    guard let value = values[name] else { return nil }
    guard let string = value.stringValue else {
      throw MCPError.invalidParams("\(name) must be a string")
    }
    return string
  }

  /// A string that must be one of `allowed`, in their case.
  func oneOf(_ name: String, _ allowed: [String]) throws -> String? {
    guard let string = try string(name) else { return nil }
    guard allowed.contains(string) else {
      throw MCPError.invalidParams(
        "\(name) must be one of \(allowed.joined(separator: ", ")), not \(string)")
    }
    return string
  }

  func range(_ name: String) throws -> ToolRange? {
    try oneOf(name, ToolRange.allCases.map(\.rawValue)).flatMap(ToolRange.init(rawValue:))
  }

  func integer(_ name: String, in bounds: ClosedRange<Int>) throws -> Int? {
    guard let value = values[name] else { return nil }
    let integer =
      value.intValue
      ?? value.doubleValue.flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil }
    guard let integer, bounds.contains(integer) else {
      throw MCPError.invalidParams(
        "\(name) must be an integer from \(bounds.lowerBound) to \(bounds.upperBound)")
    }
    return integer
  }

  func required<Argument>(
    _ name: String, _ read: (String) throws -> Argument?
  ) throws -> Argument {
    guard let argument = try read(name) else {
      throw MCPError.invalidParams("\(name) is required")
    }
    return argument
  }
}
