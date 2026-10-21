import ComposableArchitecture
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import LilSync
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md).

@MainActor
private func appView(
  _ state: AppFeature.State, width: CGFloat = 960, height: CGFloat = 640
) -> some View {
  preparePreviewDatabase()
  var state = state
  // No pins, read: `EmptyReducer` never runs Summary's task to read them.
  state.summary = SummaryFeature.State(pins: [])
  // `EmptyReducer`: the view's task would replace the state with the real session's.
  return AppView(store: Store(initialState: state) { EmptyReducer() })
    .previewFrame(width: width, height: height)
}

#Preview("Launching") {
  appView(AppFeature.State())
}

#Preview("Signed out") {
  appView(AppFeature.State(isSignedIn: false))
}

#Preview("Summary") {
  appView(
    AppFeature.State(isSignedIn: true, syncStatus: .upToDate(at: .now.addingTimeInterval(-120))))
}

#Preview("First sync") {
  appView(
    AppFeature.State(
      isSignedIn: true, syncStatus: .bootstrapping(downloadedParts: 12, totalParts: 80)))
}

#Preview("Health Details") {
  appView(AppFeature.State(isSignedIn: true, selection: .healthDetails))
}

#Preview("A category") {
  appView(AppFeature.State(isSignedIn: true, selection: .category(.heart)))
}

// Its icon is two-tone, and goes wholly white on the key window's selection (851-2823).
#Preview("A two-tone category") {
  appView(AppFeature.State(isSignedIn: true, selection: .category(.medications)))
}

// A metric's range and periods are in the toolbar (851-2821).
#Preview("A metric") {
  appView(
    AppFeature.State(isSignedIn: true, selection: .dataType("HKQuantityTypeIdentifierStepCount")))
}

// Sleep's range and nights are in the toolbar too (851-2866).
#Preview("Sleep") {
  appView(
    AppFeature.State(isSignedIn: true, selection: .dataType(HealthDatabase.sleepType)))
}

// The window at its smallest, where the toolbar is most crowded and the sidebar's last rows go
// under its footer (851-2867).
#Preview("A metric, smallest window") {
  appView(
    AppFeature.State(
      isSignedIn: true,
      selection: .dataType("HKQuantityTypeIdentifierDistanceWalkingRunning")),
    width: 800, height: 480)
}

// The footer at its tallest, with its progress bar, over the rows of a short window (851-2867).
#Preview("First sync, smallest window") {
  appView(
    AppFeature.State(
      isSignedIn: true, syncStatus: .bootstrapping(downloadedParts: 12, totalParts: 80)),
    width: 800, height: 480)
}

#Preview("Search results") {
  appView(AppFeature.State(isSignedIn: true, searchText: "heart"))
}

#Preview("A search result") {
  appView(
    AppFeature.State(
      isSignedIn: true, selection: .dataType("HKQuantityTypeIdentifierHeartRate"),
      searchText: "heart"))
}

#Preview("Search without results") {
  appView(AppFeature.State(isSignedIn: true, searchText: "xylophone"))
}
