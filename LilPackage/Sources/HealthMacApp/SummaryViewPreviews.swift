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
private func summary(
  pins: [String], _ state: SummaryContent.State<[MetricSummary]>,
  highlights: SummaryContent.State<[Highlight]> = .loaded([])
) -> some View {
  NavigationStack {
    SummaryContent(pins: pins, state: state, highlights: highlights, edit: {}, pin: { _ in })
  }
  .previewFrame(width: 760, height: 1100)
}

/// The preview database's week highlights (two weeks of data), and a made-up trend.
@MainActor
private func previewHighlights() -> [Highlight] {
  let weeks =
    (try? makePreviewHealthDatabase().read { db in
      try HealthDatabase.highlights(now: .now, calendar: .current, db)
    }) ?? []
  let start = Calendar.current.date(byAdding: .weekOfYear, value: -16, to: .now) ?? .now
  let trend = Highlight(
    typeID: "HKQuantityTypeIdentifierRestingHeartRate", kind: .trend, current: 58, previous: 66,
    recentStart: Calendar.current.date(byAdding: .weekOfYear, value: 12, to: start) ?? start,
    points: (0..<16).map { week in
      DailyValue(
        day: Calendar.current.date(byAdding: .weekOfYear, value: week, to: start) ?? start,
        value: week < 12 ? 66 + Double(week % 3) - 1 : 58 + Double(week % 2))
    })
  return [trend] + weeks.prefix(2)
}

@MainActor
private func previewSummaries(_ ids: [String]) -> [MetricSummary] {
  (try? makePreviewHealthDatabase().read { db in try PinnedSummaries(ids: ids).fetch(db) }) ?? []
}

#Preview("Pinned") {
  summary(pins: pinned, .loaded(previewSummaries(pinned)), highlights: .loaded(previewHighlights()))
}

#Preview("Nothing pinned") {
  summary(pins: [], .loaded([]))
}

#Preview("Loading") {
  summary(pins: pinned, .loading, highlights: .loading)
}

#Preview("Failed") {
  summary(
    pins: pinned, .failed("The database couldn't be read."),
    highlights: .failed("The database couldn't be read."))
}

#Preview("Edit") {
  PinEditor(
    store: Store(initialState: SummaryFeature.State(pins: Array(pinned.prefix(3)), isEditing: true))
    {
      SummaryFeature()
    })
}

#Preview("Edit, searching") {
  var state = SummaryFeature.State(pins: Array(pinned.prefix(3)), isEditing: true)
  state.search = "heart"
  return PinEditor(store: Store(initialState: state) { SummaryFeature() })
}
