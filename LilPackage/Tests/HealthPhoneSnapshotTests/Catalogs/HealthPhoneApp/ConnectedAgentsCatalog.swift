#if os(iOS)
  import ComposableArchitecture
  import Foundation
  @testable import HealthPhoneApp
  import LilAPI
  import LilAuth
  import SwiftUI
  import Testing

  // Connected Agents (`ConnectedAgentsView`), from Settings: the agents allowed to read the
  // account's data, none, loading, failed, revoking one (a combined agent's revoke disconnects it
  // from every lil app, 851-2902), turning agent access off, and unverified, unnamed and long
  // names. "Last used" is relative to `previewNow`. The MCP server URL is staging's. Synthetic data
  // only: made-up agents.

  extension PhoneSnapshotTests {
    @Test(arguments: connectedAgentsCatalog.selectedStates)
    func connectedAgents(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let connectedAgentsCatalog = StateCatalog(
    phone: "Connected Agents",
    states: [
      CatalogState("Connected agents") {
        agents(ConnectedAgentsFeature.State(agents: .loaded(SyntheticAgents.agents)))
      },
      CatalogState("No agents") {
        agents(ConnectedAgentsFeature.State(agents: .loaded([])))
      },
      CatalogState("Loading") {
        agents(ConnectedAgentsFeature.State(agents: .loading, isLoadingLog: true))
      },
      CatalogState("Failed") {
        agents(
          ConnectedAgentsFeature.State(agents: .failed(ConnectedAgentsError.unavailable.message)))
      },
      CatalogState("Revoke Claude?") {
        agents(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents),
            alert: .confirmRevoke(SyntheticAgents.claude)))
      },
      // A combined agent's: revoking it disconnects it from every lil app (851-2902).
      CatalogState("Revoke ChatGPT?") {
        agents(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents),
            alert: .confirmRevoke(SyntheticAgents.chatGPT)))
      },
      CatalogState("Revoking") {
        agents(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents), revoking: ["grant-1"]))
      },
      CatalogState("Revoke failed") {
        agents(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents),
            failure: ConnectedAgentsError.unavailable.message))
      },
      CatalogState("Turn off agent access?") {
        agents(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents), alert: .confirmTurnOff))
      },
      CatalogState("Turning off") {
        agents(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents), isTurningOff: true))
      },
      CatalogState("Unverified and unnamed") {
        agents(
          ConnectedAgentsFeature.State(
            agents: .loaded([
              SyntheticAgents.digest,
              ConnectedAgent(
                id: "grant-4", name: nil, domain: nil, app: "health",
                connectedAt: Date(timeIntervalSince1970: 1_760_600_000),
                firstUsedAt: nil,
                lastUsedAt: Date(timeIntervalSince1970: 1_760_600_000)),
            ])))
      },
      CatalogState("Long names") {
        agents(
          ConnectedAgentsFeature.State(
            agents: .loaded([
              ConnectedAgent(
                id: "grant-5",
                name:
                  "A Very Long Agent Name That Somebody Registered For Their Own Health Dashboard",
                domain: nil, app: nil, apps: ["health"],
                connectedAt: Date(timeIntervalSince1970: 1_760_700_000),
                firstUsedAt: nil,
                lastUsedAt: Date(timeIntervalSince1970: 1_760_700_000)),
              ConnectedAgent(
                id: "grant-6", name: "Health Insights Assistant for Research Studies",
                domain: "research-assistant.health-insights.example.com", app: "health",
                connectedAt: Date(timeIntervalSince1970: 1_760_650_000),
                firstUsedAt: Date(timeIntervalSince1970: 1_760_650_060),
                lastUsedAt: previewNow.addingTimeInterval(-26 * 3600)),
            ])))
      },
    ])

  /// Synthetic agents and reads, for Connected Agents' and Recent Access's catalogs.
  enum SyntheticAgents {
    static let claude = ConnectedAgent(
      id: "grant-1", name: "Claude", domain: "claude.ai", app: "health",
      connectedAt: Date(timeIntervalSince1970: 1_760_900_000),
      firstUsedAt: Date(timeIntervalSince1970: 1_760_900_060),
      lastUsedAt: previewNow.addingTimeInterval(-2 * 3600))
    static let digest = ConnectedAgent(
      id: "grant-2", name: "Weekly Health Digest", domain: nil, app: "health",
      connectedAt: Date(timeIntervalSince1970: 1_760_800_000),
      firstUsedAt: Date(timeIntervalSince1970: 1_760_800_060),
      lastUsedAt: previewNow.addingTimeInterval(-3 * 86_400))
    /// Connected through the combined server, to every lil app (851-2902).
    static let chatGPT = ConnectedAgent(
      id: "grant-3", name: "ChatGPT", domain: "chatgpt.com", app: nil, apps: ["health"],
      connectedAt: Date(timeIntervalSince1970: 1_760_960_000),
      firstUsedAt: nil,
      lastUsedAt: Date(timeIntervalSince1970: 1_760_960_000))

    /// Most recently connected first, as the API lists them.
    static let agents = [chatGPT, claude, digest]

    /// `count` reads, newest first, every third by the digest, some of them not ok.
    static func reads(_ count: Int, from start: Int = 0) -> [RemoteAgentAccess] {
      (start..<(start + count)).map { index in
        let byDigest = index.isMultiple(of: 3)
        let asksForSteps = index.isMultiple(of: 2)
        return RemoteAgentAccess(
          id: 1_000 - index,
          at: Date(timeIntervalSince1970: 1_760_972_520 - Double(index) * 1_800),
          agentID: byDigest ? digest.id : claude.id,
          agentName: byDigest ? "Weekly Health Digest" : "Claude",
          tool: asksForSteps ? "get_metric" : "summary",
          types: asksForSteps
            ? ["HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate"] : [],
          range: asksForSteps ? "W" : nil, date: asksForSteps ? "2026-10-20" : nil,
          outcome: index % 7 == 5 ? "too_large" : "ok", rows: asksForSteps ? 14 : 1)
      }
    }
  }

  @MainActor
  private func agents(_ state: ConnectedAgentsFeature.State) -> some View {
    // `EmptyReducer`: opening the screen would read the agents again.
    // `ifLet`: closing an alert clears it, as the feature does.
    NavigationStack {
      ConnectedAgentsView(
        store: Store(initialState: state) {
          EmptyReducer<ConnectedAgentsFeature.State, ConnectedAgentsFeature.Action>()
            .ifLet(\.$alert, action: \.alert)
        },
        environment: .staging)
    }
  }
#endif
