#if os(macOS)
  import HealthCatalog
  import HealthDatabase
  @testable import HealthPages
  import SQLiteData
  import SwiftUI
  import Testing

  // Sleep (`SleepDetailContent`): the catalog database's nights, read as the page reads them, and
  // a made-up night without stages. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: sleepCatalog.selectedStates)
    func sleep(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let sleepCatalog = StateCatalog(
    "Sleep", width: 760, minHeight: 760,
    states: [
      CatalogState("Night") { detail(.day, .loaded(nights(.day))) },
      // Today and the next night are available (851-2866).
      CatalogState("The night before") {
        detail(.day, offset: -1, .loaded(nights(.day, offset: -1)))
      },
      // ‹ pressed: tonight stays, with a spinner, until the night before loads (851-3084).
      CatalogState("Night, loading the night before") {
        detail(.day, offset: -1, .loaded(nights(.day), isUpdating: true))
      },
      CatalogState("Week") { detail(.week, .loaded(nights(.week))) },
      CatalogState("Week, loading the week before") {
        detail(.week, offset: -1, .loaded(nights(.week), isUpdating: true))
      },
      // E.g. an iPhone's estimate, without a Watch: asleep and awake only.
      CatalogState("Night without stages") {
        let day = previewCalendar.startOfDay(for: previewNow)
        let segments = [
          SleepSegment(
            stage: .asleep, start: day.addingTimeInterval(-3600),
            end: day.addingTimeInterval(3 * 3600)),
          SleepSegment(
            stage: .awake, start: day.addingTimeInterval(3 * 3600),
            end: day.addingTimeInterval(3.3 * 3600)),
          SleepSegment(
            stage: .asleep, start: day.addingTimeInterval(3.3 * 3600),
            end: day.addingTimeInterval(6.5 * 3600)),
        ]
        detail(
          .day,
          .loaded(
            SleepPeriod(
              range: .day, lastDay: day,
              nights: [SleepNight(day: day, segments: segments, inBed: 8 * 3600)])))
      },
      CatalogState("No sleep") {
        detail(
          .day,
          .loaded(
            SleepPeriod(
              range: .day, lastDay: previewCalendar.startOfDay(for: previewNow), nights: [])))
      },
      CatalogState("Loading") { detail(.day, .loading) },
      CatalogState("Failed") { detail(.week, .failed("The database couldn't be read.")) },
    ],
    // What's below the content stays put while it loads (851-3084).
    sameLayout: [
      ["Loading", "Night", "The night before", "Night, loading the night before"],
      ["Week", "Week, loading the week before", "Failed"],
    ])

  private let sleepType = HealthCatalog.type(id: HealthDatabase.sleepType)!

  private func nights(_ range: SleepRange, offset: Int = 0) -> SleepPeriod {
    try! catalogDatabase.read { db in
      try SleepRequest(range: range, offset: offset, day: previewNow, calendar: previewCalendar)
        .fetch(db)!
    }
  }

  @MainActor
  private func detail(
    _ range: SleepRange, offset: Int = 0, _ state: SleepDetailContent.State
  ) -> some View {
    NavigationStack {
      SleepDetailContent(
        type: sleepType, range: .constant(range), offset: .constant(offset), state: state,
        now: previewNow)
    }
  }
#endif
