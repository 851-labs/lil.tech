import ComposableArchitecture
import Foundation
import HealthAgentAccess
import HealthPages
import HealthUI
import LilAuth
import SwiftUI

// In their own file: previewing a file instruments it, and with `ForEach` rows that trips an
// assertion in the macOS `List` (AGENTS.md). Synthetic data only. The Account pane, at the
// window's width: the Settings window shows its tabs in the toolbar, which a preview's tab view
// doesn't.

@MainActor
private func settings(
  methods: SignInMethodsFeature.State.Methods = .loaded([
    SignInMethod(id: "idt_apple", provider: .apple, email: "x7y2@privaterelay.appleid.com")
  ]),
  export: DataExportFeature.State.Status = .idle,
  isSignedIn: Bool? = true
) -> some View {
  var state = AppFeature.State(isSignedIn: isSignedIn)
  state.account.signInMethods = SignInMethodsFeature.State(methods: methods)
  state.account.signInMethods.authorization.isGoogleAvailable = true
  state.account.signInMethods.authorization.appleWebAPI = URL(string: "https://api.lil.tech")
  state.account.dataExport.status = export
  // `EmptyReducer`, so the sections' tasks don't replace the state shown.
  return AccountSettingsView(store: Store(initialState: state) { EmptyReducer() })
    .previewFrame(width: SettingsView.width, height: SettingsView.height)
}

#Preview("Account") {
  settings()
}

#Preview("Loading sign-in methods") {
  settings(methods: .loading)
}

#Preview("Sign-in methods failed") {
  settings(methods: .failed(SignInMethodError.unavailable.message))
}

#Preview("Preparing an export") {
  settings(export: .preparing)
}

#Preview("Downloading an export") {
  settings(export: .downloading(0.42))
}

#Preview("Saving an export") {
  settings(export: .saving)
}

#Preview("Export saved") {
  settings(export: .saved(URL(filePath: "/Users/ada/Downloads/lil-export-2026-10-18.tar")))
}

#Preview("Export failed") {
  settings(export: .failed(DataExportError.unavailable.message))
}

#Preview("Signed out") {
  settings(isSignedIn: false)
}

#Preview("Checking the session") {
  settings(isSignedIn: nil)
}

// The Agents pane (851-2840), with what intents may do (851-2892). Synthetic queries.

private let agentQueries = [
  // An intent (851-2892).
  AgentAccessEntry(
    id: 5, date: Date(timeIntervalSince1970: 1_760_973_000), command: "open Steps",
    process: "Shortcuts, Siri or Spotlight"),
  AgentAccessEntry(
    id: 4, date: Date(timeIntervalSince1970: 1_760_972_520), command: "metric Steps --range W",
    process: "claude"),
  AgentAccessEntry(
    id: 3, date: Date(timeIntervalSince1970: 1_760_972_460), command: "summary",
    process: "claude"),
  AgentAccessEntry(
    id: 2, date: Date(timeIntervalSince1970: 1_760_965_200),
    command: "samples HeartRate --from 2025-10-13 --to 2025-10-20", process: "Codex"),
  AgentAccessEntry(
    id: 1, date: Date(timeIntervalSince1970: 1_760_961_600), command: "sleep --json",
    process: "zsh"),
]

@MainActor
private func agents(
  isEnabled: Bool = true, entries: [AgentAccessEntry] = agentQueries, isLoading: Bool = false,
  failure: String? = nil, logFailure: String? = nil, isSignedIn: Bool? = true,
  commandLineTool: URL? = URL(filePath: "/usr/local/bin/lil"),
  connected: ConnectedAgentsFeature.State = ConnectedAgentsFeature.State()
) -> some View {
  var state = AppFeature.State(isSignedIn: isSignedIn)
  state.agentAccess = AgentAccessFeature.State(
    commandLineTool: commandLineTool, entries: entries, failure: failure, isEnabled: isEnabled,
    isLoading: isLoading,
    logFailure: logFailure)
  state.connectedAgents = connected
  // `EmptyReducer`, so the pane's task doesn't replace the state shown. `ifLet`: closing an alert
  // (e.g. when a snapshot's window goes) clears it, as the feature does.
  return AgentAccessSettingsView(
    store: Store(initialState: state) {
      EmptyReducer<AppFeature.State, AppFeature.Action>()
        .ifLet(\.connectedAgents.$alert, action: \.connectedAgents.alert)
    }
  )
  .previewFrame(width: SettingsView.width, height: SettingsView.height)
}

#Preview("Agents: on, with a log") {
  agents()
}

#Preview("Agents: on, empty log") {
  agents(entries: [])
}

#Preview("Agents: off, with a log") {
  agents(isEnabled: false)
}

// How to connect an agent, before `lil` is installed (851-2865).
#Preview("Agents: without lil") {
  agents(entries: [], commandLineTool: nil)
}

#Preview("Agents: off") {
  agents(isEnabled: false, entries: [])
}

#Preview("Agents: loading") {
  agents(isEnabled: false, entries: [], isLoading: true)
}

#Preview("Agents: failed") {
  agents(
    isEnabled: false, entries: [],
    failure: "lil health couldn't read or save this setting: The disk is full.")
}

#Preview("Agents: log unreadable") {
  agents(
    entries: [],
    logFailure: "lil health couldn't read the access log: The database file is locked.")
}

// Revoking an agent connected to every lil app disconnects it from all of them (851-2902).
#Preview("Agents: revoke an agent on all lil apps") {
  agents(
    connected: ConnectedAgentsFeature.State(
      agents: .loaded(remoteAgents), alert: .confirmRevoke(combinedAgent)))
}

#Preview("Agents: signed out") {
  agents(isSignedIn: false)
}

// The Agents pane's remote agents (851-2853), on their own, tall enough to see them all.
// Synthetic agents and reads.

/// Connected through the combined server, to every lil app (851-2902).
private let combinedAgent = ConnectedAgent(
  id: "grant-5", name: "ChatGPT", domain: "chatgpt.com", app: nil, apps: ["health"],
  connectedAt: Date(timeIntervalSince1970: 1_760_960_000),
  firstUsedAt: nil,
  lastUsedAt: Date(timeIntervalSince1970: 1_760_960_000))

/// Most recently connected first, as the API lists them.
private let remoteAgents = [
  combinedAgent,
  ConnectedAgent(
    id: "grant-1", name: "Claude", domain: "claude.ai", app: "health",
    connectedAt: Date(timeIntervalSince1970: 1_760_900_000),
    firstUsedAt: Date(timeIntervalSince1970: 1_760_900_060),
    lastUsedAt: Date.now.addingTimeInterval(-2 * 3600)),
  ConnectedAgent(
    id: "grant-2", name: "Weekly Health Digest", domain: nil, app: "health",
    connectedAt: Date(timeIntervalSince1970: 1_760_800_000),
    firstUsedAt: Date(timeIntervalSince1970: 1_760_800_060),
    lastUsedAt: Date.now.addingTimeInterval(-3 * 86_400)),
]

private let remoteReads = (1...6).map { index in
  RemoteAgentAccess(
    id: 100 - index, at: Date(timeIntervalSince1970: 1_760_972_520 - Double(index) * 1_800),
    agentID: index.isMultiple(of: 3) ? "grant-2" : "grant-1",
    agentName: index.isMultiple(of: 3) ? "Weekly Health Digest" : "Claude",
    tool: index.isMultiple(of: 2) ? "get_metric" : "summary",
    types: index.isMultiple(of: 2) ? ["HKQuantityTypeIdentifierStepCount"] : [],
    range: index.isMultiple(of: 2) ? "W" : nil, outcome: "ok", rows: 7)
}

@MainActor
private func remote(_ state: ConnectedAgentsFeature.State) -> some View {
  Form {
    ConnectedAgentsSections(store: Store(initialState: state) { EmptyReducer() })
  }
  .formStyle(.grouped)
  .previewFrame(width: SettingsView.width, height: 720)
}

#Preview("Remote agents") {
  remote(ConnectedAgentsFeature.State(agents: .loaded(remoteAgents), log: remoteReads))
}

#Preview("Remote agents: none") {
  remote(ConnectedAgentsFeature.State(agents: .loaded([])))
}

#Preview("Remote agents: loading") {
  remote(ConnectedAgentsFeature.State(agents: .loading, isLoadingLog: true))
}

#Preview("Remote agents: failed") {
  remote(
    ConnectedAgentsFeature.State(
      agents: .failed(ConnectedAgentsError.unavailable.message),
      logFailure: ConnectedAgentsError.unavailable.message))
}

#Preview("Remote agents: revoking") {
  remote(
    ConnectedAgentsFeature.State(
      agents: .loaded(remoteAgents), log: remoteReads, revoking: ["grant-1"]))
}

#Preview("Remote agents: revoke failed") {
  remote(
    ConnectedAgentsFeature.State(
      agents: .loaded(remoteAgents), failure: ConnectedAgentsError.unavailable.message,
      log: remoteReads))
}

#Preview("Remote agents: turning off") {
  remote(
    ConnectedAgentsFeature.State(
      agents: .loaded(remoteAgents), log: remoteReads, isTurningOff: true))
}

#Preview("Remote agents: more of the log failed") {
  remote(
    ConnectedAgentsFeature.State(
      agents: .loaded(remoteAgents), log: remoteReads,
      logFailure: ConnectedAgentsError.unavailable.message, logNextBefore: 94))
}

#Preview("Remote agents: long names, more to read") {
  remote(
    ConnectedAgentsFeature.State(
      agents: .loaded([
        ConnectedAgent(
          id: "grant-3",
          name: "A Very Long Agent Name That Somebody Registered For Their Own Health Dashboard",
          domain: nil, app: nil, apps: ["health"],
          connectedAt: Date(timeIntervalSince1970: 1_760_700_000),
          firstUsedAt: nil,
          lastUsedAt: Date(timeIntervalSince1970: 1_760_700_000)),
        ConnectedAgent(
          id: "grant-4", name: nil, domain: nil, app: "health",
          connectedAt: Date(timeIntervalSince1970: 1_760_600_000),
          firstUsedAt: nil,
          lastUsedAt: Date(timeIntervalSince1970: 1_760_600_000)),
      ]),
      log: remoteReads
        + remoteReads.map { read in
          var read = read
          read.id -= 50
          read.at = read.at.addingTimeInterval(-86_400)
          return read
        },
      logNextBefore: 44))
}
