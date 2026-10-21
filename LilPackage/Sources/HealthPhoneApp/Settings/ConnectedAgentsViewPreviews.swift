import ComposableArchitecture
import Foundation
import LilAPI
import LilAuth
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only.

/// Synthetic agents and reads for Connected Agents' and Recent Access's previews.
enum ConnectedAgentsPreviewData {
  static let claude = ConnectedAgent(
    id: "grant-1", name: "Claude", domain: "claude.ai", app: "health",
    connectedAt: Date(timeIntervalSince1970: 1_760_900_000),
    lastUsedAt: Date.now.addingTimeInterval(-2 * 3600))
  static let digest = ConnectedAgent(
    id: "grant-2", name: "Weekly Health Digest", domain: nil, app: "health",
    connectedAt: Date(timeIntervalSince1970: 1_760_800_000),
    lastUsedAt: Date.now.addingTimeInterval(-3 * 86_400))
  static let chatGPT = ConnectedAgent(
    id: "grant-3", name: "ChatGPT", domain: "chatgpt.com", app: "health",
    connectedAt: Date(timeIntervalSince1970: 1_760_960_000),
    lastUsedAt: Date(timeIntervalSince1970: 1_760_960_000))

  static let agents = [claude, digest, chatGPT]

  /// `count` reads, newest first, every third by the digest, some of them not ok.
  static func reads(_ count: Int, from start: Int = 0) -> [RemoteAgentAccess] {
    (start..<(start + count)).map { index in
      let byDigest = index.isMultiple(of: 3)
      let asksForSteps = index.isMultiple(of: 2)
      return RemoteAgentAccess(
        id: 1_000 - index, at: Date(timeIntervalSince1970: 1_760_972_520 - Double(index) * 1_800),
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
private func agents(
  _ state: ConnectedAgentsFeature.State, environment: APIEnvironment = .staging
) -> some View {
  // `EmptyReducer`: opening the screen would read the agents again.
  // `ifLet`: closing an alert (e.g. when a snapshot's window goes) clears it, as the feature does.
  return NavigationStack {
    ConnectedAgentsView(
      store: Store(initialState: state) {
        EmptyReducer<ConnectedAgentsFeature.State, ConnectedAgentsFeature.Action>()
          .ifLet(\.$alert, action: \.alert)
      },
      environment: environment)
  }
}

#Preview("Connected agents") {
  agents(ConnectedAgentsFeature.State(agents: .loaded(ConnectedAgentsPreviewData.agents)))
}

#Preview("No agents") {
  agents(ConnectedAgentsFeature.State(agents: .loaded([])))
}

#Preview("Loading") {
  agents(ConnectedAgentsFeature.State(agents: .loading, isLoadingLog: true))
}

#Preview("Failed") {
  agents(
    ConnectedAgentsFeature.State(agents: .failed(ConnectedAgentsError.unavailable.message)))
}

#Preview("Revoke Claude?") {
  agents(
    ConnectedAgentsFeature.State(
      agents: .loaded(ConnectedAgentsPreviewData.agents),
      alert: .confirmRevoke(ConnectedAgentsPreviewData.claude)))
}

#Preview("Revoking") {
  agents(
    ConnectedAgentsFeature.State(
      agents: .loaded(ConnectedAgentsPreviewData.agents), revoking: ["grant-1"]))
}

#Preview("Revoke failed") {
  agents(
    ConnectedAgentsFeature.State(
      agents: .loaded(ConnectedAgentsPreviewData.agents),
      failure: ConnectedAgentsError.unavailable.message))
}

#Preview("Turn off agent access?") {
  agents(
    ConnectedAgentsFeature.State(
      agents: .loaded(ConnectedAgentsPreviewData.agents), alert: .confirmTurnOff))
}

#Preview("Turning off") {
  agents(
    ConnectedAgentsFeature.State(
      agents: .loaded(ConnectedAgentsPreviewData.agents), isTurningOff: true))
}

#Preview("Unverified and unnamed") {
  agents(
    ConnectedAgentsFeature.State(
      agents: .loaded([
        ConnectedAgentsPreviewData.digest,
        ConnectedAgent(
          id: "grant-4", name: nil, domain: nil, app: "health",
          connectedAt: Date(timeIntervalSince1970: 1_760_600_000),
          lastUsedAt: Date(timeIntervalSince1970: 1_760_600_000)),
      ])))
}

#Preview("Long names") {
  agents(
    ConnectedAgentsFeature.State(
      agents: .loaded([
        ConnectedAgent(
          id: "grant-5",
          name: "A Very Long Agent Name That Somebody Registered For Their Own Health Dashboard",
          domain: nil, app: "health", connectedAt: Date(timeIntervalSince1970: 1_760_700_000),
          lastUsedAt: Date(timeIntervalSince1970: 1_760_700_000)),
        ConnectedAgent(
          id: "grant-6", name: "Health Insights Assistant for Research Studies",
          domain: "research-assistant.health-insights.example.com", app: "health",
          connectedAt: Date(timeIntervalSince1970: 1_760_650_000),
          lastUsedAt: Date.now.addingTimeInterval(-26 * 3600)),
      ])))
}

#Preview("Before agents launch") {
  // Prod has no MCP server yet (851-2855), so there's no URL to give.
  agents(
    ConnectedAgentsFeature.State(agents: .loaded([])), environment: .prod)
}
