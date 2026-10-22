import Darwin
import Foundation
import MCP
import Synchronization
import System

/// One app's own MCP server, `lil-<app> mcp`, which `lil mcp` runs as a child process over pipes
/// and speaks to as an MCP client (851-2897).
///
/// It's started once, when `lil mcp` starts, and what it lists then is what `lil mcp` lists. If it
/// exits, the next request to it starts it again, with one attempt, not retries: if that fails,
/// its tools answer with an error from then on.
actor AppServer {
  /// The app, by the name `lil` knows it by (`health`).
  nonisolated let app: String
  /// Its command line tool, `lil-<app>`.
  nonisolated let tool: URL
  /// The environment it runs in.
  nonisolated let environment: [String: String]
  /// How long it has to start: to initialize, and list its tools and resources, together.
  nonisolated let timeout: Duration

  /// What a started server offered.
  struct Listing: Sendable {
    var tools: [Tool] = []
    var resources: [Resource] = []
    var instructions: String?
  }

  /// Why a server didn't start, as `lil mcp`'s line on standard error says it.
  struct StartError: Error, CustomStringConvertible {
    var description: String
  }

  /// The running process and the client connected to it.
  private struct Connection: Sendable {
    let process: Process
    let client: Client
    /// Kept for as long as the connection, since they own the file descriptors.
    let pipes: [Pipe]
  }

  private var connection: Connection?
  /// A start in progress, which calls that arrive meanwhile wait for.
  private var starting: Task<Connection, any Error>?
  /// Whether starting it again failed, after which its tools answer with an error.
  private var stopped = false

  init(app: String, tool: URL, environment: [String: String], timeout: Duration) {
    self.app = app
    self.tool = tool
    self.environment = environment
    self.timeout = timeout
  }

  /// Starts it and returns what it offers.
  func start() async throws -> Listing {
    let (connection, listing) = try await launch()
    self.connection = connection
    return listing
  }

  /// Calls one of its tools by its own name, starting it again first if it has exited. Its result
  /// comes back as it is, and its protocol errors are thrown as they are.
  func call(_ name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
    guard let connection = await connectionForRequest() else { return stoppedResult }
    do {
      return try await connection.client.send(
        CallTool.request(.init(name: name, arguments: arguments))
      ).value
    } catch {
      if await hasExited(connection, after: error) { return exitedResult }
      throw error
    }
  }

  /// Reads one of its resources, starting it again first if it has exited.
  func read(_ uri: String) async throws -> ReadResource.Result {
    guard let connection = await connectionForRequest() else {
      throw MCPError.internalError(stoppedMessage)
    }
    do {
      return try await connection.client.send(ReadResource.request(.init(uri: uri))).value
    } catch {
      if await hasExited(connection, after: error) { throw MCPError.internalError(exitedMessage) }
      throw error
    }
  }

  /// Ends it, when `lil mcp` ends.
  func stop() async {
    stopped = true
    if let connection { await end(connection) }
    connection = nil
  }

  /// The process ID of the running server, for tests.
  var processIdentifier: Int32? {
    connection.flatMap { $0.process.isRunning ? $0.process.processIdentifier : nil }
  }

  private var stoppedMessage: String { "lil \(app)'s server stopped." }

  /// The command, as messages name it: `lil-health mcp`.
  private var name: String { "\(tool.lastPathComponent) mcp" }

  /// What a request it was answering when it exited says. The next request starts it again.
  private var exitedMessage: String {
    "lil \(app)'s server stopped before it answered. Call again to start it again."
  }

  private var stoppedResult: CallTool.Result { errorResult(stoppedMessage) }

  private var exitedResult: CallTool.Result { errorResult(exitedMessage) }

  private func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
  }

  /// The running server, started again if it has exited, or nil if that fails.
  private func connectionForRequest() async -> Connection? {
    if let connection, connection.process.isRunning { return connection }
    if let starting { return try? await starting.value }
    guard !stopped else { return nil }
    // Nothing is awaited before `starting` is set, so calls that arrive meanwhile wait for it.
    let exited = connection
    connection = nil
    let task = Task {
      if let exited { await self.end(exited) }
      return try await self.launch().connection
    }
    starting = task
    defer { starting = nil }
    do {
      let connection = try await task.value
      // `lil mcp` ended while it was starting.
      guard !stopped else {
        await end(connection)
        return nil
      }
      self.connection = connection
      return connection
    } catch {
      stopped = true
      FileHandle.standardError.write(
        Data("lil mcp: lil \(app)'s server stopped, and didn't start again: \(error)\n".utf8))
      return nil
    }
  }

  /// Whether a request failed because the server exited. Errors it answered with are its own;
  /// a request it never answered may have failed just before its process was seen to exit.
  private func hasExited(_ connection: Connection, after error: any Error) async -> Bool {
    switch error as? MCPError {
    // The client's own failures: it disconnected when the process exited (`terminationHandler`),
    // or couldn't write to it.
    case .internalError("Client disconnected"), .connectionClosed, .transportError:
      return await Self.hasExited(connection.process)
    default:
      return false
    }
  }

  /// Whether `process` has exited, or does within a second.
  private static func hasExited(_ process: Process) async -> Bool {
    for _ in 0..<100 where process.isRunning {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return !process.isRunning
  }

  /// Runs `lil-<app> mcp`, initializes it and lists its tools and resources, all within
  /// `timeout`.
  private func launch() async throws -> (connection: Connection, listing: Listing) {
    let input = Pipe()
    let output = Pipe()
    let process = Process()
    process.executableURL = tool
    process.arguments = ["mcp"]
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    // Its standard error is `lil mcp`'s, so what it says there reaches the agent's log.
    let client = Client(name: "lil", version: String(LilCLI.version))
    let connection = Connection(process: process, client: client, pipes: [input, output])
    // A request it hasn't answered fails when it exits, rather than waiting forever.
    process.terminationHandler = { _ in Task { await client.disconnect() } }
    // Writing to a server that has exited fails, rather than ending `lil mcp` with SIGPIPE.
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    do {
      try process.run()
    } catch {
      throw StartError(description: "couldn't run \(tool.path): \(error.localizedDescription)")
    }
    let transport = StdioTransport(
      input: FileDescriptor(rawValue: output.fileHandleForReading.fileDescriptor),
      output: FileDescriptor(rawValue: input.fileHandleForWriting.fileDescriptor))
    do {
      let listing = try await ending(connection, after: timeout) {
        let initialized = try await client.connect(transport: transport)
        var listing = Listing(instructions: initialized.instructions)
        if initialized.capabilities.tools != nil {
          listing.tools = try await client.allTools()
        }
        if initialized.capabilities.resources != nil {
          listing.resources = try await client.allResources()
        }
        return listing
      }
      return (connection, listing)
    } catch is TimedOut {
      throw StartError(description: "\(name) didn't start within \(timeout.text)")
    } catch {
      // A tool without `mcp` exits with a usage error, which ends the request.
      guard await Self.hasExited(process) else {
        await end(connection)
        throw StartError(description: "\(name) didn't start: \(error)")
      }
      await end(connection)
      throw StartError(
        description: process.terminationReason == .uncaughtSignal
          ? "\(name) was ended by signal \(process.terminationStatus)"
          : "\(name) exited with status \(process.terminationStatus)")
    }
  }

  /// Runs `operation`, or ends the server if it takes longer than `timeout`.
  private func ending<T: Sendable>(
    _ connection: Connection, after timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withTimeout(timeout, onTimeout: { await self.end(connection) }, operation)
  }

  /// Ends a server's process and its client.
  private func end(_ connection: Connection) async {
    if connection.process.isRunning { connection.process.terminate() }
    await connection.client.disconnect()
  }
}

extension Client {
  /// Every tool, across pages.
  fileprivate func allTools() async throws -> [Tool] {
    var (tools, cursor) = try await listTools()
    while let next = cursor {
      let page = try await listTools(cursor: next)
      tools += page.tools
      cursor = page.nextCursor
    }
    return tools
  }

  /// Every resource, across pages.
  fileprivate func allResources() async throws -> [Resource] {
    var (resources, cursor) = try await listResources()
    while let next = cursor {
      let page = try await listResources(cursor: next)
      resources += page.resources
      cursor = page.nextCursor
    }
    return resources
  }
}

/// The error `withTimeout` throws when the time runs out.
struct TimedOut: Error {}

/// Runs `operation`, or, if it takes longer than `timeout`, runs `onTimeout` and throws
/// `TimedOut` without waiting for it: an MCP request that's never answered doesn't end when its
/// task is cancelled.
func withTimeout<T: Sendable>(
  _ timeout: Duration,
  onTimeout: @escaping @Sendable () async -> Void,
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let outcome = Mutex<CheckedContinuation<T, any Error>?>(nil)
  let finish = { @Sendable (result: Result<T, any Error>) -> Bool in
    guard let continuation = outcome.withLock({ $0.take() }) else { return false }
    continuation.resume(with: result)
    return true
  }
  return try await withCheckedThrowingContinuation { continuation in
    outcome.withLock { $0 = continuation }
    let timer = Task {
      guard (try? await Task.sleep(for: timeout)) != nil, finish(.failure(TimedOut())) else {
        return
      }
      await onTimeout()
    }
    Task {
      let result: Result<T, any Error>
      do {
        result = .success(try await operation())
      } catch {
        result = .failure(error)
      }
      timer.cancel()
      _ = finish(result)
    }
  }
}

extension Duration {
  /// The duration in words, for messages: `10 seconds`.
  fileprivate var text: String {
    formatted(.units(allowed: [.seconds, .milliseconds], width: .wide))
  }
}
