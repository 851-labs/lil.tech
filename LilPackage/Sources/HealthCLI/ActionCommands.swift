import ArgumentParser
import Foundation
import HealthAgentAccess
import HealthCatalog
import HealthTools

// `lil-health open`, `sync` and `export` (851-2896): rather than reading the database, they ask
// lil health for Mac to act, through `AgentAccess.sqlite` (851-2895), and wait for it to answer.

/// A command that asks the app to act.
protocol ActionCommand: ParsableCommand {
  var output: OutputOptions { get }
  /// What to ask for. Throws for an unknown page.
  func action() throws -> AgentAction
}

private let waitingDiscussion = """
  lil health does it, as its Shortcuts actions do, while you allow command-line and agent access \
  in lil health › Settings… › Agents, and logs it there. It's launched if it isn't running, and \
  has 15 seconds to answer.
  """

struct OpenCommand: ActionCommand {
  static let configuration = CommandConfiguration(
    commandName: "open",
    abstract: "Opens a page in lil health: Summary, Health Details, a category or a data type.",
    discussion: """
      Pages are named as lil health's sidebar names them: Summary, Health Details, a category \
      (Activity, Heart…), or a data type, also by its HealthKit identifier (Steps, \
      "Heart Rate", HKQuantityTypeIdentifierStepCount). A type opens in its category.

      \(waitingDiscussion)
      """)

  @Argument(help: "The page, in any case, e.g. Steps or Health Details.") var page: [String]
  @OptionGroup var output: OutputOptions

  func validate() throws {
    if page.isEmpty { throw ValidationError("Missing expected argument '<page> ...'") }
  }

  func action() throws -> AgentAction {
    let name = page.joined(separator: " ")
    guard let id = Self.pageID(named: name) else {
      throw HealthCLI.ActionError(
        """
        lil health has no page named \(name). Name Summary, Health Details, a category (Activity, \
        Heart…) or a data type (Steps, "Heart Rate"), as lil health's sidebar does.
        """, status: HealthCLI.Status.dataError)
    }
    return .open(page: id)
  }

  /// A page's ID (`HealthPage.id` in the app), from the name lil health shows: Summary, Health
  /// Details, a category, or a data type by the names the queries take
  /// (`HealthCatalog.type(named:)`), as the Open intent finds them. Categories come before types,
  /// so Sleep is the category. Characteristics have no page.
  static func pageID(named name: String) -> String? {
    let name = name.trimmingCharacters(in: .whitespaces)
    func matches(_ other: String) -> Bool { other.caseInsensitiveCompare(name) == .orderedSame }
    if matches("Summary") { return "summary" }
    if matches("Health Details") { return "health-details" }
    if let category = HealthCategory.allCases.first(where: { matches($0.name) }) {
      return "category:\(category.rawValue)"
    }
    if let type = HealthCatalog.type(named: name), type.category != nil {
      return "type:\(type.id)"
    }
    return nil
  }
}

/// `lil-health sync` pulls the account's changes now; `lil-health sync status` (a query) says how
/// fresh the data is.
struct SyncCommand: ActionCommand {
  static let configuration = CommandConfiguration(
    commandName: "sync",
    abstract: "Syncs lil health now, and waits up to a minute for it to finish.",
    discussion: """
      lil health pulls your account's latest data from lil's server, which your iPhone uploads \
      to. Run it before reading, to read the latest. If it's still syncing after a minute, it \
      says so and finishes in the background.

      \(waitingDiscussion)
      """,
    subcommands: [SyncStatusCommand.self])

  @OptionGroup var output: OutputOptions

  func action() throws -> AgentAction { .sync }
}

struct ExportCommand: ActionCommand {
  static let configuration = CommandConfiguration(
    commandName: "export",
    abstract: "Exports your lil health data into a folder, and prints the archive's path.",
    discussion: """
      lil health exports your account's data, as Settings… › Account does, and saves the archive \
      into the folder. It waits until it's saved, which can take a few minutes. Ctrl-C stops \
      waiting, but lil health goes on and still saves it there.

      \(waitingDiscussion)
      """)

  @Option(
    name: .customLong("to"),
    help: ArgumentHelp(
      "The folder to save the archive in. Defaults to Downloads.", valueName: "folder"))
  var folder: String?
  @OptionGroup var output: OutputOptions

  func action() throws -> AgentAction {
    .export(folder: Self.absolutePath(folder))
  }

  /// The folder as an absolute path, which the app needs: relative to the current directory, with
  /// `~` expanded (an agent may pass it unexpanded). Downloads without one.
  static func absolutePath(
    _ folder: String?,
    currentDirectory: String = FileManager.default.currentDirectoryPath
  ) -> String {
    guard let folder, !folder.isEmpty else {
      return URL.downloadsDirectory.path(percentEncoded: false)
    }
    let expanded = (folder as NSString).expandingTildeInPath
    let url =
      expanded.hasPrefix("/")
      ? URL(filePath: expanded, directoryHint: .isDirectory)
      : URL(
        filePath: expanded, directoryHint: .isDirectory,
        relativeTo: URL(filePath: currentDirectory, directoryHint: .isDirectory))
    var path = url.standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}

extension HealthCLI {
  /// An action command's failure, with its exit status.
  struct ActionError: LocalizedError, Equatable {
    var message: String
    var status: Int32

    init(_ message: String, status: Int32) {
      self.message = message
      self.status = status
    }

    var errorDescription: String? { message }

    static let notAnswered = Self(
      "lil health didn't answer. Is it installed and signed in?", status: Status.unavailable)
  }

  /// Asks the app for the command's action, then waits for its answer: logged and checked as
  /// `AgentAccessStore.requestAction` does, then the app is woken (or launched) and has
  /// `Timing.claimWait` to claim the request, then as long as the action takes (`open`: the
  /// claim; `sync`: `Timing.syncWait`; `export`: until the archive is saved, or Ctrl-C).
  static func perform(_ command: any ActionCommand, context: Context) throws -> String {
    let action = try command.action()
    let app = context.app
    let store = AgentAccessStore(directory: context.directory)
    let id = try store.requestAction(action, process: context.process)
    app.catchInterrupts()

    let isOpen = if case .open = action { true } else { false }
    if app.isRunning() {
      app.signal()
      // The app brings itself forward, but macOS may keep the terminal in front.
      if isOpen { try? app.open(true) }
    } else {
      do {
        try app.open(isOpen)
      } catch {
        _ = try? store.cancel(id: id)
        throw error
      }
    }

    // Until the app claims it.
    let clock = ContinuousClock()
    let claimDeadline = clock.now + context.timing.claimWait
    var state = try store.outcome(id: id)
    while state == .waiting {
      if app.isInterrupted() || clock.now >= claimDeadline {
        // Withdrawn, unless the app claimed it meanwhile: then it runs, and the command waits.
        if try store.cancel(id: id) {
          throw app.isInterrupted() ? ActionError.interrupted(action) : ActionError.notAnswered
        }
      } else {
        app.sleep(context.timing.pollInterval)
      }
      state = try store.outcome(id: id)
    }

    // Until it's done.
    let doneDeadline = clock.now + context.timing.syncWait
    while state == .running {
      if isOpen { return output(.done, action: action, command: command, context: context) }
      if app.isInterrupted() { throw ActionError.interrupted(action, claimed: true) }
      if case .sync = action, clock.now >= doneDeadline {
        return output(.stillSyncing, action: action, command: command, context: context)
      }
      app.sleep(context.timing.pollInterval)
      state = try store.outcome(id: id)
    }

    switch state {
    case .finished(.ok(let result)):
      return output(result, action: action, command: command, context: context)
    case .finished(.failed(let failure)):
      throw ActionError(failure)
    case .waiting, .running, nil:
      // Gone: it expired, or a newer lil health deleted it. Only an app's answer counts.
      throw ActionError.notAnswered
    }
  }

  /// The answer, as text or `--json`'s `{"outcome": "ok", "result": …}`.
  private static func output(
    _ result: AgentActionResult, action: AgentAction, command: any ActionCommand,
    context: Context
  ) -> String {
    let json: [String: String]
    let text: String
    switch result {
    case .done:
      if case .open(let page) = action {
        let name = action.command.dropFirst("open ".count)
        json = ["page": page, "name": String(name)]
        text = "Opened \(name) in lil health."
      } else {
        json = [:]
        text = "Done."
      }
    case .synced(let date):
      let time =
        (try? ToolTime(timeZone: context.timeZone).localTime(date))
        ?? ISO8601DateFormatter().string(from: date)
      json = ["status": "upToDate", "syncedAt": time]
      text =
        "lil health is up to date, as of \(time.prefix(16).replacingOccurrences(of: "T", with: " "))."
    case .stillSyncing:
      json = ["status": "stillSyncing"]
      text = "Still syncing. lil health will finish in the background."
    case .exported(let path):
      json = ["path": path]
      text = path
    }
    guard command.output.json else { return text + "\n" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(ActionOutput(result: json))) ?? Data()
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  private struct ActionOutput: Encodable {
    var outcome = "ok"
    var result: [String: String]
  }
}

extension HealthCLI.ActionError {
  /// The app's failure: 77 for access off, 69 for signed out or an app that quit, 75 for the
  /// action's own failure (a sync's or export's error).
  init(_ failure: AgentActionFailure) {
    let status =
      switch failure.reason {
      case .accessOff: HealthCLI.Status.noPermission
      case .signedOut, .appQuit: HealthCLI.Status.unavailable
      case .failed: HealthCLI.Status.tempFail
      }
    self.init(failure.message, status: status)
  }

  /// Ctrl-C: before the claim the request is withdrawn; after it, the app goes on.
  static func interrupted(_ action: AgentAction, claimed: Bool = false) -> Self {
    guard claimed else {
      return Self("Stopped. lil health won't do it.", status: HealthCLI.Status.interrupted)
    }
    let message =
      switch action {
      case .export(let folder):
        "Stopped waiting. lil health is still exporting, and will save it to "
          + "\((folder as NSString).abbreviatingWithTildeInPath)."
      case .sync: "Stopped waiting. lil health will finish syncing in the background."
      case .open: "Stopped waiting."
      }
    return Self(message, status: HealthCLI.Status.interrupted)
  }
}
