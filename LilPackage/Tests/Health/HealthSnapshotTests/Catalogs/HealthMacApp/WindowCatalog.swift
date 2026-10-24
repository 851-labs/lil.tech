#if os(macOS)
  import ComposableArchitecture
  import HealthCatalog
  import HealthDatabase
  import LilAuth
  @testable import HealthMacApp
  import LilSync
  import SwiftUI
  import Testing

  // The main window (`AppView`): its sidebar, toolbar and split view, with the selected page
  // read from the catalog database at `previewNow`. Synthetic data only.
  //
  // Unlike Pixelbook's screen captures, the window is never on screen, so its Liquid Glass
  // doesn't draw (851-2957): the sidebar, which floats in glass on macOS 26, with its rows,
  // search field and sync footer (`SyncFooterCatalog` has the footer), the toolbar's controls
  // and the window buttons.
  //
  // The test holds the main queue until the image is taken, so nothing the views start
  // asynchronously arrives: pages' first values are fetched at once instead
  // (`fetchesFirstValueAtOnce`), and pages that load in a `.task` (a metric's chart, Sleep's
  // nights) show as loading, as a preview's first frame did.

  extension MacSnapshotTests {
    @Test(arguments: windowCatalog.selectedStates)
    func window(_ state: CatalogState) {
      withDependencies {
        $0.fetchesFirstValueAtOnce = true
      } operation: {
        state.assertMacSnapshots()
      }
    }
  }

  let windowCatalog = StateCatalog(
    "Window", width: 960, minHeight: 640,
    states: [
      CatalogState("Launching") { window(AppFeature.State()) },
      CatalogState("Signed out") { window(signedOut()) },
      CatalogState("Summary") {
        window(
          AppFeature.State(
            isSignedIn: true, syncStatus: .upToDate(at: previewNow.addingTimeInterval(-120))))
      },
      CatalogState("First sync") {
        window(
          AppFeature.State(
            isSignedIn: true, syncStatus: .bootstrapping(.downloading(300_000, of: 2_000_000))))
      },
      CatalogState("A category") {
        window(AppFeature.State(isSignedIn: true, selection: .category(.heart)))
      },
      // Its icon is two-tone, and goes wholly white on the key window's selection (851-2823).
      CatalogState("A two-tone category") {
        window(AppFeature.State(isSignedIn: true, selection: .category(.medications)))
      },
      // Body Measurements lists it, as Health does (851-3187), and its row pushes it on the
      // category's stack, which is the store's (851-3030).
      CatalogState("Vision Prescriptions in Body Measurements") {
        window(
          AppFeature.State(
            isSignedIn: true, selection: .category(.bodyMeasurements),
            metricPath: [.metric(HealthDatabase.visionPrescriptionType)]))
      },
      // A metric's range and periods are in the toolbar (851-2821).
      CatalogState("A metric") {
        window(
          AppFeature.State(
            isSignedIn: true, selection: .dataType("HKQuantityTypeIdentifierStepCount")))
      },
      // Sleep's range and nights are in the toolbar too (851-2866).
      CatalogState("Sleep") {
        window(AppFeature.State(isSignedIn: true, selection: .dataType(HealthDatabase.sleepType)))
      },
      // The window at its smallest, where the toolbar is most crowded and the sidebar's last rows
      // go under its footer (851-2867).
      CatalogState("A metric, smallest window", width: 800, minHeight: 480) {
        window(
          AppFeature.State(
            isSignedIn: true,
            selection: .dataType("HKQuantityTypeIdentifierDistanceWalkingRunning")))
      },
      // The footer at its tallest, with its progress bar, over the rows of a short window
      // (851-2867).
      CatalogState("First sync, smallest window", width: 800, minHeight: 480) {
        window(
          AppFeature.State(
            isSignedIn: true, syncStatus: .bootstrapping(.downloading(300_000, of: 2_000_000))))
      },
      // Health Categories collapses, as a sidebar's sections do (851-3220). The sidebar's rows
      // alone, since in the window they float in glass, which doesn't draw. Its chevron only shows
      // while the pointer is over its header, which a snapshot doesn't draw either.
      CatalogState("Sidebar, Health Categories expanded", width: 240, minHeight: 640) {
        sidebar(categoriesExpanded: true)
      },
      CatalogState("Sidebar, Health Categories collapsed", width: 240, minHeight: 640) {
        sidebar(categoriesExpanded: false)
      },
      // A category stays selected while its row is hidden, rather than the selection jumping to
      // Summary: no row is highlighted, and the window still shows the category.
      CatalogState(
        "Sidebar, Health Categories collapsed, a category selected", width: 240, minHeight: 640
      ) {
        sidebar(selection: .category(.heart), categoriesExpanded: false)
      },
      // Opening a category from elsewhere (an intent, `lil-health open`, clearing the search)
      // while the section is collapsed expands it, so the category's row shows selected
      // (851-3225). The state is the reducer's, from the collapsed one above.
      CatalogState(
        "Sidebar, a category opened while Health Categories was collapsed", width: 240,
        minHeight: 640
      ) {
        SidebarList(
          store: opened(
            .category(.heart),
            in: sidebarState(selection: .category(.heart), categoriesExpanded: false)))
      },
      CatalogState("Search results") {
        window(AppFeature.State(isSignedIn: true, searchText: "heart"))
      },
      CatalogState("A search result") {
        window(
          AppFeature.State(
            isSignedIn: true, selection: .dataType("HKQuantityTypeIdentifierHeartRate"),
            searchText: "heart"))
      },
      CatalogState("Search without results") {
        window(AppFeature.State(isSignedIn: true, searchText: "xylophone"))
      },
    ])

  /// Signed out of staging, as a Debug build is, with Google sign-in (the tests have no client ID),
  /// whatever `LIL_API_URL` says.
  private func signedOut() -> AppFeature.State {
    var state = AppFeature.State(isSignedIn: false)
    state.signIn.isTestAccountAvailable = false
    state.signIn.authorization.isGoogleAvailable = true
    state.signIn.authorization.appleWebAPI = URL(string: "https://api.staging.lil.tech")
    return state
  }

  /// The window in a state: `EmptyReducer` never runs the window's task, which would replace the
  /// state with the real session's. Health Categories is expanded, in a value of the state's own,
  /// so it's never read from defaults. Signed in, the account has the welcome seed's cards, as
  /// once synced, since the task that reads them doesn't run either.
  @MainActor
  private func window(_ state: AppFeature.State) -> some View {
    var state = state
    if state.isSignedIn == true { state.cards = CardsFeature.State(cards: seedCards) }
    state.$isCategoriesExpanded = Shared(value: true)
    return AppView(store: Store(initialState: state) { EmptyReducer() })
  }

  /// The sidebar's rows on their own, in the list's own style: the sidebar's draws the selection
  /// black off screen, and the search the sidebar adds would go in a toolbar outside a split
  /// view, whose glass button draws differently from run to run.
  @MainActor
  private func sidebar(
    selection: SidebarItem = .summary, categoriesExpanded: Bool
  ) -> some View {
    sidebar(sidebarState(selection: selection, categoriesExpanded: categoriesExpanded))
  }

  @MainActor
  private func sidebar(_ state: AppFeature.State) -> some View {
    SidebarList(store: Store(initialState: state) { EmptyReducer() })
  }

  /// Signed in, with Health Categories expanded or not in a value of the state's own, so the
  /// sidebar never reads it from defaults.
  private func sidebarState(selection: SidebarItem, categoriesExpanded: Bool) -> AppFeature.State {
    let state = AppFeature.State(isSignedIn: true, selection: selection)
    state.$isCategoriesExpanded = Shared(value: categoriesExpanded)
    return state
  }

  /// A store that has opened a page, as an intent does.
  @MainActor
  private func opened(_ page: HealthPage, in state: AppFeature.State) -> StoreOf<AppFeature> {
    let store = Store(initialState: state) { AppFeature() }
    store.send(.pageOpened(page))
    return store
  }
#endif
