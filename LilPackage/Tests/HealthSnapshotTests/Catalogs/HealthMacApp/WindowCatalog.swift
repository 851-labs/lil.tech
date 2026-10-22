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
      CatalogState("Health Details") {
        window(AppFeature.State(isSignedIn: true, selection: .healthDetails))
      },
      CatalogState("A category") {
        window(AppFeature.State(isSignedIn: true, selection: .category(.heart)))
      },
      // Its icon is two-tone, and goes wholly white on the key window's selection (851-2823).
      CatalogState("A two-tone category") {
        window(AppFeature.State(isSignedIn: true, selection: .category(.medications)))
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
      CatalogState("Search results") {
        window(AppFeature.State(isSignedIn: true, searchText: "heart"))
      },
      CatalogState("A search result") {
        window(
          AppFeature.State(
            isSignedIn: true, selection: .dataType("HKQuantityTypeIdentifierHeartRate"),
            searchText: "heart"))
      },
      // Health Details' characteristics first, as in the sidebar, and one opens Health Details
      // (851-3026).
      CatalogState("A characteristic found by search") {
        window(
          AppFeature.State(
            isSignedIn: true, selection: .dataType("HKCharacteristicTypeIdentifierBloodType"),
            searchText: "blood"))
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
  /// state with the real session's.
  @MainActor
  private func window(_ state: AppFeature.State) -> some View {
    AppView(store: Store(initialState: state) { EmptyReducer() })
  }
#endif
