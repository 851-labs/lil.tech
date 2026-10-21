import AppKit
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

      AgentSetupSection(commandLineTool: store.commandLineTool)

      Section {
        if store.isLoading {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        } else if store.entries.isEmpty, let logFailure = store.logFailure {
          Text(logFailure)
            .foregroundStyle(.red)
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
      } footer: {
        // Below the entries last read.
        if !store.entries.isEmpty, let logFailure = store.logFailure {
          Text(logFailure)
            .foregroundStyle(.red)
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

/// How to connect an agent to `lil-health mcp`, a local MCP server agents start themselves
/// (851-2865): Claude Code's command, and for other agents a local (stdio) server's command and
/// arguments, with `lil`'s full path, since apps don't get the shell's `PATH`. lil health has no
/// help book, so it's said here.
struct AgentSetupSection: View {
  /// Where `lil` is installed, if it is.
  let commandLineTool: URL?

  static let arguments = "health mcp"

  /// Claude Code's command, with `lil`'s full path once it's known: an agent started from an IDE
  /// or the Dock may not have `~/.local/bin` on its `PATH`.
  static func claudeCode(_ lil: String) -> String {
    "claude mcp add --scope user lil-health -- \(lil) health mcp"
  }

  var body: some View {
    Section {
      if let path = commandLineTool?.path(percentEncoded: false) {
        CopyableRow(title: "Claude Code", value: Self.claudeCode(path))
        CopyableRow(title: "Other agents: command", value: path)
        CopyableRow(title: "Other agents: arguments", value: Self.arguments)
      } else {
        CopyableRow(title: "Claude Code", value: Self.claudeCode("lil"))
        // A bare `lil` wouldn't start from an app, which doesn't get the shell's `PATH`.
        LabeledContent("Other agents") {
          Text("Once lil is installed, its path appears here.")
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Connect an Agent")
    } footer: {
      Group {
        if commandLineTool == nil {
          Text(
            "These need the lil command. Install it with lil health › Install Command Line Tool…, then add lil-health to your agent as a local (stdio) MCP server."
          )
        } else {
          Text(
            "Add lil-health to your agent as a local (stdio) MCP server. The agent starts it when it needs it, and it answers while access is on."
          )
        }
      }
      .foregroundStyle(.secondary)
    }
  }
}

/// A title above a monospaced value, with a button that copies it.
struct CopyableRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(value)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button("Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
      }
      .help("Copy \(value)")
    }
  }
}
