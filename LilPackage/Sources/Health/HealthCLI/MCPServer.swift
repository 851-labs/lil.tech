import Foundation
import GRDB
import HealthAgentAccess
import HealthCards
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
///
/// The card tools (docs/decisions/cards.md › MCP tools) run here too. The reads (851-3216),
/// `list_cards`, `get_card` and `preview_card`, on the cards synced to this Mac and with its
/// engine. The writes (851-4014), `create_card`, `update_card`, `delete_card` and
/// `reorder_cards`, are checked here, then asked of the app (`HealthCLI.askApp`), which writes them
/// as Summary's editor does, locally and through sync: the app's sync engine stays the only writer
/// of its database, which this server only reads. They never write Health data.
enum HealthMCPServer {
  /// The tools, decoded from the toolkit's definitions: every one, as the remote server lists them.
  /// `HealthMCPServerTests` checks they decode and list exactly as the file has them.
  static let tools: [Tool] = {
    do {
      return try JSONDecoder().decode([Tool].self, from: Data(mcpToolsJSON.utf8))
    } catch {
      fatalError("MCPToolsJSON.swift doesn't decode as MCP tools: \(error)")
    }
  }()

  /// The card tools that write, through the app.
  static let writeTools: Set<String> = [
    "create_card", "update_card", "delete_card", "reorder_cards",
  ]

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
    offline. Start with summary; find types with list_types or search. The card tools manage the \
    cards on lil health's Summary: preview a card with preview_card before creating it. They \
    change cards only, never Health data, and their changes sync to the person's devices. Every \
    call is logged in lil health › Settings… › Agents, and fails while Allow access on this Mac \
    is off there.
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
      try await call(parameters.name, arguments: parameters.arguments ?? [:], context: context)
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
  /// text, or for the tool's own failure (an unknown type, access off) and arguments that don't
  /// fit its input schema (851-4034) an error result with its message. Only a tool that doesn't
  /// exist is the request's error.
  static func call(
    _ name: String, arguments: [String: Value], context: HealthCLI.Context
  ) async throws -> CallTool.Result {
    if writeTools.contains(name) {
      let write: CardWriteCall
      do {
        write = try CardWriteCall(name: name, arguments: arguments)
      } catch let error as InvalidArguments {
        return failure(error)
      }
      // It waits for the app, seconds at most, off Swift's own threads.
      return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          continuation.resume(
            returning: cardWrite(write, name: name, arguments: arguments, context: context))
        }
      }
    }
    let query: ToolCall.Query
    do {
      query = try ToolCall(name: name, arguments: arguments).query
    } catch let error as InvalidArguments {
      return failure(error)
    }
    do {
      // Before every call, not once: turning access off stops the next one.
      try AgentAccessStore(directory: context.directory)
        .authorize(
          command: logEntry(name, loggedArguments(name, arguments)),
          process: context.process)
      // The Mac's time zone as it is now, not when the server started: it may run for days, and
      // the Mac may move.
      NSTimeZone.resetSystemTimeZone()
      // Opened for each call, so a server that has run since before an update reads the
      // database once the app has migrated it.
      let database = try HealthDatabase.openForReading(
        at: context.directory.appending(path: "Health.sqlite"))
      let tools = HealthTools(now: context.now(), defaultTimeZone: context.timeZone)
      return try result(try await database.read { db in try query(tools, db) })
    } catch {
      return failure(error)
    }
  }

  /// A card write (851-4014): logged and checked for access as every call is, then checked on the
  /// cards synced to this Mac, then asked of the app, which answers once it's stored; the answer
  /// is read back from the database, so it's what the app wrote.
  static func cardWrite(
    _ write: CardWriteCall, name: String, arguments: [String: Value], context: HealthCLI.Context
  ) -> CallTool.Result {
    let url = context.directory.appending(path: "Health.sqlite")
    func read<T>(_ value: (Database) throws -> T) throws -> T {
      try HealthDatabase.openForReading(at: url).read { db in try value(db) }
    }
    do {
      let access = AgentAccessStore(directory: context.directory)
      var logged = loggedArguments(name, arguments)
      // A delete logs the card's name too, read before it goes, so Settings can say which card
      // (851-4011), as the remote server's log does. Only for the log, nothing reaches the agent,
      // and only once access is known to be on: nothing is read while it's off.
      if case .delete(let id) = write {
        guard try access.isEnabled() else { throw AgentAccessError.off }
        if let cardName = try? read({ db in try HealthTools.cardName(id: id, db) }) {
          logged["name"] = .string(cardName)
        }
      }
      try access.authorize(command: logEntry(name, logged), process: context.process)
      NSTimeZone.resetSystemTimeZone()
      let tools = HealthTools(now: context.now(), defaultTimeZone: context.timeZone)
      switch write {
      case .create(let input, let timeZone):
        let input = try HealthTools.parsedSpec(input)
        let spec = try read { db in try tools.checkCreate(spec: input, timeZone: timeZone, db) }
        guard case .card(let id) = try HealthCLI.askApp(.createCard(spec: spec), context: context)
        else { throw HealthCLI.ActionError.notAnswered }
        return try result(try read { db in try tools.cardResult(id: id, timeZone: timeZone, db) })
      case .update(let id, let input, let timeZone):
        let input = try HealthTools.parsedSpec(input)
        let spec = try read { db in
          try tools.checkUpdate(id: id, spec: input, timeZone: timeZone, db)
        }
        _ = try HealthCLI.askApp(.updateCard(id: id, spec: spec), context: context)
        return try result(try read { db in try tools.cardResult(id: id, timeZone: timeZone, db) })
      case .delete(let id):
        try read { db in try tools.checkDelete(id: id, db) }
        _ = try HealthCLI.askApp(.deleteCard(id: id), context: context)
        return try result(HealthCardDeletedResult(deleted: id))
      case .reorder(let ids):
        try read { db in try tools.checkReorder(ids: ids, db) }
        _ = try HealthCLI.askApp(.reorderCards(ids: ids), context: context)
        return try result(try read { db in try tools.cardOrder(db) })
      }
    } catch {
      return failure(error)
    }
  }

  /// A tool's output as structured content and as JSON text: as the commands' `--json` writes it,
  /// keys sorted, so the text is the same from one run to the next (`JSONEncoder` keeps no order
  /// of its own), and `Europe/London`, not `Europe\/London`, as the remote server writes it.
  private static func result(_ output: any HealthToolOutput) throws -> CallTool.Result {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json = try encoder.encode(output)
    let structured: Value? = try JSONDecoder().decode(Value.self, from: json)
    return CallTool.Result(
      content: [.text(text: String(decoding: json, as: UTF8.self), annotations: nil, _meta: nil)],
      structuredContent: structured, isError: false)
  }

  /// A call of a tool that doesn't exist: the request's error, as the remote server's.
  static func unknownTool(_ name: String) -> MCPError {
    MCPError.invalidParams("Tool '\(name)' not found")
  }

  /// A tool's own failure, with its message, which the agent reads.
  private static func failure(_ error: any Error) -> CallTool.Result {
    CallTool.Result(
      content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
      isError: true)
  }

  /// What a call's log entry keeps of its arguments: those the tool takes, but never a card's
  /// spec, which stands in as its types and range for a preview, e.g. `preview_card {"range":"W",
  /// "types":["HKQuantityTypeIdentifierHeartRate"]}`, and as its name for a write, e.g.
  /// `create_card {"name":"Sleeping Heart Rate"}`, and `reorder_cards`' IDs as how many
  /// (docs/decisions/cards.md › The access log).
  static func loggedArguments(_ name: String, _ arguments: [String: Value]) -> [String: Value] {
    var logged = arguments.filter { toolArguments[name]?.contains($0.key) == true }
    if case .array(let ids)? = logged.removeValue(forKey: "ids") {
      logged["count"] = .int(ids.count)
    }
    if writeTools.contains(name), let spec = logged.removeValue(forKey: "spec") {
      if let name = CardJSON(toolArgument: spec).flatMap(HealthTools.cardName) {
        logged["name"] = .string(name)
      }
    } else if let spec = logged.removeValue(forKey: "spec") {
      let json = CardJSON(toolArgument: spec)
      if let types = json.flatMap(HealthTools.cardTypes) {
        logged["types"] = .array(types.map(Value.string))
      }
      if logged["range"] == nil, let range = json.flatMap(HealthTools.cardRange) {
        logged["range"] = .string(range)
      }
    }
    return logged
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

/// A card write's arguments, checked against its input schema as `ToolCall` checks the others'.
enum CardWriteCall: Sendable {
  /// A spec that's `nil` is JSON text that isn't JSON.
  case create(spec: CardJSON?, timeZone: String?)
  case update(id: String, spec: CardJSON?, timeZone: String?)
  case delete(id: String)
  case reorder(ids: [String])

  init(name: String, arguments values: [String: Value]) throws {
    let arguments = Arguments(tool: name, values: values)
    // A spec is any JSON: what isn't a spec comes back as the validator's errors, or JSON text
    // that isn't JSON as `invalidJSON`, as on the remote server.
    switch name {
    case "create_card":
      let spec = arguments.required("spec", arguments.any)
      let timeZone = arguments.string("timeZone")
      guard let spec, arguments.isValid else { throw arguments.invalid }
      self = .create(spec: CardJSON(toolArgument: spec), timeZone: timeZone)
    case "update_card":
      let id = arguments.required("id", arguments.string)
      let spec = arguments.required("spec", arguments.any)
      let timeZone = arguments.string("timeZone")
      guard let id, let spec, arguments.isValid else { throw arguments.invalid }
      self = .update(id: id, spec: CardJSON(toolArgument: spec), timeZone: timeZone)
    case "delete_card":
      let id = arguments.required("id", arguments.string)
      guard let id, arguments.isValid else { throw arguments.invalid }
      self = .delete(id: id)
    case "reorder_cards":
      // The input schema's limit, the store's (`HealthCards.storeMaxCards`).
      let ids = arguments.required("ids") {
        arguments.strings($0, atMost: HealthCards.storeMaxCards)
      }
      guard let ids, arguments.isValid else { throw arguments.invalid }
      self = .reorder(ids: ids)
    default:
      throw HealthMCPServer.unknownTool(name)
    }
  }
}

/// A tool call's arguments, checked against the tool's input schema as the remote server's
/// toolkit decodes them: required ones there, each of its type, enums and bounds respected, and
/// every issue reported at once. Arguments a tool doesn't take are ignored (the schemas allow
/// additional properties).
private struct ToolCall {
  typealias Query = @Sendable (HealthTools, Database) throws -> any HealthToolOutput

  let query: Query

  init(name: String, arguments values: [String: Value]) throws {
    let arguments = Arguments(tool: name, values: values)
    // Each tool's arguments are read in its input schema's order, the order the remote server
    // lists their issues in.
    switch name {
    case "summary":
      let timeZone = arguments.string("timeZone")
      try arguments.check()
      query = { tools, db in try tools.summary(timeZone: timeZone, db) }
    case "list_types":
      let timeZone = arguments.string("timeZone")
      try arguments.check()
      query = { tools, db in try tools.listTypes(timeZone: timeZone, db) }
    case "metric":
      let type = arguments.required("type", arguments.string)
      let range = arguments.required("range", arguments.range)
      let statistic = arguments.oneOf("statistic", HealthTools.Statistic.self)
      let date = arguments.string("date")
      let timeZone = arguments.string("timeZone")
      guard let type, let range, arguments.isValid else { throw arguments.invalid }
      query = { tools, db in
        try tools.metric(
          type: type, range: range, statistic: statistic, date: date, timeZone: timeZone, db)
      }
    case "samples":
      let type = arguments.required("type", arguments.string)
      let range = arguments.required("range", arguments.range)
      let date = arguments.string("date")
      let timeZone = arguments.string("timeZone")
      let cursor = arguments.string("cursor")
      let limit = arguments.integer("limit", in: 1...HealthTools.samplesLimit)
      guard let type, let range, arguments.isValid else { throw arguments.invalid }
      query = { tools, db in
        try tools.samples(
          type: type, range: range, date: date, timeZone: timeZone, cursor: cursor, limit: limit,
          db)
      }
    case "workouts":
      let range = arguments.required("range", arguments.range)
      let date = arguments.string("date")
      let timeZone = arguments.string("timeZone")
      guard let range, arguments.isValid else { throw arguments.invalid }
      query = { tools, db in try tools.workouts(range: range, date: date, timeZone: timeZone, db) }
    case "sleep":
      let range = arguments.required("range", arguments.range)
      let date = arguments.string("date")
      let timeZone = arguments.string("timeZone")
      guard let range, arguments.isValid else { throw arguments.invalid }
      query = { tools, db in try tools.sleep(range: range, date: date, timeZone: timeZone, db) }
    case "medications":
      let timeZone = arguments.string("timeZone")
      try arguments.check()
      query = { tools, db in try tools.medications(timeZone: timeZone, db) }
    case "health_details":
      let timeZone = arguments.string("timeZone")
      try arguments.check()
      query = { tools, db in try tools.healthDetails(timeZone: timeZone, db) }
    case "search":
      let text = arguments.required("query") { arguments.string($0, length: 1...100) }
      guard let text, arguments.isValid else { throw arguments.invalid }
      query = { tools, db in try tools.search(query: text, db) }
    case "sync_status":
      let timeZone = arguments.string("timeZone")
      try arguments.check()
      query = { tools, db in try tools.syncStatus(timeZone: timeZone, db) }
    case "list_cards":
      let timeZone = arguments.string("timeZone")
      try arguments.check()
      query = { tools, db in try tools.listCards(timeZone: timeZone, db) }
    case "get_card":
      let id = arguments.required("id", arguments.string)
      let range = arguments.oneOf("range", CardRange.self)
      let date = arguments.string("date")
      let timeZone = arguments.string("timeZone")
      let firstWeekday = arguments.oneOf("firstWeekday", ToolWeekday.self)
      guard let id, arguments.isValid else { throw arguments.invalid }
      query = { tools, db in
        try tools.getCard(
          id: id, range: range, date: date, timeZone: timeZone, firstWeekday: firstWeekday, db)
      }
    case "preview_card":
      // Any JSON: what isn't a spec comes back as the validator's errors, as on the remote server.
      let value = arguments.required("spec", arguments.any)
      let range = arguments.oneOf("range", CardRange.self)
      let date = arguments.string("date")
      let timeZone = arguments.string("timeZone")
      let firstWeekday = arguments.oneOf("firstWeekday", ToolWeekday.self)
      guard let value, arguments.isValid else { throw arguments.invalid }
      query = { tools, db in
        let spec = try HealthTools.parsedSpec(CardJSON(toolArgument: value))
        return try tools.previewCard(
          spec: spec, range: range, date: date, timeZone: timeZone, firstWeekday: firstWeekday,
          db)
      }
    default:
      throw HealthMCPServer.unknownTool(name)
    }
  }
}

/// Arguments outside a tool's input schema (851-4034): the tool's error, as on the remote server,
/// which answers them with its decoding's message (Effect's `McpServer`, from MCP 2025-11-25 on),
/// so the agent reads what to fix, e.g.
/// `Invalid parameters for tool 'metric': Expected "D" | "W" | "M" | "6M" | "Y"\n  at ["range"]`.
struct InvalidArguments: LocalizedError {
  /// What's wrong with one argument, in Effect's words, and where it is, e.g. `["ids"][0]`.
  struct Issue {
    var message: String
    var path: String
  }

  var tool: String
  var issues: [Issue]

  var errorDescription: String? {
    "Invalid parameters for tool '\(tool)': "
      + issues.map { "\($0.message)\n  at \($0.path)" }.joined(separator: "\n")
  }
}

/// Reads a call's arguments by name, collecting what doesn't fit the tool's input schema, in the
/// words of the remote server's decoding (Effect's `Schema`, with every issue): read them in the
/// schema's order, then check them (`check`, or `isValid` and `invalid`). A read that finds an
/// issue gives `nil`.
private final class Arguments {
  let tool: String
  let values: [String: Value]
  private var issues: [InvalidArguments.Issue] = []

  init(tool: String, values: [String: Value]) {
    self.tool = tool
    self.values = values
  }

  /// Whether every argument read so far fits the schema.
  var isValid: Bool { issues.isEmpty }

  /// The error for the arguments read so far.
  var invalid: InvalidArguments { InvalidArguments(tool: tool, issues: issues) }

  /// Fails with `invalid` unless every argument read so far fits the schema.
  func check() throws {
    guard isValid else { throw invalid }
  }

  private func issue(_ message: String, at name: String, index: Int? = nil) {
    // A path as Effect writes it: each key as JSON, in brackets.
    let path = "[\"\(name)\"]" + (index.map { "[\($0)]" } ?? "")
    issues.append(InvalidArguments.Issue(message: message, path: path))
  }

  func any(_ name: String) -> Value? { values[name] }

  func string(_ name: String) -> String? {
    guard let value = values[name] else { return nil }
    guard let string = value.argumentString else {
      issue("Expected string", at: name)
      return nil
    }
    return string
  }

  /// A string of `length` UTF-16 code units, as JavaScript counts them.
  func string(_ name: String, length: ClosedRange<Int>) -> String? {
    guard let string = string(name) else { return nil }
    guard length.contains(string.utf16.count) else {
      issue(
        "Expected a value with a length between \(length.lowerBound) and \(length.upperBound)",
        at: name)
      return nil
    }
    return string
  }

  /// One of an enum's raw values, in its case: the input schema lists them in `allCases`' order.
  func oneOf<Choice: RawRepresentable & CaseIterable>(
    _ name: String, _ choice: Choice.Type
  ) -> Choice? where Choice.RawValue == String {
    guard let value = values[name] else { return nil }
    guard let choice = value.argumentString.flatMap(Choice.init(rawValue:)) else {
      let allowed = Choice.allCases.map { "\"\($0.rawValue)\"" }
      issue("Expected " + allowed.joined(separator: " | "), at: name)
      return nil
    }
    return choice
  }

  func range(_ name: String) -> ToolRange? { oneOf(name, ToolRange.self) }

  /// A whole number in `bounds`. Both of its checks are made, as Effect's are: 0.5 is neither.
  func integer(_ name: String, in bounds: ClosedRange<Int>) -> Int? {
    guard let value = values[name] else { return nil }
    let number: Double
    switch value {
    case .int(let integer): number = Double(integer)
    case .double(let double): number = double
    default:
      issue("Expected number", at: name)
      return nil
    }
    // A safe integer, as JavaScript's `Number.isSafeInteger`.
    let isInteger = number.rounded() == number && abs(number) <= 9_007_199_254_740_991
    let isInBounds = number >= Double(bounds.lowerBound) && number <= Double(bounds.upperBound)
    if !isInteger { issue("Expected an integer", at: name) }
    if !isInBounds {
      issue(
        "Expected a value between \(bounds.lowerBound) and \(bounds.upperBound)", at: name)
    }
    return isInteger && isInBounds ? Int(number) : nil
  }

  /// An array of strings, at most `limit` of them. Its length is checked once every item is one.
  func strings(_ name: String, atMost limit: Int) -> [String]? {
    guard let value = values[name] else { return nil }
    guard case .array(let items) = value else {
      issue("Expected array", at: name)
      return nil
    }
    var strings: [String] = []
    for (index, item) in items.enumerated() {
      if let string = item.argumentString {
        strings.append(string)
      } else {
        issue("Expected string", at: name, index: index)
      }
    }
    guard strings.count == items.count else { return nil }
    guard strings.count <= limit else {
      issue("Expected a value with a length of at most \(limit)", at: name)
      return nil
    }
    return strings
  }

  /// A required argument: `read`'s, or an issue when it's missing.
  func required<Argument>(_ name: String, _ read: (String) -> Argument?) -> Argument? {
    guard values[name] != nil else {
      issue("Missing key", at: name)
      return nil
    }
    return read(name)
  }
}

extension Value {
  /// A string argument. `Value` decodes a string that's a data URL as `.data`, which is still a
  /// string to the remote server's schemas, so it's written back as one: the SDK keeps its data,
  /// not its text, so a data URL written another way (`data:,steps`) reads as its base64 form.
  fileprivate var argumentString: String? {
    switch self {
    case .string(let string): string
    case .data(let mimeType, let data): data.dataURLEncoded(mimeType: mimeType)
    default: nil
    }
  }
}

extension CardJSON {
  /// A tool's spec argument as JSON: as given, or parsed when it's a string, since some agents
  /// send objects as JSON text, as the remote server does. `nil` for text that isn't JSON.
  init?(toolArgument value: MCP.Value) {
    if case .string(let text) = value {
      guard let json = try? CardJSON(parsing: Data(text.utf8)) else { return nil }
      self = json
      return
    }
    guard let data = try? JSONEncoder().encode(value),
      let json = try? JSONDecoder().decode(CardJSON.self, from: data)
    else { return nil }
    self = json
  }
}
