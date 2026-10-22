import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthAgentAccess
import LilAuth
import LilSync
import LilTestSupport
import Testing

@testable import HealthMacApp

private let lastSynced = Date(timeIntervalSince1970: 1_792_000_000)
private let synced = Date(timeIntervalSince1970: 1_792_003_600)

// Sync lil health (851-2893). Synthetic data only, and temporary directories for the access
// setting.
@Suite(.dependencies)
@MainActor
struct SyncHealthDataIntentTests {
  private let directory = URL.temporaryDirectory.appending(
    path: "AgentAccess-\(UUID().uuidString)", directoryHint: .isDirectory)
  private var accessStore: AgentAccessStore { AgentAccessStore(directory: directory) }

  // MARK: - AppFeature

  @Test(.timeLimit(.minutes(1)))
  func pullsAndAnswersOnceCaughtUp() async throws {
    let sync = FakeSync(.upToDate(at: lastSynced))
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.sync = sync.client
      $0.continuousClock = ManualClock()
    }
    let (request, answer) = makeRequest(.sync)
    await store.send(.appActionRequested(request))
    await store.receive(\.syncRestarted)
    try await eventually { sync.events.value == ["run"] }
    sync.set(.syncing(cursor: 10, head: 20))
    sync.set(.upToDate(at: synced))
    #expect(try await answer() == .synced(at: synced))
    await store.finish()
  }

  @Test(.timeLimit(.minutes(1)))
  func failsWithTheSyncsErrorEvenTheSameAsBefore() async throws {
    let sync = FakeSync(.failed("unexpectedStatus(500)"))
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.sync = sync.client
      $0.continuousClock = ManualClock()
    }
    // The failure from before the pull isn't the answer: the pull's own is.
    let (request, answer) = makeRequest(.sync)
    await store.send(.appActionRequested(request))
    await store.receive(\.syncRestarted)
    sync.set(.failed("unexpectedStatus(500)"))
    await #expect(throws: HealthAppActionError.syncFailed("unexpectedStatus(500)")) {
      try await answer()
    }
    #expect(
      HealthAppActionError.syncFailed("unexpectedStatus(500)").localizedDescription
        == "Couldn't sync: unexpectedStatus(500)")

    let (offlineRequest, offlineAnswer) = makeRequest(.sync)
    await store.send(.appActionRequested(offlineRequest))
    await store.receive(\.syncRestarted)
    sync.set(.offline)
    await #expect(throws: HealthAppActionError.offline) { try await offlineAnswer() }
    try await eventually { sync.events.value == ["run", "run"] }
    await store.finish()
  }

  @Test(.timeLimit(.minutes(1)))
  func stillSyncingAfterAMinuteIsntAnError() async throws {
    let sync = FakeSync(.upToDate(at: lastSynced))
    let clock = ManualClock()
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.sync = sync.client
      $0.continuousClock = clock
    }
    let (request, answer) = makeRequest(.sync)
    await store.send(.appActionRequested(request))
    await store.receive(\.syncRestarted)
    sync.set(.bootstrapping(downloadedParts: 1, totalParts: 80))
    try await clock.waitUntilAsleep(endingIn: .seconds(60))
    clock.advance(by: .seconds(59))
    sync.set(.bootstrapping(downloadedParts: 40, totalParts: 80))
    clock.advance(by: .seconds(1))
    #expect(try await answer() == .stillSyncing)
    #expect(
      SyncHealthDataIntent.message(for: .stillSyncing)
        == "Still syncing. lil health will finish in the background.")
    #expect(SyncHealthDataIntent.message(for: .synced(at: synced)) == "lil health is up to date.")
    #expect(SyncHealthDataIntent.message(for: .done) == "Done.")
    await store.finish()
  }

  @Test(.timeLimit(.minutes(1)))
  func waitsForAPullAlreadyRunning() async throws {
    // A bootstrap that runs until cancelled.
    let sync = FakeSync(.bootstrapping(downloadedParts: 3, totalParts: 80), hangingRuns: 1)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.sync = sync.client
      $0.continuousClock = ManualClock()
    }
    let running = await store.send(.retrySyncButtonTapped)
    try await eventually { sync.events.value == ["run"] }

    // Not restarted, which would throw away the bootstrap's progress: its end is the answer.
    let (request, answer) = makeRequest(.sync)
    await store.send(.appActionRequested(request))
    try await eventually { sync.observerCount == 1 }
    sync.set(.bootstrapping(downloadedParts: 80, totalParts: 80))
    sync.set(.upToDate(at: synced))
    #expect(try await answer() == .synced(at: synced))
    #expect(sync.events.value == ["run"])
    await running.cancel()
    await store.finish()
  }

  @Test(.timeLimit(.minutes(1)))
  func restartsAPullBackingOffAfterAFailure() async throws {
    // The first pull failed, and backs off until cancelled.
    let sync = FakeSync(.offline, hangingRuns: 1)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.sync = sync.client
      $0.continuousClock = ManualClock()
    }
    await store.send(.retrySyncButtonTapped)
    try await eventually { sync.events.value == ["run"] }

    let (request, answer) = makeRequest(.sync)
    await store.send(.appActionRequested(request))
    await store.receive(\.syncRestarted)
    // As Try Again: the backoff is cut short, and a new pull starts at once.
    try await eventually { sync.events.value.sorted() == ["run", "run", "run ended"] }
    sync.set(.upToDate(at: synced))
    #expect(try await answer() == .synced(at: synced))
    await store.finish()
  }

  @Test(.timeLimit(.minutes(1)))
  func signingOutWhileWaitingFailsTheSync() async throws {
    let actions = HealthAppActions(channel: HealthAppActionChannel(signInWait: .zero))
    let (updates, session) = AsyncStream<Bool>.makeStream()
    let sync = FakeSync(.upToDate(at: lastSynced))
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess.reset = {}
      $0.auth.signedInUpdates = { updates }
      $0.healthAppActions = actions
      $0.sync = sync.client
      $0.continuousClock = ManualClock()
    }
    store.exhaustivity = .off

    let task = await store.send(.task)
    session.yield(true)
    await store.receive(\.signedInChanged)

    let syncing = Task { try await actions.perform(.sync, { _ in }) }
    await store.receive(\.appActionRequested)
    await store.receive(\.syncRestarted)
    session.yield(false)
    await store.receive(\.signedInChanged)
    await #expect(throws: HealthAppActionError.signedOut) { try await syncing.value }
    await task.cancel()
    await store.finish()
  }

  // MARK: - The intent's perform

  @Test
  func refusesAndLogsNothingWhileAccessIsOff() async throws {
    let asked = LockIsolated<[HealthAppAction]>([])
    await withDependencies {
      $0.agentAccess = .live(accessStore)
      $0.healthAppActions.perform = { action, _ in
        asked.withValue { $0.append(action) }
        return .synced(at: synced)
      }
    } operation: {
      let error = await #expect(throws: HealthAppIntentError.self) {
        try await HealthAppIntents.perform(.sync)
      }
      #expect(error?.message == AgentAccessError.off.localizedDescription)
    }
    #expect(asked.value.isEmpty)
    #expect(try accessStore.entries().isEmpty)
  }

  @Test
  func logsSyncThenAsksTheAppWhileAccessIsOn() async throws {
    try accessStore.setEnabled(true)
    let result = try await withDependencies {
      $0.agentAccess = .live(accessStore)
      $0.healthAppActions.perform = { action, _ in
        #expect(action == .sync)
        return .synced(at: synced)
      }
    } operation: {
      try await HealthAppIntents.perform(.sync)
    }
    #expect(result == .synced(at: synced))
    let entries = try accessStore.entries()
    #expect(entries.map(\.command) == ["sync"])
    #expect(entries.map(\.process) == ["Shortcuts, Siri or Spotlight"])
  }

  @Test
  func failsWithSignInFirstWhenSignedOut() async throws {
    try accessStore.setEnabled(true)
    await withDependencies {
      $0.agentAccess = .live(accessStore)
      $0.healthAppActions = HealthAppActions(channel: HealthAppActionChannel(signInWait: .zero))
    } operation: {
      await #expect(throws: HealthAppActionError.signedOut) {
        try await HealthAppIntents.perform(.sync)
      }
    }
    #expect(try accessStore.entries().map(\.command) == ["sync"])
  }
}

/// A request for `AppFeature`, and its answer once given.
private func makeRequest(
  _ action: HealthAppAction
) -> (HealthAppActionRequest, () async throws -> HealthAppActionResult) {
  let (answers, answer) = AsyncStream<Result<HealthAppActionResult, any Error>>.makeStream()
  let request = HealthAppActionRequest(action: action) { answer.yield($0) }
  return (
    request,
    {
      for await result in answers { return try result.get() }
      throw CancellationError()
    }
  )
}

/// Sync whose status the test sets, recording each pull (`run`) and its end.
private final class FakeSync: Sendable {
  let events = LockIsolated<[String]>([])
  private let status: LockIsolated<SyncStatus>
  private let observers = LockIsolated<[AsyncStream<SyncStatus>.Continuation]>([])
  private let hangingRuns: Int
  private let runs = LockIsolated(0)

  init(_ status: SyncStatus, hangingRuns: Int = 0) {
    self.status = LockIsolated(status)
    self.hangingRuns = hangingRuns
  }

  /// How many have asked for the status.
  var observerCount: Int { observers.value.count }

  /// Announces a status, as the engine does: to every observer, even if it's the same as before.
  func set(_ status: SyncStatus) {
    self.status.setValue(status)
    for observer in observers.value { observer.yield(status) }
  }

  var client: SyncClient {
    SyncClient(
      run: { [events, runs, hangingRuns] in
        events.withValue { $0.append("run") }
        let run = runs.withValue {
          $0 += 1
          return $0
        }
        guard run <= hangingRuns else { return }
        try? await Task.sleep(for: .seconds(86_400))
        events.withValue { $0.append("run ended") }
      },
      listen: { _ in },
      syncNow: {},
      push: { _ in },
      status: { [status, observers] in
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        continuation.yield(status.value)
        observers.withValue { $0.append(continuation) }
        return stream
      },
      removeLocalData: {}
    )
  }
}
