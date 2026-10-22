#if os(macOS)
  import ComposableArchitecture
  import HealthCatalog
  import HealthDatabase
  @testable import HealthMacApp
  import HealthPages
  import SQLiteData
  import SwiftUI
  import Testing

  // Summary (`SummaryContent`): the pinned metrics' cards and highlights, from the catalog
  // database at `previewNow`, its pin editor, and highlight cards with made-up values. Synthetic
  // data only.

  extension MacSnapshotTests {
    @Test(arguments: summaryCatalog.selectedStates)
    func summary(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let summaryCatalog = StateCatalog(
    "Summary", width: 760, minHeight: 1100,
    states: [
      CatalogState("Pinned") {
        summary(pins: pinned, .loaded(pinnedSummaries(pinned)), highlights: .loaded(highlights()))
      },
      CatalogState("Nothing pinned") { summary(pins: [], .loaded([])) },
      CatalogState("Loading") { summary(pins: pinned, .loading, highlights: .loading) },
      CatalogState("Failed") {
        summary(
          pins: pinned, .failed("The database couldn't be read."),
          highlights: .failed("The database couldn't be read."))
      },
      // Wider than the sheet's 420 points, so its search field shows whole: narrower, it folds
      // into a toolbar button whose glyph only sometimes draws offscreen.
      CatalogState("Edit", width: 640, minHeight: 520) { pinEditor() },
      CatalogState("Edit, searching", width: 420, minHeight: 520) { pinEditor(search: "heart") },
      // About the same, up a lot, and down to almost nothing, in a narrow column, where the bars'
      // names used to run into the bar above (851-2824).
      CatalogState("Week comparisons", width: 360, minHeight: 640) {
        ScrollView {
          VStack(spacing: 12) {
            weekHighlight("HKQuantityTypeIdentifierRestingHeartRate", current: 61, previous: 60)
            weekHighlight("HKQuantityTypeIdentifierStepCount", current: 12_480, previous: 4_210)
            weekHighlight("HKQuantityTypeIdentifierActiveEnergyBurned", current: 12, previous: 640)
          }
          .padding(16)
        }
        .background(Color.pageBackground)
      },
    ])

  private let pinned = [
    "HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate",
    "HKQuantityTypeIdentifierActiveEnergyBurned", "HKCategoryTypeIdentifierSleepAnalysis",
    // No data in the catalog database.
    "HKDataTypeIdentifierElectrocardiogram",
  ]

  /// The pin editor, with three pins.
  @MainActor
  private func pinEditor(search: String = "") -> some View {
    var state = SummaryFeature.State(pins: Array(pinned.prefix(3)), isEditing: true)
    state.search = search
    return PinEditor(store: Store(initialState: state) { SummaryFeature() })
  }

  /// Summary in a navigation stack, for its title.
  @MainActor
  private func summary(
    pins: [String], _ state: SummaryContent.State<[MetricSummary]>,
    highlights: SummaryContent.State<[Highlight]> = .loaded([])
  ) -> some View {
    NavigationStack {
      SummaryContent(pins: pins, state: state, highlights: highlights, edit: {}, pin: { _ in })
    }
  }

  private func pinnedSummaries(_ ids: [String]) -> [MetricSummary] {
    try! catalogDatabase.read { db in
      try ids.compactMap(HealthCatalog.type(id:)).map {
        try HealthDatabase.metricSummary(of: $0, now: previewNow, calendar: previewCalendar, db)
      }
    }
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
    HighlightCard(
      highlight: Highlight(
        typeID: typeID, kind: .week, current: current, previous: previous,
        recentStart: previewNow),
      type: HealthCatalog.type(id: typeID)!)
  }
#endif
