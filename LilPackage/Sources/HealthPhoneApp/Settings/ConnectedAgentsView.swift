import ComposableArchitecture
import Foundation
import LilAPI
import LilAuth
import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// Settings › Connected Agents (851-2854): the remote agents allowed to read the account's Health
/// data through lil health's MCP server, each revoked with a swipe; Recent Access, what they read;
/// how to connect one; and Turn Off Agent Access. Revoking and turning off ask first. It reads the
/// agents and the log again each time it opens.
struct ConnectedAgentsView: View {
  @Bindable var store: StoreOf<ConnectedAgentsFeature>
  /// The deployment the app talks to, whose MCP server agents connect to.
  var environment = Self.currentEnvironment

  private static let currentEnvironment = APIEnvironment.current()

  /// Whether it has asked for the agents since it opened: coming back from Recent Access isn't
  /// opening it again.
  @State private var hasAppeared = false

  var body: some View {
    List {
      Section {
        switch store.agents {
        case .loading:
          ProgressView()
            .frame(maxWidth: .infinity)
        case .failed(let message):
          VStack(alignment: .leading, spacing: 8) {
            Text(message)
              .foregroundStyle(.red)
            Button("Try Again") { store.send(.retryButtonTapped) }
          }
        case .loaded(let agents) where agents.isEmpty:
          Text("No agents are connected.")
            .foregroundStyle(.secondary)
        case .loaded(let agents):
          ForEach(agents) { agent in
            let isRevoking = store.revoking.contains(agent.id)
            ConnectedAgentRow(agent: agent, isRevoking: isRevoking)
              .swipeActions {
                // Not `.destructive`, which would take the row away before it's confirmed.
                Button("Revoke") { store.send(.revokeButtonTapped(agent)) }
                  .tint(.red)
                  .disabled(isRevoking || store.isTurningOff)
              }
          }
        }
      } footer: {
        if let failure = store.failure {
          Text(failure)
            .foregroundStyle(.red)
        } else if !store.loadedAgents.isEmpty {
          Text(
            "These read all of your lil health data from lil health's servers, from anywhere, until you revoke them. Swipe left on one to revoke it."
          )
        } else {
          Text(
            "Agents you allow read all of your lil health data from lil health's servers, from anywhere, until you revoke them."
          )
        }
      }

      Section {
        NavigationLink("Recent Access") {
          RecentAccessView(store: store)
        }
      } footer: {
        Text("What connected agents read, and when.")
      }

      MCPServerSection(
        url: environment.mcpURL(app: ConnectedAgentsFeature.app),
        helpURL: environment.agentsHelpURL)

      if case .loaded = store.agents {
        Section {
          if store.isTurningOff {
            LabeledContent("Turning Off…") { ProgressView() }
          } else {
            Button("Turn Off Agent Access", role: .destructive) {
              store.send(.turnOffButtonTapped)
            }
          }
        } footer: {
          Text("Every agent loses access, and none can connect again until you allow one.")
        }
      }
    }
    .navigationTitle("Connected Agents")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .refreshable { await store.send(.appeared).finish() }
    .onAppear {
      guard !hasAppeared else { return }
      hasAppeared = true
      store.send(.appeared)
    }
    .alert($store.scope(\.alert, action: \.alert))
  }
}

/// A connected agent: its name (marked when unverified), domain, and when it connected and last
/// read, with progress while it's revoked.
struct ConnectedAgentRow: View {
  let agent: ConnectedAgent
  let isRevoking: Bool

  private static let date = Date.FormatStyle.dateTime.month(.abbreviated).day().year()

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(ConnectedAgentsFeature.name(agent))
            .font(.body.weight(.medium))
            .lineLimit(2)
          if agent.isUnverified {
            Text("Unverified")
              .font(.caption.weight(.medium))
              .foregroundStyle(.orange)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(.orange.opacity(0.15), in: Capsule())
              .fixedSize()
          }
        }
        Text(agent.domain ?? "No verified website")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text("Connected \(agent.connectedAt.formatted(Self.date)) · \(agent.lastUsedDescription)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if isRevoking {
        ProgressView()
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// lil health's MCP server URL, the one agents are given, to copy, and the help page on
/// connecting one (851-2877).
struct MCPServerSection: View {
  let url: URL
  let helpURL: URL

  @State private var isCopied = false

  var body: some View {
    Section {
      HStack(alignment: .firstTextBaseline) {
        Text(url.absoluteString)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button(isCopied ? "Copied" : "Copy") {
          #if os(iOS)
            UIPasteboard.general.string = url.absoluteString
          #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
          #endif
          isCopied = true
        }
        .buttonStyle(.borderless)
        // Back to Copy after a moment, so a second copy shows too.
        .task(id: isCopied) {
          guard isCopied else { return }
          try? await Task.sleep(for: .seconds(2))
          isCopied = false
        }
      }
      Link("How to Connect an Agent", destination: helpURL)
    } header: {
      Text("Connect an Agent")
    } footer: {
      Text(
        "Add the MCP server URL to your agent as a remote MCP server (a connector), then sign in to lil health when it asks, and allow it."
      )
    }
  }
}
