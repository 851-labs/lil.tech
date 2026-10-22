import AppKit
import ComposableArchitecture
import HealthAgentAccess
import HealthCatalog
import LilAPI
import LilAuth
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
      AgentAccessForm(
        store: store.scope(\.agentAccess, action: \.agentAccess),
        connected: store.scope(\.connectedAgents, action: \.connectedAgents))
    }
  }
}

/// The setting, with what turning it on means, and a row opening the log of what read the data on
/// this Mac; then the remote agents connected to the account, and a row opening what they read
/// (851-2853). The logs open in sheets over the window (851-3082), as Apple's own Settings windows
/// show sub-pages (Safari's Manage Website Data…), so the pane stays short.
struct AgentAccessForm: View {
  @Bindable var store: StoreOf<AgentAccessFeature>
  @Bindable var connected: StoreOf<ConnectedAgentsFeature>

  var body: some View {
    Form {
      Section {
        Toggle(
          "Allow command-line and agent access", isOn: $store.isEnabled.sending(\.accessToggled)
        )
        .disabled(store.isLoading)
        AgentLogRow(title: "Access Log", summary: localLogSummary) {
          store.send(.logShown(true))
        }
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "Lets the lil-health command, and AI agents through its MCP server, read all of your Health data on this Mac."
          )
          // App actions (851-2892) check the same setting.
          Text("Also lets Shortcuts, Siri and Spotlight open pages in lil health, sync and export.")
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

      ConnectedAgentsSections(store: connected)
    }
    .formStyle(.grouped)
    // On the form rather than the rows, which a grouped form may lay out again.
    .sheet(isPresented: $store.isShowingLog.sending(\.logShown)) {
      AgentAccessLogSheet(store: store)
    }
    .sheet(isPresented: $connected.isShowingLog.sending(\.logShown)) {
      RemoteAccessLogSheet(store: connected)
    }
    .task { await store.send(.task).finish() }
    .onAppear { connected.send(.appeared) }
    .alert($connected.scope(\.alert, action: \.alert))
  }

  /// Under the Access Log row: when the latest query was, or why there's none to show.
  private var localLogSummary: AgentLogRow.Summary {
    if let latest = store.entries.first {
      .latest(latest.date)
    } else if store.isLoadingLog {
      .loading
    } else if store.logFailure != nil {
      .failed
    } else {
      .none(AgentAccessLogSheet.empty)
    }
  }
}

/// A row opening a log in a sheet: its name, when its latest entry was (already read, for the
/// pane), and Show…, as System Settings' rows open their sheets (Keyboard Shortcuts…).
struct AgentLogRow: View {
  let title: String
  let summary: Summary
  let show: () -> Void

  enum Summary: Equatable {
    case latest(Date)
    case loading
    case failed
    /// An empty log, and what that means.
    case none(String)
  }

  var body: some View {
    LabeledContent {
      Button("Show…", action: show)
    } label: {
      Text(title)
      switch summary {
      case .latest(let date):
        Text("Latest \(date, format: .dateTime.month(.abbreviated).day().hour().minute())")
          .monospacedDigit()
      case .loading:
        Text("Loading…")
      case .failed:
        Text("lil health couldn't read it.")
      case .none(let description):
        Text(description)
      }
    }
  }
}

/// A log's sheet: its title and what it records above its entries, then Done, the default button
/// (Return). Esc closes it too, as it does any SwiftUI sheet. `actions` go before Done, on the left
/// (Turn Off Access).
struct AgentLogSheet<Content: View, Actions: View>: View {
  let title: String
  let description: String
  @ViewBuilder let content: Content
  @ViewBuilder let actions: Actions

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          content
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text(title)
              .font(.title3.weight(.semibold))
              .foregroundStyle(.primary)
            Text(description)
              .font(.body.weight(.regular))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.bottom, 4)
        }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        actions
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
    .frame(
      minWidth: AgentLogSheetSize.minWidth, idealWidth: AgentLogSheetSize.width,
      minHeight: AgentLogSheetSize.minHeight, idealHeight: AgentLogSheetSize.height)
  }
}

extension AgentLogSheet where Actions == EmptyView {
  /// A sheet with only Done.
  init(title: String, description: String, @ViewBuilder content: () -> Content) {
    self.init(title: title, description: description, content: content, actions: { EmptyView() })
  }
}

/// A log sheet's sizes. It opens at the Settings window's smallest size, so it never overhangs the
/// window, and resizes from there. Nonisolated for snapshot catalogs.
enum AgentLogSheetSize {
  nonisolated static let width = SettingsView.minWidth
  nonisolated static let height = SettingsView.minHeight
  nonisolated static let minWidth: CGFloat = 400
  nonisolated static let minHeight: CGFloat = 280
}

/// The log of what read the data on this Mac: the latest 100 queries, read again every few seconds
/// while the pane is open, and Turn Off Access while it's on.
struct AgentAccessLogSheet: View {
  let store: StoreOf<AgentAccessFeature>

  /// What the sheet and its row say while the log is empty.
  static let empty = "Nothing has read your Health data yet."

  var body: some View {
    AgentLogSheet(
      title: "Access Log",
      description:
        "What read your Health data on this Mac, the latest \(AgentAccessFeature.entryLimit): the command or tool with its arguments, and what ran it, never what it answered."
    ) {
      if store.entries.isEmpty, store.isLoadingLog {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity)
      } else if store.entries.isEmpty, let logFailure = store.logFailure {
        Text(logFailure)
          .foregroundStyle(.red)
      } else if store.entries.isEmpty {
        Text(Self.empty)
          .foregroundStyle(.secondary)
      } else {
        ForEach(store.entries) { entry in
          AgentAccessEntryRow(entry: entry)
        }
        // Below the entries last read.
        if let logFailure = store.logFailure {
          Text(logFailure)
            .foregroundStyle(.red)
        }
      }
    } actions: {
      if store.isEnabled {
        Button("Turn Off Access") { store.send(.turnOffButtonTapped) }
      }
    }
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

/// How to connect an agent to a local MCP server agents start themselves (851-2865): Claude
/// Code's command, and for other agents a local (stdio) server's command and arguments, with
/// `lil`'s full path, since apps don't get the shell's `PATH`. `lil mcp` comes first, one server for
/// every lil app (851-2898), then `lil health mcp` for agents that should only see lil health. lil
/// health has no help book, so it's said here.
struct AgentSetupSection: View {
  /// Where `lil` is installed, if it is.
  let commandLineTool: URL?

  /// `lil mcp`'s arguments: every lil app's tools.
  static let arguments = "mcp"
  /// `lil health mcp`'s: lil health's only.
  static let healthArguments = "health mcp"

  /// Claude Code's command adding `lil` with these arguments as the server `name`, with `lil`'s
  /// full path once it's known: an agent started from an IDE or the Dock may not have
  /// `~/.local/bin` on its `PATH`.
  static func claudeCode(name: String, lil: String, arguments: String) -> String {
    "claude mcp add --scope user \(name) -- \(lil) \(arguments)"
  }

  private var path: String? { commandLineTool?.path(percentEncoded: false) }

  var body: some View {
    Section {
      CopyableRow(
        title: "Claude Code",
        value: Self.claudeCode(name: "lil", lil: path ?? "lil", arguments: Self.arguments))
      if let path {
        CopyableRow(title: "Other agents: command", value: path)
        CopyableRow(title: "Other agents: arguments", value: Self.arguments)
      } else {
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
            "These need the lil command. Install it with lil health › Install Command Line Tool…, then add lil to your agent as a local (stdio) MCP server: one server for every lil app."
          )
        } else {
          Text(
            "Add lil to your agent as a local (stdio) MCP server: one server for every lil app. The agent starts it when it needs it, and it answers while access is on."
          )
        }
      }
      .foregroundStyle(.secondary)
    }

    Section {
      CopyableRow(
        title: "Claude Code",
        value: Self.claudeCode(
          name: "lil-health", lil: path ?? "lil", arguments: Self.healthArguments))
      if path != nil {
        CopyableRow(title: "Other agents: arguments", value: Self.healthArguments)
      }
    } header: {
      Text("Connect an Agent to lil health Only")
    } footer: {
      Text(
        path == nil
          ? "For an agent that should only see lil health, add lil-health instead, once lil is installed."
          : "For an agent that should only see lil health, add lil-health instead: the same command, with these arguments."
      )
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

/// Remote agents (851-2853): those connected to the account through lil health's MCP server, or the
/// combined one for every lil app (851-2902), revoking them, a row opening what they read
/// (851-3082), and how to connect one.
struct ConnectedAgentsSections: View {
  let store: StoreOf<ConnectedAgentsFeature>

  /// The deployment the app talks to, read once.
  private static let environment = APIEnvironment.current()

  var body: some View {
    Section {
      switch store.agents {
      case .loading:
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity)
      case .failed(let message):
        HStack {
          Text(message)
            .foregroundStyle(.red)
          Spacer()
          Button("Try Again") { store.send(.retryButtonTapped) }
        }
      case .loaded(let agents) where agents.isEmpty:
        Text("No agents are connected.")
          .foregroundStyle(.secondary)
      case .loaded(let agents):
        ForEach(agents) { agent in
          ConnectedAgentRow(
            agent: agent, isRevoking: store.revoking.contains(agent.id),
            revoke: { store.send(.revokeButtonTapped(agent)) })
        }
      }
      // Revoked agents' reads stay in the log, so it's there whatever the list shows.
      // Its sheet is on the pane's form (`AgentAccessForm`).
      AgentLogRow(title: "Remote Access Log", summary: logSummary) {
        store.send(.logShown(true))
      }
    } header: {
      HStack {
        Text("Remote Agents")
        Spacer()
        if store.isTurningOff {
          ProgressView()
            .controlSize(.small)
        } else if case .loaded = store.agents {
          Button("Turn Off Agent Access…") { store.send(.turnOffButtonTapped) }
        }
      }
    } footer: {
      if let failure = store.failure {
        Text(failure)
          .foregroundStyle(.red)
      } else {
        Text(
          "Agents you allow read all of your lil health data from lil health's servers, from anywhere, until you revoke them."
        )
        .foregroundStyle(.secondary)
      }
    }

    Section {
      CopyableRow(
        title: "MCP server URL",
        value: Self.environment.mcpURL(app: "health").absoluteString)
      Link("How to Connect an Agent", destination: Self.environment.agentsHelpURL)
    } header: {
      Text("Connect a Remote Agent")
    } footer: {
      Text(
        "Add the MCP server URL to your agent as a remote MCP server (a connector), then sign in to lil health when it asks, and allow it."
      )
      .foregroundStyle(.secondary)
    }

  }

  /// Under the Remote Access Log row: when the latest read was, or why there's none to show.
  private var logSummary: AgentLogRow.Summary {
    if let latest = store.log.first {
      .latest(latest.at)
    } else if store.isLoadingLog {
      .loading
    } else if store.logFailure != nil {
      .failed
    } else {
      .none(RemoteAccessLogSheet.empty)
    }
  }
}

/// What the remote agents read (851-2853), a page at a time, newest first, with Show More.
struct RemoteAccessLogSheet: View {
  let store: StoreOf<ConnectedAgentsFeature>

  /// What the sheet and its row say while the log is empty.
  static let empty = "No remote agent has read your data yet."

  var body: some View {
    AgentLogSheet(
      title: "Remote Access Log",
      description:
        "What agents connected to your account read from lil health's servers: the tool each used and what it asked for, never the values."
    ) {
      if store.log.isEmpty, store.isLoadingLog {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity)
      } else if store.log.isEmpty, let failure = store.logFailure {
        HStack {
          Text(failure)
            .foregroundStyle(.red)
          Spacer()
          Button("Try Again") { store.send(.retryLogButtonTapped) }
        }
      } else if store.log.isEmpty {
        Text(Self.empty)
          .foregroundStyle(.secondary)
      } else {
        ForEach(store.log) { entry in
          RemoteAccessRow(entry: entry)
        }
        if store.isLoadingLog {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        } else if let failure = store.logFailure {
          Text(failure)
            .foregroundStyle(.red)
        } else if store.logNextBefore != nil {
          Button("Show More") { store.send(.loadMoreLogButtonTapped) }
            .frame(maxWidth: .infinity)
        }
      }
    }
  }
}

/// A connected agent: its name (marked when unverified, or connected to all lil apps), domain, when
/// it connected and last read, and Revoke….
struct ConnectedAgentRow: View {
  let agent: ConnectedAgent
  let isRevoking: Bool
  let revoke: () -> Void

  private static let date = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
  /// From dependencies, so snapshot catalogs fix it (`previewNow`).
  @Dependency(\.date.now) private var now

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(ConnectedAgentsFeature.name(agent))
            .lineLimit(1)
            .truncationMode(.tail)
          if agent.isUnverified {
            AgentLabel(text: "Unverified", color: .orange)
              .help("It registered itself, so lil health can't confirm who made it.")
          }
          if agent.isCombined {
            AgentLabel(text: "All lil apps", color: .blue)
              .help(
                "It connected to every lil app at once. Revoking it disconnects it from all of them."
              )
          }
        }
        Text(agent.domain ?? "No verified website")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(
          "Connected \(agent.connectedAt.formatted(Self.date)) · \(agent.lastUsedDescription(now: now))"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      if isRevoking {
        ProgressView()
          .controlSize(.small)
      } else {
        Button("Revoke…", action: revoke)
      }
    }
  }
}

/// A short label next to an agent's name: Unverified, or All lil apps (851-2902).
private struct AgentLabel: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.caption.weight(.medium))
      .foregroundStyle(color)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(color.opacity(0.15), in: Capsule())
  }
}

/// A read in the remote access log: the tool with what it asked for, which agent, and when.
struct RemoteAccessRow: View {
  let entry: RemoteAgentAccess

  var body: some View {
    LabeledContent {
      Text(entry.at, format: .dateTime.month(.abbreviated).day().hour().minute())
        .monospacedDigit()
    } label: {
      Text(entry.request { id in HealthCatalog.type(id: id)?.name ?? id })
        .font(.body.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
      Text(entry.agentAndOutcome)
    }
  }
}
