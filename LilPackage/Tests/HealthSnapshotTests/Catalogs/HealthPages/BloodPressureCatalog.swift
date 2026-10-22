#if os(macOS)
  import HealthDatabase
  @testable import HealthPages
  import SQLiteData
  import SwiftUI
  import Testing

  // Blood Pressure (`BloodPressureContent`): the catalog database's readings, through the page's
  // own query, and a made-up reading. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: bloodPressureCatalog.selectedStates)
    func bloodPressure(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let bloodPressureCatalog = StateCatalog(
    "Blood Pressure", width: 760, minHeight: 900,
    states: [
      CatalogState("Blood pressure, week") { bloodPressure(.week, .loaded(chart(.week))) },
      CatalogState("Blood pressure, month") { bloodPressure(.month, .loaded(chart(.month))) },
      CatalogState("Blood pressure, year") { bloodPressure(.year, .loaded(chart(.year))) },
      // A reading without its diastolic: a point, and "–" in its place.
      CatalogState("A reading missing a value") { readingMissingAValue() },
      CatalogState("No blood pressure") {
        bloodPressure(
          .week,
          .loaded(
            BloodPressureChart(
              interval: ChartRange.week.interval(
                offset: 0, now: previewNow, calendar: previewCalendar),
              points: [], readings: [])))
      },
      CatalogState("Blood pressure loading") { bloodPressure(.week, .loading) },
      CatalogState("Blood pressure failed") {
        bloodPressure(.week, .failed("The database couldn't be read."))
      },
    ])

  private func chart(_ range: ChartRange) -> BloodPressureChart {
    try! catalogDatabase.read { db in
      try HealthDatabase.bloodPressureChart(
        range: range, offset: 0, now: previewNow, calendar: previewCalendar, db)
    }
  }

  @MainActor
  private func bloodPressure(_ range: ChartRange, _ state: BloodPressureContent.State)
    -> some View
  {
    NavigationStack {
      BloodPressureContent(range: .constant(range), offset: .constant(0), state: state)
    }
  }

  @MainActor
  private func readingMissingAValue() -> some View {
    let interval = ChartRange.week.interval(offset: 0, now: previewNow, calendar: previewCalendar)
    let reading = BloodPressureReading(
      id: "synthetic", date: interval.start.addingTimeInterval(30 * 3600), systolic: 133,
      diastolic: nil, sourceName: "Synthetic Cuff")
    return bloodPressure(
      .week,
      .loaded(
        BloodPressureChart(
          interval: interval,
          points: [
            BloodPressurePoint(
              start: reading.date, systolic: 133...133, diastolic: nil, readings: [reading])
          ],
          readings: [reading])))
  }
#endif
