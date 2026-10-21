import ComposableArchitecture
import HealthAgentAccess
import SwiftUI

/// The Agents pane: command-line and agent access, while signed in. Signed out, the Mac has no
/// Health data to read.
struct AgentAccessSettingsView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    switch store.isSignedIn {
    case nil:
      // The stored session isn't checked yet.
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case false:
      ContentUnavailableView {
        Label("Not Signed In", systemImage: "terminal")
      } description: {
        Text("Sign in to lil health to let command-line tools and agents read your Health data.")
      }
    case true:
      AgentAccessForm(store: store.scope(\.agentAccess, action: \.agentAccess))
    }
  }
}

/// The setting, with what turning it on means, and the log of what read the data.
struct AgentAccessForm: View {
  @Bindable var store: StoreOf<AgentAccessFeature>

  var body: some View {
    Form {
      Section {
        Toggle(
          "Allow command-line and agent access", isOn: $store.isEnabled.sending(\.accessToggled)
        )
        .disabled(store.isLoading)
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "Lets the lil-health command, and AI agents through its MCP server, read all of your Health data on this Mac."
          )
          Label {
            Text(
              "Agents usually send what they read to their AI provider, which handles it under its own terms, not lil health's privacy policy."
            )
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.yellow)
          }
          if let failure = store.failure {
            Text(failure)
              .foregroundStyle(.red)
          }
        }
        .foregroundStyle(.secondary)
      }

      Section {
        if store.isLoading {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        } else if store.entries.isEmpty {
          Text("Nothing has read your Health data yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.entries) { entry in
            AgentAccessEntryRow(entry: entry)
          }
        }
      } header: {
        HStack {
          Text("Access Log")
          Spacer()
          if store.isEnabled {
            Button("Turn Off Access") { store.send(.turnOffButtonTapped) }
          }
        }
      }
    }
    .formStyle(.grouped)
    .task { await store.send(.task).finish() }
  }
}

/// A query in the log: the command or tool, what asked, and when.
struct AgentAccessEntryRow: View {
  let entry: AgentAccessEntry

  var body: some View {
    LabeledContent {
      Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
        .monospacedDigit()
    } label: {
      Text(entry.command)
        .font(.body.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
      Text(entry.process)
    }
  }
}
