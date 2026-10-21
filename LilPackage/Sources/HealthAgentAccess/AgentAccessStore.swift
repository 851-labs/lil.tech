public import Foundation
import GRDB

/// Whether command-line tools and agents may read lil health's data on this Mac, and the log of
/// what they read (851-2840). Shared by the app, which shows the setting and the log, and the
/// `lil-health` command and its MCP server, which check the setting before every query and log
/// each one.
///
/// Both live in a small SQLite database of their own, `AgentAccess.sqlite`, in the app's folder
/// in Application Support, next to the health database. A file rather than the app's user
/// defaults, so a separate executable reads and writes it the same way, and SQLite so several
/// processes can log at once. Every call opens it and closes it again: an MCP server that runs
/// for hours sees access turned off at its next query.
///
/// It's a consent switch, not a sandbox: anything running as the user could read the health
/// database directly.
public struct AgentAccessStore: Sendable {
  /// The database's file name, in `directory`.
  public static let fileName = "AgentAccess.sqlite"

  /// The app's own folder in Application Support, where the app keeps its health database. By
  /// bundle ID, which a command-line tool doesn't have, so it's spelled out.
  public static var defaultDirectory: URL {
    URL.applicationSupportDirectory.appending(path: "tech.lil.health", directoryHint: .isDirectory)
  }

  /// How many entries the log keeps: the oldest go as new ones come.
  public static let logLimit = 1_000

  /// The database file.
  public let url: URL

  public init(directory: URL = Self.defaultDirectory) {
    url = directory.appending(path: Self.fileName)
  }

  /// Whether access is on. Off until the app turns it on, including when there's no file yet.
  public func isEnabled() throws -> Bool {
    guard exists else { return false }
    return try open().read { db in
      try Bool.fetchOne(db, sql: #"SELECT "isEnabled" FROM "agentAccessSetting""#) ?? false
    }
  }

  /// Turns access on or off. Only the app does this.
  public func setEnabled(_ isEnabled: Bool, at date: Date = Date()) throws {
    try open().write { db in
      try db.execute(
        sql: """
          INSERT INTO "agentAccessSetting" ("id", "isEnabled", "changedAt") VALUES (1, ?, ?)
          ON CONFLICT ("id") DO UPDATE SET
            "isEnabled" = excluded."isEnabled", "changedAt" = excluded."changedAt"
          """,
        arguments: [isEnabled, date.timeIntervalSince1970])
    }
  }

  /// What a command-line tool or agent calls before each query: throws `AgentAccessError.off`
  /// while access is off, otherwise logs the query. Call it for every query, not once at launch.
  public func authorize(command: String, process: String, at date: Date = Date()) throws {
    guard try isEnabled() else { throw AgentAccessError.off }
    try record(command: command, process: process, at: date)
  }

  /// Logs a query: the command or MCP tool with its arguments (never what it answered), and the
  /// process that asked.
  public func record(command: String, process: String, at date: Date = Date()) throws {
    try open().write { db in
      try db.execute(
        sql: #"INSERT INTO "agentAccessLog" ("date", "command", "process") VALUES (?, ?, ?)"#,
        arguments: [date.timeIntervalSince1970, command, process])
      try db.execute(
        sql: """
          DELETE FROM "agentAccessLog" WHERE "id" <= (SELECT max("id") FROM "agentAccessLog") - ?
          """,
        arguments: [Self.logLimit])
    }
  }

  /// The log's latest entries, newest first. Empty when there's no file yet.
  public func entries(limit: Int = 100) throws -> [AgentAccessEntry] {
    guard exists else { return [] }
    return try open().read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT "id", "date", "command", "process" FROM "agentAccessLog"
          ORDER BY "id" DESC LIMIT ?
          """,
        arguments: [limit]
      )
      .map { row in
        AgentAccessEntry(
          id: row["id"], date: Date(timeIntervalSince1970: row["date"]), command: row["command"],
          process: row["process"])
      }
    }
  }

  /// Turns access off and empties the log, when the account signs out: the next account decides
  /// for itself.
  public func reset(at date: Date = Date()) throws {
    guard exists else { return }
    try setEnabled(false, at: date)
    try open().write { db in try db.execute(sql: #"DELETE FROM "agentAccessLog""#) }
  }

  private var exists: Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  private func open() throws -> DatabaseQueue {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var configuration = Configuration()
    // Another process may be writing: the app turning access off while a tool logs a query.
    configuration.busyMode = .timeout(5)
    let database = try DatabaseQueue(
      path: url.path(percentEncoded: false), configuration: configuration)
    try Self.migrator.migrate(database)
    return database
  }

  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("Create agent access") { db in
      try db.execute(
        sql: """
          CREATE TABLE "agentAccessSetting" (
            "id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 1),
            "isEnabled" INTEGER NOT NULL,
            "changedAt" REAL NOT NULL
          ) STRICT;
          CREATE TABLE "agentAccessLog" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT,
            "date" REAL NOT NULL,
            "command" TEXT NOT NULL,
            "process" TEXT NOT NULL
          ) STRICT;
          """)
    }
    return migrator
  }
}

/// A query a command-line tool or agent made.
public struct AgentAccessEntry: Identifiable, Equatable, Sendable {
  public var id: Int64
  public var date: Date
  /// The command or MCP tool, with its arguments, e.g. `metric Steps --range W`.
  public var command: String
  /// The process that asked, e.g. `claude`.
  public var process: String

  public init(id: Int64, date: Date, command: String, process: String) {
    self.id = id
    self.date = date
    self.command = command
    self.process = process
  }
}

public enum AgentAccessError: LocalizedError, Equatable {
  /// Access is off, as it is until the person turns it on.
  case off

  public var errorDescription: String? {
    switch self {
    case .off:
      """
      lil health's command-line and agent access is off. To turn it on, open lil health, choose \
      lil health › Settings…, then Agents, and turn on Allow command-line and agent access.
      """
    }
  }
}
