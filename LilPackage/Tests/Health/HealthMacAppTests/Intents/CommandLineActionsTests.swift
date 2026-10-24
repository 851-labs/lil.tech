import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthAgentAccess
import HealthCatalog
import HealthDatabase
import LilAuth
import LilSync
import LilTestSupport
import SQLiteData
import Testing

@testable import HealthMacApp

private let steps = HealthPage.dataType(
  HealthCatalog.type(id: "HKQuantityTypeIdentifierStepCount")!)!

// The command line's requests, as the app performs them (851-2895). Synthetic data, and
// temporary directories for `AgentAccess.sqlite`.
// Signing in follows the account's cards (851-3204), in a database of their own.
@Suite(.dependencies { $0.defaultDatabase = try! HealthDatabase.make() })
@MainActor
struct CommandLineActionsTests {
  private let directory = URL.temporaryDirectory.appending(
    path: "AgentAccess-\(UUID().uuidString)", directoryHint: .isDirectory)
  private var accessStore: AgentAccessStore { AgentAccessStore(directory: directory) }

  private func finished(_ id: AgentActionRequest.ID) async throws -> AgentActionOutcome? {
    let accessStore = accessStore
    try await eventually {
      if case .finished = try accessStore.outcome(id: id) { true } else { false }
    }
    guard case .finished(let outcome) = try accessStore.outcome(id: id) else { return nil }
    return outcome
  }

  /// What a command does: asks, as another process would with its own connection.
  private func ask(_ action: AgentAction) throws -> AgentActionRequest.ID {
    try AgentAccessStore(directory: directory).requestAction(action, process: "zsh")
  }

  @Test(.timeLimit(.minutes(1)))
  func runsWhatWasAskedBeforeLaunchAndWhatsSignaledAfter() async throws {
    try accessStore.setEnabled(true)
    // Asked before the app launched: the command launched it.
    let beforeLaunch = try ask(.open(page: steps.id))

    let (signals, signal) = AsyncStream<Void>.makeStream()
    let (updates, session) = AsyncStream<Bool>.makeStream()
    let broughtForward = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess = .live(accessStore)
      $0.agentAccess.reset = {}
      $0.agentAccess.actionsRequested = { signals }
      $0.agentAccess.bringAppForward = { broughtForward.withValue { $0 += 1 } }
      $0.auth.signedInUpdates = { updates }
      // The action waits for the stored session to be checked, as after a launch.
      $0.healthAppActions = HealthAppActions(
        channel: HealthAppActionChannel(signInWait: .seconds(30)))
      $0.sync = .constant(.idle)
      // For the sync footer's wait, which the first pull never ends.
      $0.continuousClock = ManualClock()
    }
    store.exhaustivity = .off

    let task = await store.send(.task)
    // At launch, before the session is known.
    signal.yield()
    await store.receive(\.commandLineActionsClaimed)
    session.yield(true)
    #expect(try await finished(beforeLaunch) == .ok(.done))
    await store.receive(\.pageOpened) {
      $0.selection = .category(.activity)
      $0.metricPath = ["HKQuantityTypeIdentifierStepCount"]
    }

    // The app is running: a command asks, then signals.
    let whileRunning = try ask(.open(page: HealthPage.category(.heart).id))
    signal.yield()
    #expect(try await finished(whileRunning) == .ok(.done))
    await store.receive(\.pageOpened) {
      $0.selection = .category(.heart)
      $0.metricPath = []
    }
    // Open brings the app forward, as the intent does.
    #expect(broughtForward.value == 2)
    // Claimed once: signaled again, nothing more runs.
    signal.yield()
    await task.cancel()
    await store.finish()
  }

  @Test
  func writesEachResultAndFailure() async throws {
    try accessStore.setEnabled(true)
    let folder = URL.temporaryDirectory.appending(path: "lil-export", directoryHint: .isDirectory)
    let open = try ask(.open(page: steps.id))
    let sync = try ask(.sync)
    let export = try ask(.export(folder: folder.path(percentEncoded: false)))
    let unknownPage = try ask(.open(page: "type:HKQuantityTypeIdentifierTeleportCount"))
    // A relative path would be the app's: the command sends absolute ones.
    let relativeFolder = try ask(.export(folder: "Downloads"))
    let asked = LockIsolated<[HealthAppAction]>([])
    let broughtForward = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess = .live(accessStore)
      $0.agentAccess.bringAppForward = { broughtForward.withValue { $0 += 1 } }
      $0.healthAppActions.perform = { action, _ in
        asked.withValue { $0.append(action) }
        switch action {
        case .open: return .done
        case .sync: throw HealthAppActionError.offline
        case .export(let folder): return .exported(folder.appending(path: "a.tar"))
        }
      }
    }
    let claimed = try accessStore.claimActions()
    #expect(claimed.map(\.id) == [open, sync, export, unknownPage, relativeFolder])
    await store.send(.commandLineActionsClaimed(claimed))
    await store.finish()

    #expect(
      Set(asked.value.map(\.command)) == [
        "open Steps", "sync", "export \(HealthAppAction.displayPath(folder))",
      ])
    #expect(try await finished(open) == .ok(.done))
    #expect(
      try await finished(sync)
        == .failed(
          AgentActionFailure(reason: .failed, message: "Couldn't sync: this Mac is offline.")))
    #expect(
      try await finished(export)
        == .ok(.exported(path: folder.appending(path: "a.tar").path(percentEncoded: false))))
    // A page this version doesn't have isn't asked for.
    #expect(
      try await finished(unknownPage)
        == .failed(.unknownPage("type:HKQuantityTypeIdentifierTeleportCount")))
    #expect(
      try await finished(relativeFolder)
        == .failed(AgentActionFailure(reason: .failed, message: "There's no folder at Downloads.")))
    // Only for the page that opened.
    #expect(broughtForward.value == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func failsWithSignInFirstWhenSignedOut() async throws {
    try accessStore.setEnabled(true)
    let id = try ask(.sync)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess = .live(accessStore)
      // No store serves actions, and the wait after launch is over.
      $0.healthAppActions = HealthAppActions(channel: HealthAppActionChannel(signInWait: .zero))
    }
    await store.send(.commandLineActionsClaimed(try accessStore.claimActions()))
    await store.finish()
    #expect(try await finished(id) == .failed(.signedOut))
    #expect(
      AgentActionFailure.signedOut.message == HealthAppActionError.signedOut.localizedDescription)
  }

  @Test(.timeLimit(.minutes(1)))
  func accessTurnedOffBeforeTheClaimRunsNothing() async throws {
    try accessStore.setEnabled(true)
    let id = try ask(.export(folder: "/tmp"))
    try accessStore.setEnabled(false)

    let (signals, signal) = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess = .live(accessStore)
      $0.agentAccess.actionsRequested = { signals }
      $0.auth.signedInUpdates = { AsyncStream { _ in } }
      // Asking the app would fail the test (`testValue`).
    }
    let task = await store.send(.task)
    signal.yield()
    #expect(try await finished(id) == .failed(.accessOff))
    await task.cancel()
    await store.finish()
  }

  // MARK: - Agreeing with the intents

  /// The log shows the same command whether an intent or the command line asked.
  @Test
  func logsTheSameCommandsAsTheIntents() throws {
    for page in HealthPage.all {
      let action = AgentAction.open(page: page.id)
      #expect(action.command == HealthAppAction.open(page).command)
      #expect(try HealthAppAction(action) == .open(page))
    }
    for folder in [URL.downloadsDirectory, URL(filePath: "/tmp/lil export")] {
      let action = AgentAction.export(folder: folder.path(percentEncoded: false))
      #expect(action.command == HealthAppAction.export(to: folder).command)
    }
    // With or without the trailing slash a folder's URL has.
    #expect(
      AgentAction.export(folder: "/tmp/lil export").command
        == HealthAppAction.export(to: URL(filePath: "/tmp/lil export/")).command)
    #expect(AgentAction.sync.command == HealthAppAction.sync.command)
  }
}
