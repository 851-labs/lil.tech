public import Foundation
import GRDB

/// Whether command-line tools and agents may read lil health's data on this Mac, and the log of
/// what they read (851-2840). Shared by the app, which shows the setting and the log, and the
/// `lil-health` command and its MCP server, which check the setting before every query and log
/// each one.
///
/// Both live in a small SQLite database of their own, `AgentAccess.sqlite`, in the Mac app's
/// folder in Application Support (`HealthDatabase.macDirectory`), next to the health database. A file rather than the app's user
/// defaults, so a separate executable reads and writes it the same way, and SQLite so several
/// processes can log at once. Every call opens it and closes it again: an MCP server that runs
/// for hours sees access turned off at its next query.
///
/// It also holds the command line's requests for the app to act (`requestAction`, 851-2895).
///
/// It's a consent switch, not a sandbox: anything running as the user could read the health
/// database directly.
public struct AgentAccessStore: Sendable {
  /// The database's file name, in `directory`.
  public static let fileName = "AgentAccess.sqlite"

  /// How many entries the log keeps: the oldest go as new ones come.
  public static let logLimit = 1_000

  /// The database file.
  public let url: URL

  public init(directory: URL) {
    url = directory.appending(path: Self.fileName)
  }

  /// Whether access is on. Off until the app turns it on, including when there's no file yet.
  public func isEnabled() throws -> Bool {
    guard exists else { return false }
    return try open().read(Self.isEnabled)
  }

  /// Turns access on or off, as the person did at `date`. Only the app does this. A change from
  /// before the one saved is ignored, so saves that finish out of order end as the person left
  /// the setting, and one made before signing out can't undo `reset`.
  public func setEnabled(_ isEnabled: Bool, at date: Date = Date()) throws {
    try open().write { db in try Self.setEnabled(isEnabled, at: date, db) }
  }

  /// What a command-line tool or agent calls before each query: throws `AgentAccessError.off`
  /// while access is off, otherwise logs the query, in one transaction. Call it for every query,
  /// not once at launch.
  public func authorize(command: String, process: String, at date: Date = Date()) throws {
    // No file: off, and nothing to create.
    guard exists else { throw AgentAccessError.off }
    try open().write { db in
      guard try Self.isEnabled(db) else { throw AgentAccessError.off }
      try Self.record(command: command, process: process, at: date, db)
    }
  }

  /// Logs a query: the command or MCP tool with its arguments (never what it answered), and the
  /// process that asked. `authorize` does this once it has checked access.
  public func record(command: String, process: String, at date: Date = Date()) throws {
    try open().write { db in try Self.record(command: command, process: process, at: date, db) }
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
  /// for itself. Creates the file if there's none, so a save from before that's still running
  /// can't turn access on after it. The command line's requests go too: those not finished fail
  /// as signed out, so a command waiting on one hears why (`resetActions`).
  public func reset(at date: Date = Date()) throws {
    try open().write { db in
      try Self.setEnabled(false, at: date, db)
      try db.execute(sql: #"DELETE FROM "agentAccessLog""#)
      try Self.resetActions(at: date, db)
    }
  }

  static func isEnabled(_ db: Database) throws -> Bool {
    try Bool.fetchOne(db, sql: #"SELECT "isEnabled" FROM "agentAccessSetting""#) ?? false
  }

  private static func setEnabled(_ isEnabled: Bool, at date: Date, _ db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO "agentAccessSetting" ("id", "isEnabled", "changedAt") VALUES (1, ?, ?)
        ON CONFLICT ("id") DO UPDATE SET
          "isEnabled" = excluded."isEnabled", "changedAt" = excluded."changedAt"
        WHERE excluded."changedAt" >= "agentAccessSetting"."changedAt"
        """,
      arguments: [isEnabled, date.timeIntervalSince1970])
  }

  static func record(
    command: String, process: String, at date: Date, _ db: Database
  ) throws {
    try db.execute(
      sql: #"INSERT INTO "agentAccessLog" ("date", "command", "process") VALUES (?, ?, ?)"#,
      arguments: [date.timeIntervalSince1970, command, process])
    try db.execute(
      sql: """
        DELETE FROM "agentAccessLog" WHERE "id" <= (SELECT max("id") FROM "agentAccessLog") - ?
        """,
      arguments: [logLimit])
  }

  var exists: Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  func open() throws -> DatabaseQueue {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var configuration = Configuration()
    // Another process may be writing: the app turning access off while a tool logs a query.
    configuration.busyMode = .timeout(5)
    let database = try DatabaseQueue(
      path: url.path(percentEncoded: false), configuration: configuration)
    // `IF NOT EXISTS` rather than a migrator, whose check of what's applied isn't in the same
    // transaction as applying it, so two processes opening a new file could both create the
    // tables. A later change to the schema needs the same care.
    try database.write { db in
      try db.execute(
        sql: """
          CREATE TABLE IF NOT EXISTS "agentAccessSetting" (
            "id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 1),
            "isEnabled" INTEGER NOT NULL,
            "changedAt" REAL NOT NULL
          ) STRICT;
          CREATE TABLE IF NOT EXISTS "agentAccessLog" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT,
            "date" REAL NOT NULL,
            "command" TEXT NOT NULL,
            "process" TEXT NOT NULL
          ) STRICT;
          CREATE TABLE IF NOT EXISTS "actionRequests" (
            "id" TEXT PRIMARY KEY NOT NULL,
            "action" TEXT NOT NULL,
            "requestedAt" REAL NOT NULL,
            "requesterPID" INTEGER NOT NULL,
            "requesterStartedAt" INTEGER NOT NULL,
            "claimedAt" REAL,
            "claimerPID" INTEGER,
            "claimerStartedAt" INTEGER,
            "finishedAt" REAL,
            "outcome" TEXT CHECK ("outcome" IN ('ok', 'failed')),
            "result" TEXT,
            "failureReason" TEXT,
            "error" TEXT
          ) STRICT;
          """)
    }
    return database
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
      "lil health doesn't allow access on this Mac. Turn on Allow access on this Mac in lil health › Settings… › Agents."
    }
  }
}
