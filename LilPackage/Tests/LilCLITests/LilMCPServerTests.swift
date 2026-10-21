import Foundation
import GRDB
import HealthAgentAccess
import HealthDatabase
import MCP
import Synchronization
import Testing

@testable import LilCLI

/// `lil mcp` with two apps' real servers as its children: the built `lil-health` on a synthetic
/// database in a temporary home (`CFFIXED_USER_HOME`), never the real one, and `lil-example`, a
/// stand-in for a second app. `PATH` and the known apps are the test's.
@Suite
struct LilMCPServerTests {
  /// `swift test` builds every product next to the test bundle.
  static let products = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()

  let root: URL
  let bin: URL
  let health: URL
  let access: AgentAccessStore
  let environment: [String: String]

  init() throws {
    root = try makeTemporaryDirectory()
    bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: bin.appending(path: "lil-health"),
      withDestinationURL: Self.products.appending(path: "lil-health-dev"))
    try FileManager.default.createSymbolicLink(
      at: bin.appending(path: "lil-example"),
      withDestinationURL: Self.products.appending(path: "lil-example"))
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    health = home.appending(path: "Library/Application Support/tech.lil.health")
    try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
    try HealthDatabase.migrator.migrate(
      DatabasePool(path: health.appending(path: "Health.sqlite").path))
    access = AgentAccessStore(directory: health)
    environment = LilMCPServer.serversEnvironment(
      ["CFFIXED_USER_HOME": home.path, "TZ": "UTC", "PATH": "/usr/bin:/bin"], agent: "claude")
  }

  func dispatcher(_ apps: [String] = ["example", "health"]) -> Dispatcher {
    Dispatcher(
      applicationURL: { _ in nil }, searchPath: [bin], describe: { _ in nil }, version: 42,
      knownApps: apps)
  }

  /// `lil mcp`'s server with the apps' servers started, and a client connected to it.
  func connect(
    _ apps: [String] = ["example", "health"],
    timeout: Duration = LilMCPServer.startTimeout,
    reports: Reports = Reports()
  ) async throws -> Connection {
    try #require(
      FileManager.default.isExecutableFile(
        atPath: Self.products.appending(path: "lil-example").path))
    let started = await LilMCPServer.startApps(
      dispatcher: dispatcher(apps), environment: environment, timeout: timeout,
      report: reports.append)
    return try await Connection(apps: started)
  }

  @Test
  func initializesAsLilWithEachAppsInstructions() async throws {
    let connection = try await connect()
    let initialized = connection.initialized
    #expect(initialized.serverInfo.name == "lil")
    #expect(initialized.serverInfo.version == String(LilCLI.version))
    #expect(initialized.capabilities.tools?.listChanged == false)
    let instructions = try #require(initialized.instructions)
    #expect(instructions.hasPrefix("Tools from the lil apps on this Mac, each named <app>.<tool>"))
    #expect(instructions.contains("example.echo is lil example's echo"))
    #expect(instructions.contains("\n\n## lil example\n\nEchoes text.\n\n## lil health\n\n"))
    await connection.close()
  }

  /// Both apps' tools, under their names, exactly as each app lists them otherwise.
  @Test
  func listsEachAppsToolsUnderItsName() async throws {
    let connection = try await connect()
    let tools = try await connection.client.listTools().tools
    #expect(tools.first?.name == "example.echo")
    #expect(tools.dropFirst().allSatisfy { $0.name.hasPrefix("health.") })
    #expect(tools.contains { $0.name == "health.summary" })

    var own: [(app: String, tool: Tool)] = []
    for app in connection.apps {
      let server = AppServer(
        app: app.name, tool: app.server.tool, environment: environment, timeout: .seconds(10))
      own += try await server.startedAndStopped().tools.map { (app.name, $0) }
    }
    #expect(tools.count == own.count)
    for (tool, (app, original)) in zip(tools, own) {
      #expect(tool.name == "\(app).\(original.name)")
      #expect(try json(tool, without: "name") == json(original, without: "name"))
    }
    await connection.close()
  }

  @Test
  func routesCallsToTheirAppsServer() async throws {
    let connection = try await connect()
    let echo = try await connection.call("example.echo", ["text": "a.b"])
    #expect(echo.isError == false)
    #expect(
      echo.structuredContent
        == ["text": "a.b", "callingProcess": "claude (via lil mcp)"])
    // The app's own error result comes back as it is.
    #expect(try await connection.call("example.echo", ["text": "fail"]).isError == true)

    // As lil-health mcp answers it, and logged with the agent's name.
    try access.setEnabled(true)
    let types = try await connection.call("health.list_types", ["timeZone": "UTC"])
    #expect(types.isError == false)
    let own = try await AppServer(
      app: "health", tool: bin.appending(path: "lil-health"), environment: environment,
      timeout: .seconds(10)
    ).calledAndStopped("list_types", ["timeZone": "UTC"])
    // The text is the same JSON, though its keys' order may differ from one process to another.
    #expect(types.structuredContent == own.structuredContent && types.isError == own.isError)
    #expect(
      try JSONDecoder().decode(Value.self, from: Data(types.text.utf8))
        == JSONDecoder().decode(Value.self, from: Data(own.text.utf8)))
    #expect(
      try access.entries().map(\.process) == ["claude (via lil mcp)", "claude (via lil mcp)"])
    #expect(
      try access.entries().map(\.command) == [
        #"list_types {"timeZone":"UTC"}"#, #"list_types {"timeZone":"UTC"}"#,
      ])
    await connection.close()
  }

  @Test
  func passesOnAnAppsAccessBeingOff() async throws {
    let connection = try await connect()
    let summary = try await connection.call("health.summary")
    #expect(summary.isError == true)
    #expect(summary.text.contains("Settings"))
    #expect(try access.entries().isEmpty)
    await connection.close()
  }

  @Test
  func readsResourcesFromTheAppThatListedThem() async throws {
    let connection = try await connect()
    let resources = try await connection.client.listResources().resources
    #expect(resources.map(\.uri) == ["example://greeting", "health://catalog"])

    let greeting = try await connection.client.readResource(uri: "example://greeting")
    #expect(
      greeting == [
        .text("Hello from lil example.", uri: "example://greeting", mimeType: "text/plain")
      ])
    let catalog = try await connection.client.readResource(uri: "health://catalog")
    #expect(catalog.count == 1)

    await #expect(throws: MCPError.invalidParams("Unknown resource: health://nope")) {
      _ = try await connection.client.readResource(uri: "health://nope")
    }
    await connection.close()
  }

  @Test(arguments: ["nope.summary", "summary", "health.nope", "example.", ".echo"])
  func unknownAppsAndToolsAreInvalidParams(name: String) async throws {
    let connection = try await connect()
    await #expect(throws: MCPError.invalidParams("Unknown tool: \(name)")) {
      _ = try await connection.call(name)
    }
    await connection.close()
  }

  /// A tool that exits instead of serving (`lil-health` before it had `mcp` did, with a usage
  /// error), or hangs, is skipped with a line on standard error, and the others still serve. A
  /// `lil-<app>` on `PATH` for an app `lil` doesn't know is never run.
  @Test
  func skipsServersThatDontStart() async throws {
    try writeScript("echo 'unknown command' >&2; exit 64", to: bin.appending(path: "lil-old"))
    try writeScript("touch \"$0.ran\"; exit 0", to: bin.appending(path: "lil-stranger"))
    let reports = Reports()
    let connection = try await connect(["example", "missing", "old", "example"], reports: reports)
    #expect(connection.apps.map(\.name) == ["example"])
    #expect(reports.lines == ["lil mcp: skipped lil old: lil-old mcp exited with status 64"])
    #expect(!FileManager.default.fileExists(atPath: bin.appending(path: "lil-stranger.ran").path))
    #expect(try await connection.call("example.echo", ["text": "hi"]).isError == false)

    try writeScript("exec sleep 60", to: bin.appending(path: "lil-hangs"))
    let hung = Reports()
    let started = Date()
    let none = try await connect(["hangs"], timeout: .milliseconds(300), reports: hung)
    #expect(none.apps.isEmpty)
    #expect(
      hung.lines == [
        "lil mcp: skipped lil hangs: lil-hangs mcp didn't start within 300 milliseconds"
      ])
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(none.initialized.instructions?.contains("No lil app with tools") == true)
    await none.close()
    await connection.close()
  }

  /// A server that exits is started again at the next call to one of its tools, with one
  /// attempt. If that fails, its tools answer with an error from then on.
  @Test
  func startsAServerThatExitedAgainOnce() async throws {
    let connection = try await connect(["example"])
    let example = try #require(connection.apps.first?.server)
    let first = try #require(await example.processIdentifier)
    // It exits while it answers.
    let exited = try await connection.call("example.echo", ["text": "exit"])
    #expect(exited.isError == true)
    #expect(
      exited.text
        == "lil example's server stopped before it answered. Call again to start it again.")
    #expect(await example.processIdentifier == nil)

    let echo = try await connection.call("example.echo", ["text": "again"])
    #expect(echo.isError == false && echo.text == "again")
    let second = try #require(await example.processIdentifier)
    #expect(second != first)

    // Now it can't start.
    try FileManager.default.removeItem(at: bin.appending(path: "lil-example"))
    try writeScript("exit 1", to: bin.appending(path: "lil-example"))
    try await kill(second)
    for _ in 0..<2 {
      let stopped = try await connection.call("example.echo", ["text": "again"])
      #expect(stopped.isError == true)
      #expect(stopped.text == "lil example's server stopped.")
    }
    await #expect(throws: MCPError.internalError("lil example's server stopped.")) {
      _ = try await connection.client.readResource(uri: "example://greeting")
    }
    await connection.close()
  }

  @Test
  func namesTheAgentForTheAppsLogs() {
    #expect(
      LilMCPServer.serversEnvironment(["PATH": "/bin"], agent: "claude")
        == ["PATH": "/bin", "LIL_CALLING_PROCESS": "claude (via lil mcp)"])
    #expect(
      LilMCPServer.serversEnvironment([:], agent: nil)
        == ["LIL_CALLING_PROCESS": "unknown (via lil mcp)"])
  }

  /// Kills a server's process and waits until it's gone.
  private func kill(_ pid: Int32) async throws {
    #expect(Darwin.kill(pid, SIGKILL) == 0)
    for _ in 0..<500 where Darwin.kill(pid, 0) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func json(_ tool: Tool, without key: String) throws -> Value {
    var object = try JSONDecoder().decode([String: Value].self, from: JSONEncoder().encode(tool))
    object[key] = nil
    return .object(object)
  }
}

/// A client connected in memory to `lil mcp`'s server for `apps`.
struct Connection: Sendable {
  let apps: [LilMCPServer.App]
  let server: Server
  let client: MCP.Client
  let initialized: Initialize.Result

  init(apps: [LilMCPServer.App]) async throws {
    self.apps = apps
    server = await LilMCPServer.makeServer(apps: apps)
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    client = MCP.Client(name: "LilMCPServerTests", version: "1")
    initialized = try await client.connect(transport: clientTransport)
  }

  func call(_ name: String, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
    try await client.send(CallTool.request(.init(name: name, arguments: arguments))).value
  }

  func close() async {
    await client.disconnect()
    await server.stop()
    for app in apps { await app.server.stop() }
  }
}

/// What `lil mcp` wrote to standard error.
final class Reports: Sendable {
  private let storage = Mutex<[String]>([])

  var lines: [String] { storage.withLock { $0 } }

  @Sendable func append(_ line: String) {
    storage.withLock { $0.append(line) }
  }
}

extension AppServer {
  /// Its listing, from a server of its own that's then stopped.
  func startedAndStopped() async throws -> Listing {
    let listing = try await start()
    await stop()
    return listing
  }

  /// A call's result, from a server of its own that's then stopped.
  func calledAndStopped(_ name: String, _ arguments: [String: Value]) async throws
    -> CallTool.Result
  {
    _ = try await start()
    let result = try await call(name, arguments: arguments)
    await stop()
    return result
  }
}

extension CallTool.Result {
  var text: String {
    content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
  }
}

private final class Marker {}
