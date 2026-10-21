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

// The Agents pane (851-2840). Synthetic queries.

private let agentQueries = [
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
  commandLineTool: URL? = URL(filePath: "/usr/local/bin/lil")
) -> some View {
  var state = AppFeature.State(isSignedIn: isSignedIn)
  state.agentAccess = AgentAccessFeature.State(
    commandLineTool: commandLineTool, entries: entries, failure: failure, isEnabled: isEnabled,
    isLoading: isLoading,
    logFailure: logFailure)
  // `EmptyReducer`, so the pane's task doesn't replace the state shown.
  return AgentAccessSettingsView(store: Store(initialState: state) { EmptyReducer() })
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

#Preview("Agents: signed out") {
  agents(isSignedIn: false)
}
