#if os(macOS)
  import HealthCatalog
  import HealthDatabase
  @testable import HealthMacApp
  import SQLiteData
  import SwiftUI
  import Testing

  // Metric Detail, the Mac's chart page (`MetricDetailView`): its states, from the catalog
  // database at `previewNow`, and made-up overlays, sound levels and category values. Synthetic
  // data only.

  extension MacSnapshotTests {
    @Test(arguments: metricDetailCatalog.selectedStates)
    func metricDetail(_ state: CatalogState) {
      // So a page the detail opens, which fetches when it appears (Health Details, for a
      // characteristic), shows its first value, as in `WindowCatalog`. Charts load in a `.task`,
      // and states give them theirs.
      withDependencies {
        $0.fetchesFirstValueAtOnce = true
      } operation: {
        state.assertMacSnapshots()
      }
    }
  }

  let metricDetailCatalog = StateCatalog(
    "Metric Detail", width: 760, minHeight: 820,
    states: [
      CatalogState("Steps, week") { detail(steps, .week) },
      // Today and the next week are available (851-2821).
      CatalogState("Steps, the week before") { detail(steps, .week, offset: -1) },
      CatalogState("Steps, day") { detail(steps, .day) },
      CatalogState("Heart rate, month") { detail(heartRate, .month) },
      CatalogState("Heart rate, day") { detail(heartRate, .day) },
      // Two weeks of data: the last bars.
      CatalogState("Steps, 6 months") { detail(steps, .sixMonths) },
      CatalogState("Heart rate, year") { detail(heartRate, .year) },
      // A characteristic, a single value with no chart: Health Details, which shows it with the
      // others (851-3026).
      // In a stack, as the app shows it, so Vision Prescriptions' link is enabled.
      CatalogState("A characteristic", minHeight: 400) {
        NavigationStack {
          MetricDetailView(
            type: HealthCatalog.type(id: "HKCharacteristicTypeIdentifierBloodType")!)
        }
      },
      CatalogState("No data") {
        detail(
          "HKQuantityTypeIdentifierBodyMass", .week,
          chart: MetricChart(
            interval: ChartRange.week.interval(
              offset: 0, now: previewNow, calendar: previewCalendar),
            points: [], summary: nil))
      },
      CatalogState("Loading") { detail(steps, .week, state: .loading) },
      // ‹ pressed: this week stays, with a spinner, until the week before loads (851-3084).
      CatalogState("Steps, loading the week before") {
        detail(
          steps, .week, offset: -1,
          state: .loaded(
            PeriodChart(range: .week, offset: 0, chart: storedChart(steps, .week)), isUpdating: true
          ))
      },
      // M pressed: the week stays until the month loads.
      CatalogState("Steps, loading the month") {
        detail(
          steps, .month,
          state: .loaded(
            PeriodChart(range: .week, offset: 0, chart: storedChart(steps, .week)), isUpdating: true
          ))
      },
      // Before its lines load, or in a period without them, the legend's row stays.
      CatalogState("Heart rate, loading", minHeight: 720) {
        detail(heartRate, .week, offset: -1, state: .loading)
      },
      CatalogState("Failed") {
        detail(steps, .week, state: .failed("The database couldn't be read."))
      },
      CatalogState("Heart rate with resting and walking", minHeight: 720) {
        heartRateWithOverlays()
      },
      CatalogState("Heart rate, lines loading", minHeight: 720) {
        heartRateWithOverlays(overlays: false)
      },
      CatalogState("Environmental sound levels, week", minHeight: 720) { soundLevels() },
      // Heart rate variability also links to the beat-to-beat measurements: three rows.
      CatalogState("Heart rate variability, week") {
        detail("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", .week)
      },
      // Category types charted like metrics (851-2831).
      CatalogState("Stand hours, day") {
        // Stood most hours from 7 AM to 7 PM.
        let hours = (0..<24).map { (7...19).contains($0) && $0 != 13 && $0 != 16 ? 1.0 : 0 }
        categoryChart(
          HealthDatabase.standHourType, .day, values: hours, summary: .total(hours.reduce(0, +)))
      },
      CatalogState("Mindful minutes, week") {
        categoryChart(
          HealthDatabase.mindfulSessionType, .week, values: [10, 0, 15, 5, 20, 0, 12],
          summary: .dailyAverage(12.4))
      },
      CatalogState("Handwashing, month") {
        categoryChart(
          HealthDatabase.handwashingType, .month,
          values: (0..<20).map { Double(4 + ($0 * 7) % 6) }, summary: .averageDuration(23))
      },
      CatalogState("Toothbrushing, year") {
        categoryChart(
          HealthDatabase.toothbrushingType, .year,
          values: [1.8, 1.9, 2, 1.7, 2, 1.9, 2, 2, 1.6, 1.8], summary: .averageDuration(118))
      },
    ],
    // What's below the chart stays put while it loads, and whatever the period shows (851-3084).
    // Heart rate keeps a row for its lines' legend.
    sameLayout: [
      [
        "Steps, week", "Loading", "Steps, loading the week before", "Steps, loading the month",
        "Steps, the week before", "Steps, day", "Steps, 6 months", "No data", "Failed",
        "Environmental sound levels, week", "Stand hours, day", "Mindful minutes, week",
        "Handwashing, month", "Toothbrushing, year",
      ],
      [
        "Heart rate with resting and walking", "Heart rate, loading", "Heart rate, lines loading",
        "Heart rate, month", "Heart rate, day", "Heart rate, year",
      ],
    ])

  private let steps = "HKQuantityTypeIdentifierStepCount"
  private let heartRate = HealthDatabase.heartRateType

  /// The detail of a type, in a navigation stack for its title and toolbar: its chart for the
  /// period, from the catalog database unless given one, or the state given.
  @MainActor
  private func detail(
    _ id: String, _ range: ChartRange, offset: Int = 0, chart: MetricChart? = nil,
    state: MetricDetailContent.State? = nil, overlays: [MetricOverlay] = []
  ) -> some View {
    let type = HealthCatalog.type(id: id)!
    let loaded = PeriodChart(
      range: range, offset: offset, chart: chart ?? storedChart(id, range, offset: offset))
    return NavigationStack {
      MetricDetailContent(
        type: type, range: .constant(range), offset: .constant(offset),
        state: state ?? .loaded(loaded), overlays: overlays)
    }
  }

  private func storedChart(_ id: String, _ range: ChartRange, offset: Int = 0) -> MetricChart {
    let type = HealthCatalog.type(id: id)!
    return try! catalogDatabase.read { db in
      try HealthDatabase.metricChart(
        of: type, range: range, offset: offset, now: previewNow, calendar: previewCalendar, db)
    }
  }

  /// Last week's heart rate (the data's two weeks end today), with made-up daily averages for
  /// resting and walking, unless they're still loading.
  @MainActor
  private func heartRateWithOverlays(overlays: Bool = true) -> some View {
    let chart = storedChart(heartRate, .week, offset: -1)
    let resting = MetricOverlay(
      name: "Resting", color: .blue,
      points: chart.points.enumerated().map { index, point in
        ChartPoint(start: point.start, value: 56 + Double(index % 3))
      }, range: .week, offset: -1)
    let walking = MetricOverlay(
      name: "Walking Average", color: .orange,
      points: chart.points.enumerated().map { index, point in
        ChartPoint(start: point.start, value: 96 + Double((index * 5) % 9))
      }, range: .week, offset: -1)
    return detail(
      heartRate, .week, offset: -1, chart: chart, overlays: overlays ? [resting, walking] : [])
  }

  /// A week of daily ranges, two days loud.
  @MainActor
  private func soundLevels() -> some View {
    let calendar = previewCalendar
    let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_400_000))
    let days = (0..<7).map { calendar.date(byAdding: .day, value: $0 - 6, to: today)! }
    let ranges: [(Double, Double)] = [
      (42, 71), (45, 86), (40, 68), (38, 74), (44, 91), (41, 66), (39, 70),
    ]
    let points = zip(days, ranges).map { day, range in
      ChartPoint(start: day, value: (range.0 + range.1) / 2, minimum: range.0, maximum: range.1)
    }
    let chart = MetricChart(
      interval: DateInterval(
        start: days[0], end: calendar.date(byAdding: .day, value: 1, to: today)!),
      points: points, summary: .range(minimum: 38, maximum: 91))
    return detail(
      "HKQuantityTypeIdentifierEnvironmentalAudioExposure", .week, chart: chart)
  }

  /// A category type's chart from made-up values, one per bar from the period's start.
  @MainActor
  private func categoryChart(
    _ id: String, _ range: ChartRange, values: [Double], summary: MetricChart.Summary?
  ) -> some View {
    let interval = range.interval(offset: 0, now: previewNow, calendar: previewCalendar)
    let points = values.enumerated().compactMap { index, value -> ChartPoint? in
      guard value > 0,
        let start = previewCalendar.date(byAdding: range.barUnit, value: index, to: interval.start)
      else { return nil }
      return ChartPoint(start: start, value: value)
    }
    return detail(
      id, range, chart: MetricChart(interval: interval, points: points, summary: summary))
  }
#endif
