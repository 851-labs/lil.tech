#if os(macOS)
  import ComposableArchitecture
  import HealthCatalog
  import HealthDatabase
  @testable import HealthMacApp
  import HealthPages
  import SQLiteData
  import SwiftUI
  import Testing

  // Summary (`SummaryContent`): the everyday metrics' rows and highlights, from the catalog
  // database at `previewNow`, and highlights with made-up values. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: summaryCatalog.selectedStates)
    func summary(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let summaryCatalog = StateCatalog(
    "Summary", width: 760, minHeight: 480,
    states: [
      CatalogState("Loaded") {
        summary(.loaded(summaryMetrics()), highlights: .loaded(highlights()))
      },
      // A new account, before its iPhone has shared anything.
      CatalogState("No data") {
        summary(.loaded(HealthDatabase.summaryTypes.map { MetricSummary(id: $0) }))
      },
      CatalogState("Loading") { summary(.loading, highlights: .loading) },
      CatalogState("Failed") {
        summary(
          .failed("The database couldn't be read."),
          highlights: .failed("The database couldn't be read."))
      },
      // About the same, up a lot, and down to almost nothing, in a narrow column, where the bars'
      // names used to run into the bar above (851-2824).
      CatalogState("Week comparisons", width: 360, minHeight: 640) {
        // Links, as Summary's rows are, so the form's chevron takes its width here too.
        NavigationStack {
          Form {
            Section("Highlights") {
              weekHighlight("HKQuantityTypeIdentifierRestingHeartRate", current: 61, previous: 60)
              weekHighlight("HKQuantityTypeIdentifierStepCount", current: 12_480, previous: 4_210)
              weekHighlight(
                "HKQuantityTypeIdentifierActiveEnergyBurned", current: 12, previous: 640)
            }
          }
          .formStyle(.grouped)
        }
      },
    ])

  /// Summary in a navigation stack, for its title.
  @MainActor
  private func summary(
    _ state: SummaryContent.State<[MetricSummary]>,
    highlights: SummaryContent.State<[Highlight]> = .loaded([])
  ) -> some View {
    NavigationStack {
      SummaryContent(state: state, highlights: highlights)
    }
  }

  /// The app's request, at the suite's date and calendar.
  private func summaryMetrics() -> [MetricSummary] {
    try! catalogDatabase.read { db in try SummaryRequest().fetch(db) }
  }

  /// The catalog database's week highlights (two weeks of data), after a made-up trend.
  private func highlights() -> [Highlight] {
    let calendar = previewCalendar
    let weeks = try! catalogDatabase.read { db in
      try HealthDatabase.highlights(now: previewNow, calendar: calendar, db)
    }
    let start = calendar.date(byAdding: .weekOfYear, value: -16, to: previewNow)!
    let trend = Highlight(
      typeID: "HKQuantityTypeIdentifierRestingHeartRate", kind: .trend, current: 58, previous: 66,
      recentStart: calendar.date(byAdding: .weekOfYear, value: 12, to: start)!,
      points: (0..<16).map { week in
        DailyValue(
          day: calendar.date(byAdding: .weekOfYear, value: week, to: start)!,
          value: week < 12 ? 66 + Double(week % 3) - 1 : 58 + Double(week % 2))
      })
    return [trend] + weeks.prefix(2)
  }

  @MainActor
  private func weekHighlight(_ typeID: String, current: Double, previous: Double) -> some View {
    NavigationLink(value: typeID) {
      HighlightRow(
        highlight: Highlight(
          typeID: typeID, kind: .week, current: current, previous: previous,
          recentStart: previewNow),
        type: HealthCatalog.type(id: typeID)!)
    }
  }
#endif
