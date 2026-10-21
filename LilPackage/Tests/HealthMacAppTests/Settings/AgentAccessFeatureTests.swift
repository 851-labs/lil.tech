import ComposableArchitecture
import Foundation
import HealthAgentAccess
import LilTestSupport
import Testing

@testable import HealthMacApp

// Synthetic data only (AGENTS.md).
@MainActor
struct AgentAccessFeatureTests {
  private let first = AgentAccessEntry(
    id: 1, date: Date(timeIntervalSince1970: 1_760_961_600), command: "summary", process: "zsh")
  private let second = AgentAccessEntry(
    id: 2, date: Date(timeIntervalSince1970: 1_760_965_200), command: "metric Steps --range W",
    process: "claude")

  @Test(.timeLimit(.minutes(1)))
  func readsTheSettingThenTheLogWhileOpen() async throws {
    let clock = ManualClock()
    let log = LockIsolated<[AgentAccessEntry]>([])
    let store = TestStore(initialState: AgentAccessFeature.State()) {
      AgentAccessFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.agentAccess.isEnabled = { true }
      $0.agentAccess.entries = { limit in
        #expect(limit == AgentAccessFeature.entryLimit)
        return log.value
      }
    }

    let task = await store.send(.task)
    await store.receive(\.settingLoaded) {
      $0.isEnabled = true
      $0.isLoading = false
    }
    await store.receive(\.entriesLoaded)

    // The command logs a query, and the open pane shows it at its next read.
    log.setValue([first])
    try await clock.waitUntilAsleep(endingIn: AgentAccessFeature.refreshInterval)
    clock.advance(by: AgentAccessFeature.refreshInterval)
    await store.receive(\.entriesLoaded) {
      $0.entries = [first]
    }
    log.setValue([second, first])
    try await clock.waitUntilAsleep(endingIn: AgentAccessFeature.refreshInterval)
    clock.advance(by: AgentAccessFeature.refreshInterval)
    await store.receive(\.entriesLoaded) {
      $0.entries = [second, first]
    }

    // Closing the pane stops reading.
    await task.cancel()
  }

  @Test
  func turningAccessOnAndOffSavesIt() async {
    let saved = LockIsolated<[Bool]>([])
    let now = Date(timeIntervalSince1970: 1_760_970_000)
    let store = TestStore(
      initialState: AgentAccessFeature.State(entries: [first], isLoading: false)
    ) {
      AgentAccessFeature()
    } withDependencies: {
      $0.date.now = now
      $0.agentAccess.setEnabled = { isEnabled, date in
        // Dated, so saves that finish out of order end as the person left the setting.
        #expect(date == now)
        saved.withValue { $0.append(isEnabled) }
      }
    }

    await store.send(.accessToggled(true)) {
      $0.isEnabled = true
    }
    await store.send(.turnOffButtonTapped) {
      $0.isEnabled = false
    }
    await store.finish()
    #expect(saved.value == [true, false])
  }

  @Test
  func aSettingThatCouldntBeSavedShowsWhatsSaved() async {
    struct DiskFull: Error {}
    let store = TestStore(initialState: AgentAccessFeature.State(isLoading: false)) {
      AgentAccessFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_760_970_000)
      $0.agentAccess.setEnabled = { _, _ in throw DiskFull() }
      $0.agentAccess.isEnabled = { false }
    }

    await store.send(.accessToggled(true)) {
      $0.isEnabled = true
    }
    await store.receive(\.settingFailed) {
      $0.failure =
        "lil health couldn't read or save this setting: \(DiskFull().localizedDescription)"
    }
    await store.receive(\.settingLoaded) {
      $0.isEnabled = false
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func failuresToReadShowUntilReadingWorksAgain() async throws {
    struct Busy: Error {}
    let clock = ManualClock()
    let logReadable = LockIsolated(false)
    let store = TestStore(initialState: AgentAccessFeature.State()) {
      AgentAccessFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.agentAccess.isEnabled = { throw Busy() }
      $0.agentAccess.entries = { _ in
        guard logReadable.value else { throw Busy() }
        return []
      }
    }

    let task = await store.send(.task)
    // The toggle works again, rather than staying disabled for good.
    await store.receive(\.settingFailed) {
      $0.failure = "lil health couldn't read or save this setting: \(Busy().localizedDescription)"
      $0.isLoading = false
    }
    await store.receive(\.logFailed) {
      $0.logFailure = "lil health couldn't read the access log: \(Busy().localizedDescription)"
    }
    logReadable.setValue(true)
    try await clock.waitUntilAsleep(endingIn: AgentAccessFeature.refreshInterval)
    clock.advance(by: AgentAccessFeature.refreshInterval)
    await store.receive(\.entriesLoaded) {
      $0.logFailure = nil
    }
    await task.cancel()
  }
}
