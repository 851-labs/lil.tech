import ComposableArchitecture
import Foundation
import HealthCatalog
import LilAuth
import SwiftUI

/// Settings › Connected Agents › Recent Access (851-2854): the remote access log, newest first,
/// a page at a time. The next page loads when the end of the list shows, or with Show More.
struct RecentAccessView: View {
  let store: StoreOf<ConnectedAgentsFeature>

  var body: some View {
    List {
      Section {
        if store.log.isEmpty, store.isLoadingLog {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else if store.log.isEmpty, let failure = store.logFailure {
          Text(failure)
            .foregroundStyle(.red)
        } else if store.log.isEmpty {
          Text("No agent has read your data yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.log) { entry in
            RecentAccessRow(entry: entry)
          }
          if store.isLoadingLog {
            ProgressView()
              .frame(maxWidth: .infinity)
          } else if let failure = store.logFailure {
            VStack(alignment: .leading, spacing: 8) {
              Text(failure)
                .foregroundStyle(.red)
              Button("Try Again") { store.send(.loadMoreLogButtonTapped) }
            }
          } else if store.logNextBefore != nil {
            Button("Show More") { store.send(.loadMoreLogButtonTapped) }
              .frame(maxWidth: .infinity)
              // The end of the list is in view: the next page comes without a tap.
              .onAppear { store.send(.loadMoreLogButtonTapped) }
          }
        }
      } footer: {
        Text("Each read names the tool an agent used and what it asked for, never the values.")
      }
    }
    .navigationTitle("Recent Access")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

/// A read in the remote access log: the tool with what it asked for, which agent (and how it
/// went, unless it went fine), and when.
struct RecentAccessRow: View {
  let entry: RemoteAgentAccess

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(Self.request(entry))
        .font(.callout.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(alignment: .firstTextBaseline) {
        Text(entry.outcome == "ok" ? entry.agentName : "\(entry.agentName) · \(entry.outcome)")
          .lineLimit(1)
        Spacer()
        Text(entry.at, format: .dateTime.month(.abbreviated).day().hour().minute())
          .monospacedDigit()
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  /// The tool and what it asked for: "get_metric Steps W", as the Mac shows it.
  static func request(_ entry: RemoteAgentAccess) -> String {
    let types = entry.types.map { id in HealthCatalog.type(id: id)?.name ?? id }
    return ([entry.tool] + types + [entry.range, entry.date].compactMap { $0 }).joined(
      separator: " ")
  }
}
