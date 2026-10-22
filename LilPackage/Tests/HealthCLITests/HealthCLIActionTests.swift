import Foundation
import HealthAgentAccess
import HealthCatalog
import Synchronization
import Testing

@testable import HealthCLI

// `lil-health open`, `sync` and `export` (851-2896), with a fake app: a thread that claims the
// command's request from a temporary `AgentAccess.sqlite` and answers it, as the app does.

/// Tuesday, October 20, 2026, 15:00 UTC.
private let syncedAt = Date(timeIntervalSince1970: 1_792_508_400)

/// lil health, as the commands see it: running or not, installed or not, and how it answers.
private final class FakeApp: Sendable {
  /// What it does with a request it's woken or launched for.
  enum Behavior: Sendable {
    /// Claims it, then answers.
    case answer(AgentActionOutcome)
    /// Claims it, and never answers (still working).
    case claimOnly
    /// Claims it, then quits.
    case quit
    /// Never looks.
    case silent
  }

  let store: AgentAccessStore
  let running: Bool
  let installed: Bool
  let behavior: Behavior
  /// What the command did: `signal`, `open` or `activate`.
  let calls = Mutex<[String]>([])
  /// The requests it claimed.
  let claimed = Mutex<[AgentActionRequest]>([])
  let interrupted = Atomic(false)

  init(
    _ store: AgentAccessStore, running: Bool = true, installed: Bool = true,
    behavior: Behavior
  ) {
    self.store = store
    self.running = running
    self.installed = installed
    self.behavior = behavior
  }

  var connection: HealthCLI.AppConnection {
    HealthCLI.AppConnection(
      isRunning: { self.running },
      signal: {
        self.calls.withLock { $0.append("signal") }
        self.respond()
      },
      open: { activate in
        self.calls.withLock { $0.append(activate ? "activate" : "open") }
        guard self.installed else { throw HealthCLI.ActionError.notInstalled }
        // A running app was woken already.
        if !self.running { self.respond() }
      },
      sleep: { _ in Thread.sleep(forTimeInterval: 0.01) },
      isInterrupted: { self.interrupted.load(ordering: .sequentiallyConsistent) })
  }

  /// Claims and answers on a thread of its own, as the app does in its own process.
  private func respond() {
    let behavior = behavior
    guard case .silent = behavior else {
      Thread.detachNewThread { [self] in
        // An app that quits is told apart from this process by when it started.
        let claimer: AgentProcess =
          if case .quit = behavior {
            AgentProcess(pid: getpid(), startedAt: 1)
          } else {
            .current
          }
        let requests = (try? store.claimActions(by: claimer)) ?? []
        claimed.withLock { $0 += requests }
        guard case .answer(let outcome) = behavior else { return }
        for request in requests {
          try? store.finish(id: request.id, outcome: outcome)
        }
      }
      return
    }
  }
}

private struct ActionFolder {
  let directory: URL
  let store: AgentAccessStore

  init(enabled: Bool = true) throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "HealthCLIActionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    store = AgentAccessStore(directory: directory)
    try store.setEnabled(enabled)
    // `export`'s default, which it checks is there.
    try FileManager.default.createDirectory(
      at: URL.downloadsDirectory, withIntermediateDirectories: true)
  }

  func run(
    _ arguments: [String], app: FakeApp,
    timing: HealthCLI.Timing = HealthCLI.Timing(claimWait: .seconds(10))
  ) -> HealthCLI.Outcome {
    HealthCLI.run(
      arguments,
      context: HealthCLI.Context(
        directory: directory, now: { Date() }, process: "zsh", timeZone: "UTC",
        app: app.connection, timing: timing))
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private func json(_ text: String) -> NSDictionary? {
  try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
}

extension String {
  fileprivate func trimmingSuffix(_ suffix: String) -> String {
    count > 1 && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
  }
}

@Suite
struct HealthCLIActionTests {
  // MARK: - open

  @Test
  func opensAPageInTheRunningAppAndBringsItForward() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, behavior: .answer(.ok(.done)))
    let outcome = folder.run(["open", "heart", "rate"], app: app)
    #expect(outcome == HealthCLI.Outcome(output: "Opened Heart Rate in lil health.\n"))
    #expect(app.calls.withLock { $0 } == ["signal", "activate"])
    #expect(
      app.claimed.withLock { $0.map(\.action) }
        == [.open(page: "type:HKQuantityTypeIdentifierHeartRate")])
    #expect(try folder.store.entries().map(\.command) == ["open Heart Rate"])
    #expect(try folder.store.entries().map(\.process) == ["zsh"])
  }

  @Test
  func opensAPageByLaunchingTheApp() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, running: false, behavior: .answer(.ok(.done)))
    let outcome = folder.run(["open", "Health Details", "--json"], app: app)
    #expect(outcome.status == 0, "\(outcome.error)")
    #expect(
      json(outcome.output)
        == ["outcome": "ok", "result": ["page": "health-details", "name": "Health Details"]])
    #expect(app.calls.withLock { $0 } == ["activate"])
  }

  @Test
  func waitsForTheAppToOpenThePage() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    // Launched signed out: the app claims the request, then fails it.
    let signedOut = FakeApp(folder.store, running: false, behavior: .answer(.failed(.signedOut)))
    #expect(
      folder.run(["open", "Steps"], app: signedOut)
        == HealthCLI.Outcome(error: "lil-health: Sign in to lil health first.\n", status: 69))
    // Claimed, but slow to answer: the app has it, and opens it without the command.
    let slow = FakeApp(folder.store, behavior: .claimOnly)
    #expect(
      folder.run(
        ["open", "Steps"], app: slow, timing: HealthCLI.Timing(openWait: .milliseconds(200)))
        == HealthCLI.Outcome(output: "Opened Steps in lil health.\n"))
  }

  @Test
  func refusesAnUnknownPageWithoutAsking() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, behavior: .answer(.ok(.done)))
    for page in ["Nope", "Blood Type"] {
      let outcome = folder.run(["open", page], app: app)
      #expect(outcome.status == 65 && outcome.error.contains("has no page named \(page)."))
    }
    #expect(app.calls.withLock { $0 }.isEmpty)
    #expect(try folder.store.entries().isEmpty)
  }

  @Test
  func namesPagesAsTheSidebarDoes() {
    #expect(OpenCommand.pageID(named: "summary") == "summary")
    #expect(OpenCommand.pageID(named: " Health details ") == "health-details")
    // The category before the type of the same name.
    #expect(OpenCommand.pageID(named: "Sleep") == "category:sleep")
    #expect(OpenCommand.pageID(named: "body measurements") == "category:bodyMeasurements")
    #expect(OpenCommand.pageID(named: "Steps") == "type:HKQuantityTypeIdentifierStepCount")
    #expect(OpenCommand.pageID(named: "stepcount") == "type:HKQuantityTypeIdentifierStepCount")
    #expect(
      OpenCommand.pageID(named: "HKQuantityTypeIdentifierHeartRate")
        == "type:HKQuantityTypeIdentifierHeartRate")
    // Characteristics have no page: Health Details shows them.
    #expect(OpenCommand.pageID(named: "Blood Type") == nil)
    // Every category and type with a page, as the app's `HealthPage.id` has them.
    for category in HealthCategory.allCases {
      #expect(OpenCommand.pageID(named: category.name) == "category:\(category.rawValue)")
    }
    for type in HealthCatalog.all {
      #expect(
        OpenCommand.pageID(named: type.id) == (type.category == nil ? nil : "type:\(type.id)"))
    }
  }

  // MARK: - sync

  @Test
  func syncsAndSaysWhen() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, running: false, behavior: .answer(.ok(.synced(at: syncedAt))))
    let outcome = folder.run(["sync"], app: app)
    #expect(
      outcome == HealthCLI.Outcome(output: "lil health is up to date, as of 2026-10-20 15:00.\n"))
    // In the background.
    #expect(app.calls.withLock { $0 } == ["open"])
    #expect(try folder.store.entries().map(\.command) == ["sync"])

    let json = json(folder.run(["sync", "--json"], app: app).output)
    #expect(
      json == [
        "outcome": "ok", "result": ["status": "upToDate", "syncedAt": "2026-10-20T15:00:00+00:00"],
      ])
  }

  @Test
  func saysWhenSyncIsStillGoing() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let still = "Still syncing. lil health will finish in the background.\n"
    let answering = FakeApp(folder.store, behavior: .answer(.ok(.stillSyncing)))
    #expect(folder.run(["sync"], app: answering) == HealthCLI.Outcome(output: still))
    #expect(
      json(folder.run(["sync", "--json"], app: answering).output)
        == ["outcome": "ok", "result": ["status": "stillSyncing"]])

    // An app that claimed it and stopped answering: the command stops waiting after a while.
    let quiet = FakeApp(folder.store, behavior: .claimOnly)
    let outcome = folder.run(
      ["sync"], app: quiet, timing: HealthCLI.Timing(syncWait: .milliseconds(200)))
    #expect(outcome == HealthCLI.Outcome(output: still))
  }

  @Test
  func syncStatusIsStillAQuery() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, behavior: .answer(.ok(.done)))
    // No database here: it's read, not asked of the app.
    let outcome = folder.run(["sync", "status"], app: app)
    #expect(outcome.status == 69)
    #expect(app.calls.withLock { $0 }.isEmpty)
    #expect(try folder.store.entries().map(\.command) == ["sync status"])
  }

  // MARK: - export

  @Test
  func exportsToDownloadsAndPrintsThePath() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let path = "/Users/someone/Downloads/lil health export 2026-10-20.tar"
    let app = FakeApp(folder.store, behavior: .answer(.ok(.exported(path: path))))
    #expect(folder.run(["export"], app: app) == HealthCLI.Outcome(output: path + "\n"))
    #expect(
      app.claimed.withLock { $0.map(\.action) }
        == [.export(folder: URL.downloadsDirectory.path(percentEncoded: false))])
    #expect(
      json(folder.run(["export", "--to", folder.directory.path, "--json"], app: app).output)
        == ["outcome": "ok", "result": ["path": path]])
    let directory = folder.directory.standardizedFileURL.path(percentEncoded: false)
      .trimmingSuffix("/")
    #expect(app.claimed.withLock { $0.last?.action } == .export(folder: directory))
    #expect(
      try folder.store.entries().map(\.command)
        == ["export \((directory as NSString).abbreviatingWithTildeInPath)", "export ~/Downloads"])

    // A folder that isn't there: retrying won't help, so it's a data error, and nothing's asked.
    let missing = folder.run(["export", "--to", "/nonexistent-2896"], app: app)
    #expect(
      missing
        == HealthCLI.Outcome(
          error: "lil-health: There's no folder at /nonexistent-2896.\n", status: 65))
    #expect(try folder.store.entries().count == 2)
  }

  @Test
  func sendsTheAppAnAbsoluteFolder() {
    let home = NSHomeDirectory()
    #expect(ExportCommand.absolutePath("exports", currentDirectory: "/tmp/x") == "/tmp/x/exports")
    #expect(ExportCommand.absolutePath("../y/", currentDirectory: "/tmp/x") == "/tmp/y")
    #expect(ExportCommand.absolutePath(".", currentDirectory: "/tmp/x") == "/tmp/x")
    #expect(ExportCommand.absolutePath("/", currentDirectory: "/tmp/x") == "/")
    #expect(
      ExportCommand.absolutePath("~/Desktop", currentDirectory: "/tmp/x") == home + "/Desktop")
    #expect(
      ExportCommand.absolutePath(nil, currentDirectory: "/tmp/x")
        == URL.downloadsDirectory.path(percentEncoded: false))
  }

  // MARK: - Exit statuses

  @Test
  func refusesWhileAccessIsOff() throws {
    let folder = try ActionFolder(enabled: false)
    defer { folder.remove() }
    let app = FakeApp(folder.store, behavior: .answer(.ok(.done)))
    for command in [["open", "Steps"], ["sync"], ["export"]] {
      let outcome = folder.run(command, app: app)
      #expect(outcome.status == 77 && outcome.error.contains("Allow command-line and agent access"))
    }
    #expect(app.calls.withLock { $0 }.isEmpty)
    #expect(try folder.store.entries().isEmpty)
  }

  @Test
  func failsWhenTheAppDoesNotAnswer() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, behavior: .silent)
    let outcome = folder.run(
      ["sync"], app: app, timing: HealthCLI.Timing(claimWait: .milliseconds(200)))
    #expect(
      outcome
        == HealthCLI.Outcome(
          error: "lil-health: lil health didn't answer. Is it installed and signed in?\n",
          status: 69))
    // Withdrawn: an app launched later doesn't act on it.
    #expect(try folder.store.claimActions().isEmpty)
  }

  @Test
  func failsWhenTheAppIsNotInstalled() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, running: false, installed: false, behavior: .silent)
    let outcome = folder.run(["export"], app: app)
    #expect(
      outcome == HealthCLI.Outcome(error: "lil-health: lil health isn't installed.\n", status: 69))
    #expect(try folder.store.claimActions().isEmpty)
  }

  @Test(
    arguments: [
      (AgentActionFailure(reason: .failed, message: "Couldn't sync: this Mac is offline."), 75),
      (AgentActionFailure.signedOut, 69),
      (AgentActionFailure.accessOff, 77),
    ] as [(AgentActionFailure, Int32)])
  func failsAsTheAppSays(failure: AgentActionFailure, status: Int32) throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, behavior: .answer(.failed(failure)))
    let outcome = folder.run(["sync", "--json"], app: app)
    #expect(outcome == HealthCLI.Outcome(error: "lil-health: \(failure.message)\n", status: status))
  }

  @Test
  func failsWhenTheAppQuitsBeforeItIsDone() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, behavior: .quit)
    let outcome = folder.run(["export"], app: app)
    #expect(
      outcome
        == HealthCLI.Outcome(error: "lil-health: lil health quit before it finished.\n", status: 69)
    )
  }

  @Test
  func ctrlCBeforeTheAppClaimsItWithdrawsTheRequest() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, behavior: .silent)
    app.interrupted.store(true, ordering: .sequentiallyConsistent)
    let outcome = folder.run(["export"], app: app)
    #expect(
      outcome
        == HealthCLI.Outcome(error: "lil-health: Stopped. lil health won't do it.\n", status: 130))
    #expect(try folder.store.claimActions().isEmpty)
  }

  @Test
  func ctrlCAfterTheAppClaimsAnExportLeavesItRunning() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, behavior: .claimOnly)
    // Interrupted once the app has claimed it.
    Thread.detachNewThread {
      while app.claimed.withLock({ $0.isEmpty }) { Thread.sleep(forTimeInterval: 0.01) }
      app.interrupted.store(true, ordering: .sequentiallyConsistent)
    }
    let outcome = folder.run(["export", "--to", "/tmp"], app: app)
    #expect(
      outcome
        == HealthCLI.Outcome(
          error:
            "lil-health: Stopped waiting. lil health is still exporting, and will save it to /tmp.\n",
          status: 130))
  }

  @Test
  func describesTheActionsInHelp() throws {
    let folder = try ActionFolder()
    defer { folder.remove() }
    let app = FakeApp(folder.store, behavior: .silent)
    let help = folder.run(["--help"], app: app).output
    for command in ["open", "sync", "export"] {
      #expect(help.contains("\n  \(command) "), "\(command)")
      let own = folder.run([command, "--help"], app: app)
      #expect(own.status == 0 && own.output.contains("USAGE: lil-health \(command)"))
    }
    #expect(folder.run(["open"], app: app).status == 64)
    #expect(app.calls.withLock { $0 }.isEmpty)
  }
}
