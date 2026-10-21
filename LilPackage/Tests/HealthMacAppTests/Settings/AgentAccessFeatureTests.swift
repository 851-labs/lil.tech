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
    let store = TestStore(
      initialState: AgentAccessFeature.State(entries: [first], isLoading: false)
    ) {
      AgentAccessFeature()
    } withDependencies: {
      $0.agentAccess.setEnabled = { isEnabled in saved.withValue { $0.append(isEnabled) } }
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
  func aSettingThatCouldntBeSavedGoesBack() async {
    struct DiskFull: Error {}
    let store = TestStore(initialState: AgentAccessFeature.State(isLoading: false)) {
      AgentAccessFeature()
    } withDependencies: {
      $0.agentAccess.setEnabled = { _ in throw DiskFull() }
    }

    await store.send(.accessToggled(true)) {
      $0.isEnabled = true
    }
    await store.receive(\.settingLoaded) {
      $0.isEnabled = false
    }
    await store.receive(\.failed) {
      $0.failure =
        "lil health couldn't read or save this setting: \(DiskFull().localizedDescription)"
    }
  }
}
