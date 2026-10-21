import ArgumentParser
public import Foundation
import GRDB
import HealthAgentAccess
import HealthDatabase
import HealthTools

/// `lil-health`, lil health for Mac's command-line tool (851-2843): the Health toolkit's queries
/// on the Mac's synced database, as text or `--json`. It ships inside the app
/// (`Contents/MacOS/lil-health`), and `lil health …` runs it.
///
/// It reads only while the person allows command-line and agent access in the app's settings,
/// and logs each query there (851-2840). It opens the database read-only and never migrates it.
/// `lil-health mcp` serves the same queries to agents, as a local MCP server (851-2844).
public enum HealthCLI {
  /// What `lil help` lists it with (`--describe`).
  public static let description = "Reads lil health's data on this Mac: summary, metrics, sleep…"

  /// Runs `lil-health` with the process's arguments, then exits.
  public static func main() -> Never {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if (try? LilHealthCommand.parseAsRoot(arguments)) is MCPCommand {
      HealthMCPServer.serve(context: .live())
    }
    let outcome = run(arguments, context: .live())
    FileHandle.standardOutput.write(Data(outcome.output.utf8))
    FileHandle.standardError.write(Data(outcome.error.utf8))
    exit(outcome.status)
  }

  /// Where it reads, and what it tells the access log.
  public struct Context: Sendable {
    /// The app's folder, with `Health.sqlite` and `AgentAccess.sqlite`.
    public var directory: URL
    /// The clock: today, and what has happened by now.
    public var now: @Sendable () -> Date
    /// The process that ran it, for the access log: a shell, or an agent.
    public var process: String
    /// The IANA time zone of queries that don't name one, or `nil` for the Mac's.
    public var timeZone: String?

    public init(
      directory: URL, now: @escaping @Sendable () -> Date, process: String,
      timeZone: String? = nil
    ) {
      self.directory = directory
      self.now = now
      self.process = process
      self.timeZone = timeZone
    }

    /// The app's own folder, the clock, and the parent process.
    public static func live() -> Self {
      Self(
        directory: HealthDatabase.macDirectory, now: { Date() },
        process: AgentAccessStore.callingProcess() ?? "unknown")
    }
  }

  /// What a run printed, and its exit status.
  public struct Outcome: Equatable, Sendable {
    public var output = ""
    public var error = ""
    public var status: Int32 = 0
  }

  /// Exit statuses, from `sysexits.h`.
  enum Status {
    /// A query's arguments were wrong (an unknown type or time zone).
    static let dataError: Int32 = 65
    /// There's no database to read, or not one this version can.
    static let unavailable: Int32 = 69
    /// Command-line and agent access is off.
    static let noPermission: Int32 = 77
  }

  /// Parses `arguments` (without the program's name) and runs them.
  public static func run(_ arguments: [String], context: Context) -> Outcome {
    let command: any ParsableCommand
    do {
      command = try LilHealthCommand.parseAsRoot(arguments)
    } catch {
      return failure(error)
    }
    do {
      switch command {
      case let root as LilHealthCommand:
        return Outcome(
          output: root.describe ? description + "\n" : LilHealthCommand.helpMessage() + "\n")
      case let query as any QueryCommand:
        return Outcome(output: try perform(query, arguments: arguments, context: context))
      case is MCPCommand:
        // `main` serves it: it runs until the client closes standard input.
        return Outcome(error: "lil-health: mcp only runs as its own process.\n", status: 64)
      default:
        // ArgumentParser's own commands (`help <command>`) print for themselves.
        var command = command
        try command.run()
        return Outcome()
      }
    } catch {
      return failure(error)
    }
  }

  /// Checks access and logs the query, then answers it from the database.
  static func perform(
    _ command: any QueryCommand, arguments: [String], context: Context
  ) throws -> String {
    // Before every query, not once: turning access off stops the next one.
    try AgentAccessStore(directory: context.directory)
      .authorize(command: commandLine(arguments), process: context.process)
    let database = try HealthDatabase.openForReading(
      at: context.directory.appending(path: "Health.sqlite"))
    let tools = HealthTools(now: context.now(), defaultTimeZone: context.timeZone)
    let answer = try database.read { db in try command.answer(tools, db) }
    guard command.output.json else { return answer.text }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(answer.json), as: UTF8.self) + "\n"
  }

  private static func failure(_ error: any Error) -> Outcome {
    let message = { (status: Int32) in
      Outcome(error: "lil-health: \(error.localizedDescription)\n", status: status)
    }
    switch error {
    case is AgentAccessError: return message(Status.noPermission)
    // Including SQLite's: a damaged database, or one the app kept locked past the timeout.
    case is HealthDatabase.ReadError, is DatabaseError: return message(Status.unavailable)
    case is HealthToolError: return message(Status.dataError)
    default:
      let text = LilHealthCommand.fullMessage(for: error) + "\n"
      let status = LilHealthCommand.exitCode(for: error).rawValue
      // Help goes to standard output, errors to standard error.
      return status == 0 ? Outcome(output: text) : Outcome(error: text, status: status)
    }
  }

  /// The arguments as a shell would take them, for the access log: `metric Steps --range W`.
  static func commandLine(_ arguments: [String]) -> String {
    arguments.map { argument in
      let plain =
        !argument.isEmpty
        && argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./:+=@,".contains($0) }
      return plain ? argument : "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
    .joined(separator: " ")
  }
}
