import Darwin
import Foundation
import MCP

/// `lil mcp` (851-2897): one local MCP server, on standard input and output, with every installed
/// lil app's tools, so an agent adds `lil mcp` once rather than a server per app.
///
/// It starts each known app's own server (`lil-<app> mcp`) as a child process, lists their tools
/// under the app's name (`health.summary`) and their resources as they are, and sends each request
/// on to the app's server. It checks no access of its own: each app's server checks and logs its
/// own app's switch, and names the agent in its log through `LIL_CALLING_PROCESS`.
enum LilMCPServer {
  /// What separates an app's name from its tool's: `health.summary`. App names have no dots, so a
  /// name splits at its first.
  static let separator: Character = "."

  /// The environment variable that names the agent in each app's access log
  /// (`AgentAccessStore.callingProcessVariable`), since the servers' parent is `lil`.
  static let callingProcessVariable = "LIL_CALLING_PROCESS"

  /// How long each app's server has to start.
  static let startTimeout = Duration.seconds(10)

  /// An app's server that started, and what it offers.
  struct App: Sendable {
    let name: String
    let server: AppServer
    let listing: AppServer.Listing
  }

  /// Serves on standard input and output until the client closes them, then ends the apps'
  /// servers and exits.
  static func serve(dispatcher: Dispatcher) -> Never {
    // A server that has exited closes its end of the pipe: writing to it fails rather than ending
    // `lil mcp`.
    signal(SIGPIPE, SIG_IGN)
    let environment = serversEnvironment(
      ProcessInfo.processInfo.environment, agent: parentProcessName())
    Task {
      let apps = await startApps(dispatcher: dispatcher, environment: environment)
      let server = await makeServer(apps: apps)
      var status: Int32 = 0
      do {
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
      } catch {
        FileHandle.standardError.write(Data("lil mcp: \(error.localizedDescription)\n".utf8))
        status = 1
      }
      for app in apps { await app.server.stop() }
      exit(status)
    }
    dispatchMain()
  }

  /// The apps' servers' environment: `lil mcp`'s, naming the agent that started it for their
  /// access logs, as `claude (via lil mcp)`.
  static func serversEnvironment(
    _ environment: [String: String], agent: String?
  ) -> [String: String] {
    var environment = environment
    environment[callingProcessVariable] = "\(agent ?? "unknown") (via lil mcp)"
    return environment
  }

  /// Starts the server of each known app with a tool, all at once, in the apps' order. A tool that
  /// has no `mcp`, or fails to start, is skipped with a line on standard error (`report`).
  static func startApps(
    dispatcher: Dispatcher,
    environment: [String: String],
    timeout: Duration = startTimeout,
    report: @escaping @Sendable (String) -> Void = {
      FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }
  ) async -> [App] {
    // Only the apps `lil` knows: another `lil-<something>` on `PATH` could do anything with an
    // argument it doesn't expect.
    let tools = dispatcher.knownApps.compactMap { app -> (String, URL)? in
      guard case .tool(let tool) = dispatcher.locate(app: app) else { return nil }
      return (app, tool)
    }
    return await withTaskGroup(of: (Int, App?).self) { group in
      for (index, (app, tool)) in tools.enumerated() {
        group.addTask {
          let server = AppServer(
            app: app, tool: tool, environment: environment, timeout: timeout)
          do {
            return (index, App(name: app, server: server, listing: try await server.start()))
          } catch {
            report("lil mcp: skipped lil \(app): \(error)")
            return (index, nil)
          }
        }
      }
      var apps = [App?](repeating: nil, count: tools.count)
      for await (index, app) in group { apps[index] = app }
      return apps.compactMap { $0 }
    }
  }

  /// The combined server, named "lil", with the apps' tools and resources.
  static func makeServer(apps: [App]) async -> Server {
    let tools = apps.flatMap { app in app.listing.tools.compactMap { namespaced($0, app: app.name) }
    }
    let resources = apps.flatMap(\.listing.resources)
    // The first app to list a URI reads it, as each app uses its own scheme (`health://`).
    var readers: [String: AppServer] = [:]
    for app in apps {
      for resource in app.listing.resources where readers[resource.uri] == nil {
        readers[resource.uri] = app.server
      }
    }
    let servers = Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0) })
    let byURI = readers

    let server = Server(
      name: "lil",
      version: String(LilCLI.version),
      title: "lil",
      instructions: instructions(apps: apps),
      capabilities: Server.Capabilities(
        resources: .init(subscribe: false, listChanged: false),
        // The servers are found once, when `lil mcp` starts.
        tools: .init(listChanged: false)))
    await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
    await server.withMethodHandler(CallTool.self) { parameters in
      guard let (app, tool) = route(parameters.name),
        let app = servers[app],
        app.listing.tools.contains(where: { $0.name == tool })
      else {
        throw MCPError.invalidParams("Unknown tool: \(parameters.name)")
      }
      // Not forwarded: progress and cancellation, since every tool is read-only and quick.
      return try await app.server.call(tool, arguments: parameters.arguments)
    }
    await server.withMethodHandler(ListResources.self) { _ in
      ListResources.Result(resources: resources)
    }
    await server.withMethodHandler(ReadResource.self) { parameters in
      guard let reader = byURI[parameters.uri] else {
        throw MCPError.invalidParams("Unknown resource: \(parameters.uri)")
      }
      return try await reader.read(parameters.uri)
    }
    return server
  }

  /// What the server tells agents when they connect: how tools are named, then each app's own
  /// instructions under its name.
  static func instructions(apps: [App]) -> String {
    guard let example = apps.first(where: { !$0.listing.tools.isEmpty }) else {
      return """
        Tools from the lil apps on this Mac, named <app>\(separator)<tool>. No lil app with tools \
        for agents is installed.
        """
    }
    let app = example.name
    let tool = example.listing.tools[0].name
    var text = """
      Tools from the lil apps on this Mac, each named <app>\(separator)<tool>: \
      \(app)\(separator)\(tool) is lil \(app)'s \(tool). Each app's own instructions follow, \
      under its name.
      """
    for app in apps {
      guard let instructions = app.listing.instructions, !instructions.isEmpty else { continue }
      text += "\n\n## lil \(app.name)\n\n\(instructions)"
    }
    return text
  }

  /// A tool listed under its app's name, otherwise unchanged.
  static func namespaced(_ tool: Tool, app: String) -> Tool? {
    // `Tool`'s name can't be set, so it's renamed in its JSON, which keeps every other field.
    guard
      var object = try? JSONDecoder().decode(
        [String: Value].self, from: JSONEncoder().encode(tool))
    else { return nil }
    object["name"] = .string("\(app)\(separator)\(tool.name)")
    return try? JSONDecoder().decode(Tool.self, from: JSONEncoder().encode(object))
  }

  /// The app and the tool's own name, split at the first separator.
  static func route(_ name: String) -> (app: String, tool: String)? {
    guard let index = name.firstIndex(of: separator) else { return nil }
    return (String(name[..<index]), String(name[name.index(after: index)...]))
  }

  /// The name of the process that started `lil`: the agent.
  static func parentProcessName() -> String? {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(getppid(), &path, UInt32(path.count)) > 0 else { return nil }
    let executable = String(
      decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return URL(filePath: executable).lastPathComponent
  }
}
