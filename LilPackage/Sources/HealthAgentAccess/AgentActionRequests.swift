public import Foundation
import GRDB
import HealthCatalog

#if os(macOS)
  import Darwin
#endif

// The command line's app actions (851-2895): `lil-health open`, `sync` and `export` (851-2896)
// ask lil health for Mac to act by writing a request into `AgentAccess.sqlite`, then waking the
// app (`AgentActionSignal`) or launching it. The row is the permission: only a process running as
// the person can write it, as with the access switch. The app claims requests when it launches
// and on each signal, performs them as its intents do (`HealthAppActions`), and writes the
// outcome, which the command polls.

/// An action the command line asks the app for.
public enum AgentAction: Equatable, Sendable {
  /// Brings the main window forward and shows a page, by its ID: `summary`, `health-details`,
  /// `category:<raw value>` or `type:<HealthKit identifier>` (the app's `HealthPage.id`).
  case open(page: String)
  /// Pulls the account's changes now, and waits for the pull to end.
  case sync
  /// Exports the account's data into the folder at this absolute path.
  case export(folder: String)

  /// The action as the access log shows it, the same as the app's intents log it: `open Steps`,
  /// `sync`, `export ~/Downloads`.
  public var command: String {
    switch self {
    case .open(let page): "open \(Self.pageName(page))"
    case .sync: "sync"
    case .export(let folder): "export \((folder as NSString).abbreviatingWithTildeInPath)"
    }
  }

  /// The name the sidebar shows for a page ID, or the ID itself if it isn't one.
  static func pageName(_ id: String) -> String {
    if id == "summary" { return "Summary" }
    if id == "health-details" { return "Health Details" }
    if id.hasPrefix("category:"),
      let category = HealthCategory(rawValue: String(id.dropFirst("category:".count)))
    {
      return category.name
    }
    if id.hasPrefix("type:"), let type = HealthCatalog.type(id: String(id.dropFirst("type:".count)))
    {
      return type.name
    }
    return id
  }
}

/// Stored as `{"action": "open", "page": "type:…"}`, `{"action": "sync"}` or
/// `{"action": "export", "folder": "/Users/…"}`.
extension AgentAction: Codable {
  private enum CodingKeys: String, CodingKey {
    case action, page, folder
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .action) {
    case "open": self = .open(page: try container.decode(String.self, forKey: .page))
    case "sync": self = .sync
    case "export": self = .export(folder: try container.decode(String.self, forKey: .folder))
    case let action:
      throw DecodingError.dataCorruptedError(
        forKey: .action, in: container, debugDescription: "Unknown action \(action)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .open(let page):
      try container.encode("open", forKey: .action)
      try container.encode(page, forKey: .page)
    case .sync:
      try container.encode("sync", forKey: .action)
    case .export(let folder):
      try container.encode("export", forKey: .action)
      try container.encode(folder, forKey: .folder)
    }
  }
}

/// What the app answered once it performed an action.
public enum AgentActionResult: Equatable, Sendable {
  /// Done, with nothing to say: the page is open.
  case done
  /// Caught up with the server, as of the end of the pull.
  case synced(at: Date)
  /// Still pulling after the app's wait (60 s): it finishes in the background.
  case stillSyncing
  /// The archive, saved at this path.
  case exported(path: String)
}

/// Stored as `{"result": "done"}`, `{"result": "synced", "at": <seconds since 1970>}`,
/// `{"result": "stillSyncing"}` or `{"result": "exported", "path": "/Users/…"}`.
extension AgentActionResult: Codable {
  private enum CodingKeys: String, CodingKey {
    case result, at, path
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .result) {
    case "done": self = .done
    case "synced":
      self = .synced(
        at: Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .at)))
    case "stillSyncing": self = .stillSyncing
    case "exported": self = .exported(path: try container.decode(String.self, forKey: .path))
    case let result:
      throw DecodingError.dataCorruptedError(
        forKey: .result, in: container, debugDescription: "Unknown result \(result)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .done:
      try container.encode("done", forKey: .result)
    case .synced(let date):
      try container.encode("synced", forKey: .result)
      try container.encode(date.timeIntervalSince1970, forKey: .at)
    case .stillSyncing:
      try container.encode("stillSyncing", forKey: .result)
    case .exported(let path):
      try container.encode("exported", forKey: .result)
      try container.encode(path, forKey: .path)
    }
  }
}

/// Why the app didn't perform an action, with the message to print.
public struct AgentActionFailure: Error, Equatable, Sendable, LocalizedError {
  public enum Reason: String, Sendable {
    /// Access was turned off before the app claimed the request.
    case accessOff
    /// The app isn't signed in, or signed out before it was done.
    case signedOut
    /// The app quit (or crashed) after claiming the request, before it was done.
    case appQuit
    /// The action itself failed (a sync's or export's error), or the app couldn't do it.
    case failed
  }

  public var reason: Reason
  public var message: String

  public init(reason: Reason, message: String) {
    self.reason = reason
    self.message = message
  }

  public var errorDescription: String? { message }

  public static let accessOff = Self(
    reason: .accessOff, message: AgentAccessError.off.localizedDescription)
  /// The same message as the app's `HealthAppActionError.signedOut`.
  public static let signedOut = Self(reason: .signedOut, message: "Sign in to lil health first.")
  public static let appQuit = Self(
    reason: .appQuit, message: "lil health quit before it finished.")
  /// A request this version of the app can't read: a newer command's.
  static let unsupported = Self(
    reason: .failed, message: "This version of lil health can't do that. Update lil health.")
}

/// How the app answered a request.
public enum AgentActionOutcome: Equatable, Sendable {
  case ok(AgentActionResult)
  case failed(AgentActionFailure)
}

/// Where a request is, for the command that's waiting on it.
public enum AgentActionState: Equatable, Sendable {
  /// No app has claimed it yet.
  case waiting
  /// A running app claimed it and is performing it.
  case running
  /// The app answered (or quit before it could).
  case finished(AgentActionOutcome)
}

/// A request the app claimed, to perform.
public struct AgentActionRequest: Identifiable, Equatable, Sendable {
  /// 128 random bits, as 32 hex digits.
  public struct ID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    static func random() -> Self {
      var generator = SystemRandomNumberGenerator()
      let words = [generator.next(), generator.next()] as [UInt64]
      return Self(rawValue: words.map { String(format: "%016llx", $0) }.joined())
    }

    public var description: String { rawValue }
  }

  public var id: ID
  public var action: AgentAction
  public var requestedAt: Date

  public init(id: ID, action: AgentAction, requestedAt: Date) {
    self.id = id
    self.action = action
    self.requestedAt = requestedAt
  }
}

/// A process, told apart from a later one given the same ID by when it started: the command that
/// asked, or the app that claimed a request.
public struct AgentProcess: Equatable, Sendable {
  public var pid: Int32
  /// When it started, in microseconds since 1970.
  public var startedAt: Int64

  public init(pid: Int32, startedAt: Int64) {
    self.pid = pid
    self.startedAt = startedAt
  }

  /// The process with this ID, if it's running (and not a zombie waiting for its parent) and
  /// this process may read when it started.
  public init?(pid: Int32) {
    #if os(macOS)
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
        info.pbi_status != UInt32(SZOMB)
      else { return nil }
      self.init(
        pid: pid,
        startedAt: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec))
    #else
      return nil
    #endif
  }

  /// This process.
  public static var current: Self {
    Self(pid: getpid()) ?? Self(pid: getpid(), startedAt: 0)
  }

  /// Whether it's still running: a process with its ID that started when it did. One this
  /// process may not look at (a sandbox can deny it) counts as running, rather than as gone:
  /// only one that's known to have ended is.
  public var isRunning: Bool {
    if let running = Self(pid: pid) { return running == self }
    #if os(macOS)
      // A zombie, which `proc_pidinfo` can't read but `kill` still reaches, has ended.
      var process = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.size
      var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      if sysctl(&name, 4, &process, &size, nil, 0) == 0, size > 0 {
        return process.kp_proc.p_stat != SZOMB
      }
      // Not readable either: gone only if there's no such process (ESRCH).
      return kill(pid, 0) == 0 || errno == EPERM
    #else
      return true
    #endif
  }
}

extension AgentAccessStore {
  /// How long a request waits for an app to claim it. Older ones are deleted, so an app that
  /// wasn't running when they were made doesn't act on them later.
  public static let claimWindow: TimeInterval = 60

  /// How long a finished request's outcome is kept for the command to read.
  public static let outcomeLifetime: TimeInterval = 10 * 60

  /// What `lil-health open`, `sync` and `export` call: throws `AgentAccessError.off` while access
  /// is off, otherwise logs the action (with the same command text as the app's intents) and adds
  /// the request, in one transaction. Then the command signals the app (`AgentActionSignal`) or
  /// launches it, and polls `outcome(id:)`. `requester` is the process that waits for it: a
  /// request whose requester has quit before an app claims it never runs.
  @discardableResult
  public func requestAction(
    _ action: AgentAction, process: String, requester: AgentProcess = .current,
    at date: Date = Date()
  ) throws -> AgentActionRequest.ID {
    guard exists else { throw AgentAccessError.off }
    let id = AgentActionRequest.ID.random()
    let json = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
    try open().write { db in
      guard try Self.isEnabled(db) else { throw AgentAccessError.off }
      try Self.record(command: action.command, process: process, at: date, db)
      try Self.sweepActions(at: date, db)
      try db.execute(
        sql: """
          INSERT INTO "actionRequests"
            ("id", "action", "requestedAt", "requesterPID", "requesterStartedAt")
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          id.rawValue, json, date.timeIntervalSince1970, requester.pid, requester.startedAt,
        ])
    }
    return id
  }

  /// What the app calls when it launches and on each signal: the requests no app has claimed,
  /// at most `claimWindow` old and whose requester still waits, marked claimed by `claimer` in
  /// the same transaction, so two app instances or a relaunch can't run one twice. While access
  /// is off it claims nothing, and fails what's waiting (made just before access was turned off).
  /// Also deletes expired requests, and fails those claimed by an app that has quit.
  public func claimActions(
    by claimer: AgentProcess = .current, at date: Date = Date()
  ) throws -> [AgentActionRequest] {
    guard exists else { return [] }
    return try open().write { db in
      try Self.sweepActions(at: date, db)
      let waiting = try Row.fetchAll(
        db,
        sql: """
          SELECT "id", "action", "requestedAt" FROM "actionRequests"
          WHERE "claimedAt" IS NULL AND "finishedAt" IS NULL
          ORDER BY "requestedAt"
          """)
      guard !waiting.isEmpty else { return [] }
      guard try Self.isEnabled(db) else {
        for row in waiting {
          try Self.finish(id: row["id"], .failed(.accessOff), at: date, db)
        }
        return []
      }
      var claimed: [AgentActionRequest] = []
      for row in waiting {
        let id = AgentActionRequest.ID(rawValue: row["id"])
        guard
          let action = try? JSONDecoder().decode(
            AgentAction.self, from: Data((row["action"] as String).utf8))
        else {
          try Self.finish(id: id.rawValue, .failed(.unsupported), at: date, db)
          continue
        }
        try db.execute(
          sql: """
            UPDATE "actionRequests" SET "claimedAt" = ?, "claimerPID" = ?, "claimerStartedAt" = ?
            WHERE "id" = ?
            """,
          arguments: [date.timeIntervalSince1970, claimer.pid, claimer.startedAt, id.rawValue])
        claimed.append(
          AgentActionRequest(
            id: id, action: action, requestedAt: Date(timeIntervalSince1970: row["requestedAt"])))
      }
      return claimed
    }
  }

  /// Writes how the app answered a request. Only the first answer counts: one written already
  /// (signing out fails what's unfinished) stays.
  public func finish(
    id: AgentActionRequest.ID, outcome: AgentActionOutcome, at date: Date = Date()
  ) throws {
    guard exists else { return }
    try open().write { db in try Self.finish(id: id.rawValue, outcome, at: date, db) }
  }

  /// Where a request is, which the command polls. `nil` if there's no such request: it was
  /// cancelled, it expired before an app claimed it, or its outcome is older than
  /// `outcomeLifetime`. A request claimed by an app that has quit has failed (`appQuit`).
  public func outcome(id: AgentActionRequest.ID, at date: Date = Date()) throws -> AgentActionState?
  {
    guard exists else { return nil }
    return try open().read { db in
      guard
        let row = try Row.fetchOne(
          db, sql: #"SELECT * FROM "actionRequests" WHERE "id" = ?"#, arguments: [id.rawValue])
      else { return nil }
      if let outcome = try Self.outcome(row) { return .finished(outcome) }
      if row["claimedAt"] as Double? != nil {
        return Self.claimer(row)?.isRunning == true ? .running : .finished(.failed(.appQuit))
      }
      let requestedAt: Double = row["requestedAt"]
      return abs(date.timeIntervalSince1970 - requestedAt) <= Self.claimWindow ? .waiting : nil
    }
  }

  /// Withdraws a request no app has claimed, when the command stops waiting for one (it timed
  /// out, or was interrupted). `false` if an app has claimed it already: it runs, and the
  /// outcome is still written.
  @discardableResult
  public func cancel(id: AgentActionRequest.ID) throws -> Bool {
    guard exists else { return false }
    return try open().write { db in
      try db.execute(
        sql: """
          DELETE FROM "actionRequests"
          WHERE "id" = ? AND "claimedAt" IS NULL AND "finishedAt" IS NULL
          """,
        arguments: [id.rawValue])
      return db.changesCount > 0
    }
  }

  // MARK: - In a transaction

  /// Deletes outcomes older than `outcomeLifetime`, requests not claimed within `claimWindow` or
  /// whose requester has quit, and fails requests claimed by an app that has quit.
  static func sweepActions(at date: Date, _ db: Database) throws {
    let now = date.timeIntervalSince1970
    try db.execute(
      sql: #"DELETE FROM "actionRequests" WHERE "finishedAt" < ?"#,
      arguments: [now - outcomeLifetime])
    // Also those dated well ahead of now, as after the clock was set back.
    try db.execute(
      sql: """
        DELETE FROM "actionRequests"
        WHERE "claimedAt" IS NULL AND "finishedAt" IS NULL AND "requestedAt" NOT BETWEEN ? AND ?
        """,
      arguments: [now - claimWindow, now + claimWindow])
    let unfinished = try Row.fetchAll(
      db,
      sql: """
        SELECT "id", "requesterPID", "requesterStartedAt", "claimedAt", "claimerPID",
          "claimerStartedAt"
        FROM "actionRequests" WHERE "finishedAt" IS NULL
        """)
    for row in unfinished {
      let id: String = row["id"]
      if row["claimedAt"] as Double? == nil {
        let requester = AgentProcess(pid: row["requesterPID"], startedAt: row["requesterStartedAt"])
        if !requester.isRunning {
          try db.execute(sql: #"DELETE FROM "actionRequests" WHERE "id" = ?"#, arguments: [id])
        }
      } else if claimer(row)?.isRunning != true {
        try finish(id: id, .failed(.appQuit), at: date, db)
      }
    }
  }

  static func finish(
    id: String, _ outcome: AgentActionOutcome, at date: Date, _ db: Database
  ) throws {
    let result: String?
    let failure: AgentActionFailure?
    switch outcome {
    case .ok(let value):
      result = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
      failure = nil
    case .failed(let value):
      result = nil
      failure = value
    }
    try db.execute(
      sql: """
        UPDATE "actionRequests" SET
          "finishedAt" = ?, "outcome" = ?, "result" = ?, "failureReason" = ?, "error" = ?
        WHERE "id" = ? AND "finishedAt" IS NULL
        """,
      arguments: [
        date.timeIntervalSince1970, failure == nil ? "ok" : "failed", result,
        failure?.reason.rawValue, failure?.message, id,
      ])
  }

  /// When signing out (`reset`): what's unfinished fails as signed out, so a command waiting on
  /// it hears why, and outcomes already written are deleted with the log.
  static func resetActions(at date: Date, _ db: Database) throws {
    try db.execute(sql: #"DELETE FROM "actionRequests" WHERE "finishedAt" IS NOT NULL"#)
    for id in try String.fetchAll(db, sql: #"SELECT "id" FROM "actionRequests""#) {
      try finish(id: id, .failed(.signedOut), at: date, db)
    }
  }

  private static func claimer(_ row: Row) -> AgentProcess? {
    guard let pid = row["claimerPID"] as Int32?, let startedAt = row["claimerStartedAt"] as Int64?
    else { return nil }
    return AgentProcess(pid: pid, startedAt: startedAt)
  }

  private static func outcome(_ row: Row) throws -> AgentActionOutcome? {
    switch row["outcome"] as String? {
    case "ok":
      // Optional, so a row another program wrote without a result throws rather than traps.
      let json: String? = row["result"]
      return .ok(try JSONDecoder().decode(AgentActionResult.self, from: Data((json ?? "").utf8)))
    case "failed":
      let reason = AgentActionFailure.Reason(rawValue: row["failureReason"] ?? "") ?? .failed
      return .failed(AgentActionFailure(reason: reason, message: row["error"] ?? ""))
    default:
      return nil
    }
  }
}

#if os(macOS)
  /// How a command wakes a running app to look for its request (851-2895): the distributed
  /// notification `tech.lil.health.actionRequested`, which carries nothing, since the request is
  /// the row. Without a running app, the command launches it instead, and the app looks when it
  /// launches. No URL scheme: any web page could open one.
  public enum AgentActionSignal {
    public static let name = Notification.Name("tech.lil.health.actionRequested")

    /// Tells a running app there's a request, even while it's in the background. (Tests name
    /// another notification, so they don't wake an app that's running.)
    public static func post(_ name: Notification.Name = name) {
      DistributedNotificationCenter.default().postNotificationName(
        name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Once at once, then each time a command posts, for the app to claim requests. Signals the
    /// app hasn't handled yet are coalesced, since one claim takes every request waiting.
    public static func signals(_ name: Notification.Name = name) -> AsyncStream<Void> {
      let (stream, continuation) = AsyncStream<Void>.makeStream(
        bufferingPolicy: .bufferingNewest(1))
      let observer = Observer(continuation)
      // Listening before the first claim, so a request made in between isn't missed.
      DistributedNotificationCenter.default().addObserver(
        observer, selector: #selector(Observer.received), name: name, object: nil,
        suspensionBehavior: .deliverImmediately)
      continuation.yield()
      continuation.onTermination = { _ in
        DistributedNotificationCenter.default().removeObserver(observer)
      }
      return stream
    }

    private final class Observer: NSObject, Sendable {
      let continuation: AsyncStream<Void>.Continuation

      init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
      }

      @objc func received(_ notification: Notification) {
        continuation.yield()
      }
    }
  }
#endif
