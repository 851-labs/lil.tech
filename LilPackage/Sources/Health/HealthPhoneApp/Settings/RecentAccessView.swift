import ComposableArchitecture
import Foundation
import HealthCatalog
import LilAuth
import LilUI
import SwiftUI

/// Settings › Connected Agents › Recent Access (851-2854): the remote access log, newest first,
/// a page at a time. The next page loads when the end of the list shows, or with Show More.
struct RecentAccessView: View {
  let store: StoreOf<ConnectedAgentsFeature>

  var body: some View {
    List {
      Section {
        if store.log.isEmpty, store.isLoadingLog {
          DelayedProgressView()
            .frame(maxWidth: .infinity)
        } else if store.log.isEmpty, let failure = store.logFailure {
          VStack(alignment: .leading, spacing: 8) {
            Text(failure)
              .foregroundStyle(.red)
            Button("Try Again") { store.send(.retryLogButtonTapped) }
          }
        } else if store.log.isEmpty {
          Text("No agent has read your data yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.log) { entry in
            RecentAccessRow(entry: entry)
          }
          if store.isLoadingLog {
            // The next page, in Show More's place: at once, as the feedback of a tap on it, or
            // of its end coming into view (851-3086).
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
      Text(entry.request { id in HealthCatalog.type(id: id)?.name ?? id })
        .font(.callout.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(alignment: .firstTextBaseline) {
        Text(entry.agentAndOutcome)
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
}
