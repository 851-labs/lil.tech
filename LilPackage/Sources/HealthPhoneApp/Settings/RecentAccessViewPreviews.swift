import ComposableArchitecture
import Foundation
import LilAuth
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only (`ConnectedAgentsPreviewData`).

@MainActor
private func recentAccess(_ state: ConnectedAgentsFeature.State) -> some View {
  // `EmptyReducer`: reaching the end of the list would read the next page.
  NavigationStack {
    RecentAccessView(store: Store(initialState: state) { EmptyReducer() })
  }
}

#Preview("Recent access") {
  recentAccess(
    ConnectedAgentsFeature.State(
      agents: .loaded(ConnectedAgentsPreviewData.agents),
      log: ConnectedAgentsPreviewData.reads(8), logNextBefore: 992))
}

#Preview("Nothing read yet") {
  recentAccess(ConnectedAgentsFeature.State(agents: .loaded(ConnectedAgentsPreviewData.agents)))
}

#Preview("Loading") {
  recentAccess(ConnectedAgentsFeature.State(isLoadingLog: true))
}

#Preview("Failed") {
  recentAccess(
    ConnectedAgentsFeature.State(
      agents: .loaded(ConnectedAgentsPreviewData.agents),
      logFailure: ConnectedAgentsError.unavailable.message))
}

#Preview("Loading more") {
  recentAccess(
    ConnectedAgentsFeature.State(
      agents: .loaded(ConnectedAgentsPreviewData.agents),
      log: ConnectedAgentsPreviewData.reads(8), isLoadingLog: true, logNextBefore: 992))
}

#Preview("More failed") {
  recentAccess(
    ConnectedAgentsFeature.State(
      agents: .loaded(ConnectedAgentsPreviewData.agents),
      log: ConnectedAgentsPreviewData.reads(8),
      logFailure: ConnectedAgentsError.unavailable.message, logNextBefore: 992))
}

#Preview("Long log") {
  // Read to the end, with nothing more to show.
  recentAccess(
    ConnectedAgentsFeature.State(
      agents: .loaded(ConnectedAgentsPreviewData.agents),
      log: ConnectedAgentsPreviewData.reads(40)))
}
