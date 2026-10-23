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
      CatalogState("Blood pressure, week") { bloodPressure(.week, .loaded(period(.week))) },
      CatalogState("Blood pressure, month") { bloodPressure(.month, .loaded(period(.month))) },
      CatalogState("Blood pressure, year") { bloodPressure(.year, .loaded(period(.year))) },
      // M pressed: the week stays, with a spinner, until the month loads (851-3089).
      CatalogState("Blood pressure, loading the month") {
        bloodPressure(.month, .loaded(period(.week), isUpdating: true))
      },
      // A reading without its diastolic: a point, and "–" in its place.
      CatalogState("A reading missing a value") { readingMissingAValue() },
      CatalogState("No blood pressure") {
        bloodPressure(
          .week,
          .loaded(
            BloodPressurePeriod(
              range: .week,
              chart: BloodPressureChart(
                interval: ChartRange.week.interval(
                  offset: 0, now: previewNow, calendar: previewCalendar),
                points: [], readings: []))))
      },
      CatalogState("Blood pressure loading") { bloodPressure(.week, .loading) },
      CatalogState("Blood pressure failed") {
        bloodPressure(.week, .failed("The database couldn't be read."))
      },
    ],
    // The chart's section keeps its height, loading or not, so the readings below start at the
    // same place (851-3089).
    sameLayout: [
      [
        "Blood pressure, week", "Blood pressure loading", "Blood pressure, loading the month",
        "Blood pressure, month", "Blood pressure, year", "A reading missing a value",
        "No blood pressure", "Blood pressure failed",
      ]
    ])

  private func period(_ range: ChartRange) -> BloodPressurePeriod {
    try! catalogDatabase.read { db in
      BloodPressurePeriod(
        range: range,
        chart: try HealthDatabase.bloodPressureChart(
          range: range, offset: 0, now: previewNow, calendar: previewCalendar, db))
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
        BloodPressurePeriod(
          range: .week,
          chart: BloodPressureChart(
            interval: interval,
            points: [
              BloodPressurePoint(
                start: reading.date, systolic: 133...133, diastolic: nil, readings: [reading])
            ],
            readings: [reading]))))
  }
#endif
