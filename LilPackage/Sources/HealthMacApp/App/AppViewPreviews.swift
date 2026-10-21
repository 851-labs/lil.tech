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
private func appView(_ state: AppFeature.State) -> some View {
  preparePreviewDatabase()
  var state = state
  // No pins, read: `EmptyReducer` never runs Summary's task to read them.
  state.summary = SummaryFeature.State(pins: [])
  // `EmptyReducer`: the view's task would replace the state with the real session's.
  return AppView(store: Store(initialState: state) { EmptyReducer() })
    .previewFrame(width: 960, height: 640)
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

#Preview("A category") {
  appView(AppFeature.State(isSignedIn: true, selection: .category(.heart)))
}

#Preview("Search results") {
  appView(AppFeature.State(isSignedIn: true, searchText: "heart"))
}

#Preview("Search without results") {
  appView(AppFeature.State(isSignedIn: true, searchText: "xylophone"))
}
