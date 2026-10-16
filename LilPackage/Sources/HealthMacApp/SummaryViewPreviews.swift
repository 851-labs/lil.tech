import ComposableArchitecture
import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only: `makePreviewHealthDatabase()`.

private let pinned = [
  "HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate",
  "HKQuantityTypeIdentifierActiveEnergyBurned", "HKCategoryTypeIdentifierSleepAnalysis",
  // No data in the preview database.
  "HKDataTypeIdentifierElectrocardiogram",
]

@MainActor
private func summary(pins: [String], _ state: SummaryContent.State) -> some View {
  NavigationStack {
    SummaryContent(pins: pins, state: state, edit: {}, pin: { _ in })
  }
  .frame(width: 760, height: 720)
}

@MainActor
private func previewSummaries(_ ids: [String]) -> [MetricSummary] {
  (try? makePreviewHealthDatabase().read { db in try PinnedSummaries(ids: ids).fetch(db) }) ?? []
}

#Preview("Pinned") {
  summary(pins: pinned, .loaded(previewSummaries(pinned)))
}

#Preview("Nothing pinned") {
  summary(pins: [], .loaded([]))
}

#Preview("Loading") {
  summary(pins: pinned, .loading)
}

#Preview("Failed") {
  summary(pins: pinned, .failed("The database couldn't be read."))
}

#Preview("Edit") {
  let state = SummaryFeature.State(isEditing: true)
  state.$pins.withLock { $0 = Array(pinned.prefix(3)) }
  return PinEditor(store: Store(initialState: state) { SummaryFeature() })
}

#Preview("Edit, searching") {
  var state = SummaryFeature.State(isEditing: true)
  state.search = "heart"
  return PinEditor(store: Store(initialState: state) { SummaryFeature() })
}
