import ComposableArchitecture
import Foundation
import LilTestSupport
import Testing

@testable import LilAuth

// Synthetic data only (AGENTS.md).
@MainActor
struct ConnectedAgentsFeatureTests {
  private let claude = ConnectedAgent(
    id: "grant-1", name: "Claude", domain: "claude.ai", app: "health",
    connectedAt: Date(timeIntervalSince1970: 1_760_900_000),
    firstUsedAt: Date(timeIntervalSince1970: 1_760_900_060),
    lastUsedAt: Date(timeIntervalSince1970: 1_760_960_000))
  private let unnamed = ConnectedAgent(
    id: "grant-2", name: nil, domain: nil, app: "health",
    connectedAt: Date(timeIntervalSince1970: 1_760_800_000),
    firstUsedAt: nil,
    lastUsedAt: Date(timeIntervalSince1970: 1_760_800_000))
  /// Another app's agent, which lil health doesn't list.
  private let mailAgent = ConnectedAgent(
    id: "grant-3", name: "Mail Helper", domain: "example.com", app: "mail",
    connectedAt: Date(timeIntervalSince1970: 1_760_700_000),
    firstUsedAt: nil,
    lastUsedAt: Date(timeIntervalSince1970: 1_760_700_000))
  /// Connected through the combined server (851-2902), to lil health and lil mail.
  private let combined = ConnectedAgent(
    id: "grant-4", name: "ChatGPT", domain: "chatgpt.com", app: nil, apps: ["health", "mail"],
    connectedAt: Date(timeIntervalSince1970: 1_760_600_000),
    firstUsedAt: nil,
    lastUsedAt: Date(timeIntervalSince1970: 1_760_600_000))
  /// A combined agent that lil health was taken away from (its Turn Off), which reads only mail.
  private let combinedMailOnly = ConnectedAgent(
    id: "grant-5", name: "Mail Digest", domain: "example.com", app: nil, apps: ["mail"],
    connectedAt: Date(timeIntervalSince1970: 1_760_500_000),
    firstUsedAt: nil,
    lastUsedAt: Date(timeIntervalSince1970: 1_760_500_000))

  private nonisolated static func access(_ id: Int) -> RemoteAgentAccess {
    RemoteAgentAccess(
      id: id, at: Date(timeIntervalSince1970: 1_760_960_000 - Double(id) * 60),
      agentID: "grant-1", agentName: "Claude", tool: "get_metric",
      types: ["HKQuantityTypeIdentifierStepCount"], range: "W", outcome: "ok", rows: 7)
  }

  @Test
  func openingThePaneLoadsLilHealthsAgentsAndTheLog() async {
    let store = TestStore(initialState: ConnectedAgentsFeature.State()) {
      ConnectedAgentsFeature()
    } withDependencies: { [claude, unnamed, mailAgent] in
      $0.connectedAgents.list = { () throws(ConnectedAgentsError) in [claude, mailAgent, unnamed] }
      $0.connectedAgents.accessLog = { before throws(ConnectedAgentsError) in
        #expect(before == nil)
        return RemoteAgentAccessPage(entries: [Self.access(1), Self.access(2)], nextBefore: 2)
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.appeared) {
      $0.isLoadingLog = true
    }
    await store.receive(\.agentsLoaded) {
      $0.agents = .loaded([claude, unnamed])
    }
    await store.receive(\.logLoaded) {
      $0.isLoadingLog = false
      $0.log = [Self.access(1), Self.access(2)]
      $0.logNextBefore = 2
    }
  }

  @Test
  func listsTheAgentsThatReadLilHealthIncludingCombinedOnes() async {
    let store = TestStore(initialState: ConnectedAgentsFeature.State()) {
      ConnectedAgentsFeature()
    } withDependencies: { [claude, mailAgent, combined, combinedMailOnly] in
      $0.connectedAgents.list = { () throws(ConnectedAgentsError) in
        [claude, mailAgent, combined, combinedMailOnly]
      }
      $0.connectedAgents.accessLog = { _ throws(ConnectedAgentsError) in
        RemoteAgentAccessPage(entries: [], nextBefore: nil)
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.appeared)
    // Not another app's own agent, nor a combined one that no longer reads lil health.
    await store.receive(\.agentsLoaded) {
      $0.agents = .loaded([claude, combined])
    }
    #expect(!claude.isCombined)
    #expect(combined.isCombined)
  }

  @Test
  func revokingACombinedAgentSaysItDisconnectsEveryApp() async {
    let revoked = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: ConnectedAgentsFeature.State(agents: .loaded([claude, combined]))
    ) {
      ConnectedAgentsFeature()
    } withDependencies: {
      $0.connectedAgents.revoke = { id throws(ConnectedAgentsError) in
        revoked.withValue { $0.append(id) }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.revokeButtonTapped(combined)) {
      $0.alert = .confirmRevoke(self.combined)
    }
    let message = store.state.alert.map { String(state: $0.message ?? TextState("")) }
    #expect(message?.contains("disconnects it from every lil app") == true)
    let perApp = AlertState.confirmRevoke(claude).message.map { String(state: $0) }
    #expect(perApp?.contains("your Health data") == true)
    await store.send(\.alert.confirmRevoke, "grant-4") {
      $0.alert = nil
      $0.revoking = ["grant-4"]
    }
    await store.receive(\.revoked) {
      $0.revoking = []
      $0.agents = .loaded([claude])
    }
    // The whole grant: the server ends it for every app.
    #expect(revoked.value == ["grant-4"])
  }

  @Test
  func showMoreAppendsTheNextPage() async {
    let store = TestStore(
      initialState: ConnectedAgentsFeature.State(
        agents: .loaded([claude]), log: [Self.access(1), Self.access(2)], logNextBefore: 2)
    ) {
      ConnectedAgentsFeature()
    } withDependencies: {
      $0.connectedAgents.accessLog = { before throws(ConnectedAgentsError) in
        #expect(before == 2)
        return RemoteAgentAccessPage(entries: [Self.access(3)], nextBefore: nil)
      }
    }

    await store.send(.loadMoreLogButtonTapped) {
      $0.isLoadingLog = true
    }
    await store.receive(\.logLoaded) {
      $0.isLoadingLog = false
      $0.log = [Self.access(1), Self.access(2), Self.access(3)]
      $0.logNextBefore = nil
    }
  }

  @Test
  func revokingAfterConfirmingRemovesTheAgent() async {
    let revoked = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: ConnectedAgentsFeature.State(agents: .loaded([claude, unnamed]))
    ) {
      ConnectedAgentsFeature()
    } withDependencies: {
      $0.connectedAgents.revoke = { id throws(ConnectedAgentsError) in
        revoked.withValue { $0.append(id) }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.revokeButtonTapped(claude))
    #expect(store.state.alert != nil)
    // Nothing until it's confirmed.
    #expect(revoked.value.isEmpty)
    await store.send(\.alert.confirmRevoke, "grant-1") {
      $0.alert = nil
      $0.revoking = ["grant-1"]
    }
    await store.receive(\.revoked) {
      $0.revoking = []
      $0.agents = .loaded([unnamed])
    }
    #expect(revoked.value == ["grant-1"])
  }

  @Test
  func aRevokeThatFailsKeepsTheAgentAndSaysWhy() async {
    let store = TestStore(initialState: ConnectedAgentsFeature.State(agents: .loaded([claude]))) {
      ConnectedAgentsFeature()
    } withDependencies: {
      $0.connectedAgents.revoke = { _ throws(ConnectedAgentsError) in throw .unavailable }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.revokeButtonTapped(claude))
    await store.send(\.alert.confirmRevoke, "grant-1") {
      $0.revoking = ["grant-1"]
    }
    await store.receive(\.revoked) {
      $0.revoking = []
      $0.failure = ConnectedAgentsError.unavailable.message
    }
    #expect(store.state.agents == .loaded([claude]))
  }

  @Test
  func turningOffAgentAccessRevokesEveryAgent() async {
    let turnedOff = LockIsolated(false)
    let store = TestStore(
      initialState: ConnectedAgentsFeature.State(agents: .loaded([claude, unnamed]))
    ) {
      ConnectedAgentsFeature()
    } withDependencies: {
      $0.connectedAgents.turnOffHealthAgents = { () throws(ConnectedAgentsError) in
        turnedOff.setValue(true)
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.turnOffButtonTapped)
    await store.send(\.alert.confirmTurnOff) {
      $0.isTurningOff = true
    }
    await store.receive(\.turnedOff) {
      $0.isTurningOff = false
      $0.agents = .loaded([])
    }
    #expect(turnedOff.value)
  }

  @Test
  func aListThatCantLoadSaysWhy() async {
    let store = TestStore(initialState: ConnectedAgentsFeature.State()) {
      ConnectedAgentsFeature()
    } withDependencies: {
      $0.connectedAgents.list = { () throws(ConnectedAgentsError) in throw .signedOut }
      $0.connectedAgents.accessLog = { _ throws(ConnectedAgentsError) in throw .signedOut }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.appeared)
    await store.receive(\.agentsLoaded) {
      $0.agents = .failed(ConnectedAgentsError.signedOut.message)
    }
    await store.receive(\.logLoaded) {
      $0.isLoadingLog = false
      $0.logFailure = ConnectedAgentsError.signedOut.message
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aListReadBeforeARevokeDoesntBringTheAgentBack() async throws {
    let clock = ManualClock()
    let store = TestStore(
      initialState: ConnectedAgentsFeature.State(agents: .loaded([claude, unnamed]))
    ) {
      ConnectedAgentsFeature()
    } withDependencies: { [claude, unnamed] in
      $0.connectedAgents.list = { () throws(ConnectedAgentsError) in
        // Read before the revoke, answered after it.
        try? await clock.sleep(for: .seconds(5))
        return [claude, unnamed]
      }
      $0.connectedAgents.accessLog = { _ throws(ConnectedAgentsError) in
        RemoteAgentAccessPage(entries: [], nextBefore: nil)
      }
      $0.connectedAgents.revoke = { _ throws(ConnectedAgentsError) in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.appeared)
    await store.send(.revokeButtonTapped(claude))
    await store.send(\.alert.confirmRevoke, "grant-1")
    await store.receive(\.revoked) {
      $0.agents = .loaded([unnamed])
    }
    // The revoke cancelled the read, so its answer never comes.
    clock.advance(by: .seconds(5))
    await store.finish()
    #expect(store.state.agents == .loaded([unnamed]))
  }

  @Test
  func openingAgainAfterAFailureShowsProgressNotTheOldError() async {
    let store = TestStore(
      initialState: ConnectedAgentsFeature.State(
        agents: .failed("Offline"), logFailure: "Offline")
    ) {
      ConnectedAgentsFeature()
    } withDependencies: { [claude] in
      $0.connectedAgents.list = { () throws(ConnectedAgentsError) in [claude] }
      $0.connectedAgents.accessLog = { _ throws(ConnectedAgentsError) in
        RemoteAgentAccessPage(entries: [Self.access(1)], nextBefore: nil)
      }
    }

    await store.send(.appeared) {
      $0.agents = .loading
      $0.logFailure = nil
      $0.isLoadingLog = true
    }
    await store.receive(\.agentsLoaded) {
      $0.agents = .loaded([claude])
    }
    await store.receive(\.logLoaded) {
      $0.isLoadingLog = false
      $0.log = [Self.access(1)]
    }
  }

  @Test
  func tryAgainReadsTheLogsFirstPageAgain() async {
    let store = TestStore(
      initialState: ConnectedAgentsFeature.State(
        agents: .loaded([claude]), logFailure: ConnectedAgentsError.unavailable.message)
    ) {
      ConnectedAgentsFeature()
    } withDependencies: {
      $0.connectedAgents.accessLog = { before throws(ConnectedAgentsError) in
        #expect(before == nil)
        return RemoteAgentAccessPage(entries: [Self.access(1), Self.access(2)], nextBefore: 2)
      }
    }

    // Show More can't: there's no page to read on from.
    await store.send(.loadMoreLogButtonTapped)
    await store.send(.retryLogButtonTapped) {
      $0.isLoadingLog = true
      $0.logFailure = nil
    }
    await store.receive(\.logLoaded) {
      $0.isLoadingLog = false
      $0.log = [Self.access(1), Self.access(2)]
      $0.logNextBefore = 2
    }
    // Once a page is read, Show More reads on instead.
    await store.send(.retryLogButtonTapped)
  }

  @Test
  func isBusyWhileRevokingOrTurningOff() {
    #expect(!ConnectedAgentsFeature.State(agents: .loaded([claude])).isBusy)
    #expect(ConnectedAgentsFeature.State(revoking: ["grant-1"]).isBusy)
    #expect(ConnectedAgentsFeature.State(isTurningOff: true).isBusy)
  }

  @Test
  func describesAgentsAndReads() {
    #expect(unnamed.isUnused)
    #expect(unnamed.lastUsedDescription == "Not used yet")
    #expect(!claude.isUnused)
    #expect(claude.lastUsedDescription.hasPrefix("Last used "))
    // One that read only in its first minute, before the server's 5-minute throttle on
    // `lastUsedAt` would have recorded it (851-2872).
    let connectedAt = Date.now.addingTimeInterval(-90)
    let readAtOnce = ConnectedAgent(
      id: "grant-4", name: "Claude", domain: "claude.ai", app: "health",
      connectedAt: connectedAt, firstUsedAt: connectedAt.addingTimeInterval(30),
      lastUsedAt: connectedAt.addingTimeInterval(30))
    #expect(!readAtOnce.isUnused)
    #expect(readAtOnce.lastUsedDescription.hasPrefix("Last used "))
    // Even in the millisecond it connected.
    var sameMoment = readAtOnce
    sameMoment.firstUsedAt = connectedAt
    sameMoment.lastUsedAt = connectedAt
    #expect(!sameMoment.isUnused)
    let read = Self.access(1)
    #expect(read.request() == "get_metric HKQuantityTypeIdentifierStepCount W")
    #expect(read.request { _ in "Steps" } == "get_metric Steps W")
    #expect(read.agentAndOutcome == "Claude")
    var tooLarge = read
    tooLarge.outcome = "too_large"
    #expect(tooLarge.agentAndOutcome == "Claude · too_large")
  }

  @Test
  func tryAgainReadsTheListAgain() async {
    let store = TestStore(
      initialState: ConnectedAgentsFeature.State(agents: .failed("Offline"))
    ) {
      ConnectedAgentsFeature()
    } withDependencies: { [claude] in
      $0.connectedAgents.list = { () throws(ConnectedAgentsError) in [claude] }
    }

    await store.send(.retryButtonTapped) {
      $0.agents = .loading
    }
    await store.receive(\.agentsLoaded) {
      $0.agents = .loaded([claude])
    }
  }
}
