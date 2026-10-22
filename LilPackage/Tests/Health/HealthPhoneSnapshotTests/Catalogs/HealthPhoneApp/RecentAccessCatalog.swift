#if os(iOS)
  import ComposableArchitecture
  @testable import HealthPhoneApp
  import LilAuth
  import SwiftUI
  import Testing

  // Recent Access (`RecentAccessView`), from Connected Agents: what agents read, newest first,
  // nothing yet, loading, failed, loading or failing to load the next page, and a log read to its
  // end. Times are in Los Angeles (the scheme's `TZ`). Synthetic data only (`SyntheticAgents`).

  extension PhoneSnapshotTests {
    @Test(arguments: recentAccessCatalog.selectedStates)
    func recentAccess(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let recentAccessCatalog = StateCatalog(
    phone: "Recent Access",
    states: [
      CatalogState("Recent access") {
        recentAccess(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents), log: SyntheticAgents.reads(8),
            logNextBefore: 992))
      },
      CatalogState("Nothing read yet") {
        recentAccess(ConnectedAgentsFeature.State(agents: .loaded(SyntheticAgents.agents)))
      },
      CatalogState("Loading") {
        recentAccess(ConnectedAgentsFeature.State(isLoadingLog: true))
      },
      CatalogState("Failed") {
        recentAccess(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents),
            logFailure: ConnectedAgentsError.unavailable.message))
      },
      CatalogState("Loading more") {
        recentAccess(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents), log: SyntheticAgents.reads(8),
            isLoadingLog: true, logNextBefore: 992))
      },
      CatalogState("More failed") {
        recentAccess(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents), log: SyntheticAgents.reads(8),
            logFailure: ConnectedAgentsError.unavailable.message, logNextBefore: 992))
      },
      // Read to the end, with nothing more to show.
      CatalogState("Long log") {
        recentAccess(
          ConnectedAgentsFeature.State(
            agents: .loaded(SyntheticAgents.agents), log: SyntheticAgents.reads(40)))
      },
    ])

  @MainActor
  private func recentAccess(_ state: ConnectedAgentsFeature.State) -> some View {
    // `EmptyReducer`: reaching the end of the list would read the next page.
    NavigationStack {
      RecentAccessView(store: Store(initialState: state) { EmptyReducer() })
    }
  }
#endif
