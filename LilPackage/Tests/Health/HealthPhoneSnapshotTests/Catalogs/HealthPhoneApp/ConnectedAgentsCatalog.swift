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
                connectedAt: ago(days: 4), firstUsedAt: nil, lastUsedAt: ago(days: 4)),
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
                connectedAt: ago(days: 3), firstUsedAt: nil, lastUsedAt: ago(days: 3)),
              ConnectedAgent(
                id: "grant-6", name: "Health Insights Assistant for Research Studies",
                domain: "research-assistant.health-insights.example.com", app: "health",
                connectedAt: ago(days: 3.5), firstUsedAt: ago(days: 3.5), lastUsedAt: ago(hours: 26)
              ),
            ])))
      },
    ])

  /// Synthetic agents and reads, for Connected Agents' and Recent Access's catalogs.
  enum SyntheticAgents {
    static let claude = ConnectedAgent(
      id: "grant-1", name: "Claude", domain: "claude.ai", app: "health",
      connectedAt: ago(days: 1), firstUsedAt: ago(days: 1), lastUsedAt: ago(hours: 2))
    static let digest = ConnectedAgent(
      id: "grant-2", name: "Weekly Health Digest", domain: nil, app: "health",
      connectedAt: ago(days: 5), firstUsedAt: ago(days: 5), lastUsedAt: ago(days: 3))
    /// Connected through the combined server, to every lil app (851-2902).
    static let chatGPT = ConnectedAgent(
      id: "grant-3", name: "ChatGPT", domain: "chatgpt.com", app: nil, apps: ["health"],
      connectedAt: ago(hours: 6), firstUsedAt: nil, lastUsedAt: ago(hours: 6))

    /// Most recently connected first, as the API lists them.
    static let agents = [chatGPT, claude, digest]

    /// `count` reads, half an hour apart, newest first from two hours before `previewNow`, every
    /// third by the digest, some of them not ok.
    static func reads(_ count: Int, from start: Int = 0) -> [RemoteAgentAccess] {
      (start..<(start + count)).map { index in
        let byDigest = index.isMultiple(of: 3)
        let asksForSteps = index.isMultiple(of: 2)
        return RemoteAgentAccess(
          id: 1_000 - index,
          at: ago(hours: 2 + Double(index) / 2),
          agentID: byDigest ? digest.id : claude.id,
          agentName: byDigest ? "Weekly Health Digest" : "Claude",
          tool: asksForSteps ? "get_metric" : "summary",
          types: asksForSteps
            ? ["HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate"] : [],
          range: asksForSteps ? "W" : nil, date: asksForSteps ? "2024-08-13" : nil,
          outcome: index % 7 == 5 ? "too_large" : "ok", rows: asksForSteps ? 14 : 1)
      }
    }
  }

  /// A time before `previewNow`, so it reads as it would in the app on that day.
  private func ago(days: Double = 0, hours: Double = 0) -> Date {
    previewNow.addingTimeInterval(-(days * 86_400 + hours * 3_600))
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
