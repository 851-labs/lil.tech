#if os(macOS)
  import HealthCatalog
  import HealthDatabase
  @testable import HealthMacApp
  import SQLiteData
  import SwiftUI
  import Testing

  // Metric Detail, the Mac's chart page (`MetricDetailView`): its states, from the catalog
  // database at `previewNow`, a year of body measurements (`measurementsDatabase`), and made-up
  // overlays, sound levels and category values. Synthetic data only.

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
      // A period without resting or walking averages: the legend's row stays.
      CatalogState("Heart rate without lines", minHeight: 720) {
        heartRateWithOverlays(overlays: false)
      },
      CatalogState("Environmental sound levels, week", minHeight: 720) { soundLevels() },
      // Heart rate variability also links to the beat-to-beat measurements: three rows. Dots of
      // each day's average (851-3097).
      CatalogState("Heart rate variability, week") {
        detail("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", .week)
      },
      // Dots, on a percent axis.
      CatalogState("Blood oxygen, month") {
        detail("HKQuantityTypeIdentifierOxygenSaturation", .month)
      },
      // Weight is a line through each period's average, on an axis fitted to it rather than
      // from 0, under its average (851-3097). This morning's reading, the only one today.
      CatalogState("Weight, day") { measurement(weight, .day) },
      // Two mornings without a reading: the line goes on over them.
      CatalogState("Weight, last week") { measurement(weight, .week, offset: -1) },
      CatalogState("Weight, month") { measurement(weight, .month) },
      // Ten days away from the scale.
      CatalogState("Weight, month with a gap") { measurement(weight, .month, offset: -1) },
      CatalogState("Weight, 6 months") { measurement(weight, .sixMonths) },
      CatalogState("Weight, year") { measurement(weight, .year) },
      // Other lines: body fat on even days' weigh-ins, on a percent axis, and every fourth day.
      CatalogState("Body fat percentage, month") { measurement(bodyFat, .month) },
      CatalogState("Cardio fitness, 6 months") { measurement(cardioFitness, .sixMonths) },
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
        "Handwashing, month", "Toothbrushing, year", "Blood oxygen, month", "Weight, day",
        "Weight, last week", "Weight, month", "Weight, month with a gap", "Weight, 6 months",
        "Weight, year", "Body fat percentage, month", "Cardio fitness, 6 months",
      ],
      [
        "Heart rate with resting and walking", "Heart rate, loading", "Heart rate without lines",
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
      range: range, offset: offset, chart: chart ?? storedChart(id, range, offset: offset),
      overlays: overlays)
    return NavigationStack {
      MetricDetailContent(
        type: type, range: .constant(range), offset: .constant(offset),
        state: state ?? .loaded(loaded))
    }
  }

  private func storedChart(
    _ id: String, _ range: ChartRange, offset: Int = 0,
    in database: any DatabaseReader = catalogDatabase
  ) -> MetricChart {
    let type = HealthCatalog.type(id: id)!
    return try! database.read { db in
      try HealthDatabase.metricChart(
        of: type, range: range, offset: offset, now: previewNow, calendar: previewCalendar, db)
    }
  }

  /// A body measurement's detail, from `measurementsDatabase`.
  @MainActor
  private func measurement(_ id: String, _ range: ChartRange, offset: Int = 0) -> some View {
    detail(
      id, range, offset: offset,
      chart: storedChart(id, range, offset: offset, in: measurementsDatabase))
  }

  private let weight = "HKQuantityTypeIdentifierBodyMass"
  private let bodyFat = "HKQuantityTypeIdentifierBodyFatPercentage"
  private let cardioFitness = "HKQuantityTypeIdentifierVO2Max"

  /// A year of synthetic body measurements up to `previewNow`, longer than the catalog database's
  /// two weeks, so 6 months and a year have something to show (851-3097). A weigh-in most
  /// mornings, drifting down from about 74 to 71 kg, with no reading ten days in July; body fat
  /// with the weigh-ins of even-numbered days; and cardio fitness every fourth day, rising.
  private let measurementsDatabase: any DatabaseWriter = {
    let calendar = previewCalendar
    let today = calendar.startOfDay(for: previewNow)
    let away = DateInterval(
      start: calendar.date(from: DateComponents(year: 2024, month: 7, day: 17))!,
      end: calendar.date(from: DateComponents(year: 2024, month: 7, day: 27))!)
    /// The same wobble in -0.5..<0.5 on every run and Mac: an integer hash of the day (SplitMix64's
    /// mixing), unlike a random generator's or one from `sin`.
    func wobble(_ day: Int, _ seed: UInt64) -> Double {
      var x = UInt64(day) &* 0x9E37_79B9_7F4A_7C15 &+ seed
      x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
      x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
      x ^= x >> 31
      return Double(x >> 11) / Double(1 << 53) - 0.5
    }
    var samples: [HealthSample] = []
    func add(_ type: String, _ unit: String, on day: Date, minutes: Int, _ value: Double) {
      let start = day.addingTimeInterval(Double(minutes) * 60)
      samples.append(
        HealthSample(
          id: "\(type)@\(start.unixMilliseconds)", type: type, startDate: start.unixMilliseconds,
          endDate: start.unixMilliseconds, value: value, unit: unit, sourceName: "iPhone",
          sourceBundleID: "com.apple.health.iphone"))
    }
    let days = 366
    for index in 0..<days {
      let day = calendar.date(byAdding: .day, value: index - days + 1, to: today)!
      // How far through the year, 0 to 1.
      let progress = Double(index) / Double(days - 1)
      if index % 4 == 1 {
        add(
          cardioFitness, "ml/(kg*min)", on: day, minutes: 18 * 60,
          38.5 + 3 * progress + 1.2 * wobble(index, 3))
      }
      // Some mornings without weighing in, and none while away.
      guard index % 7 != 3, index % 11 != 5, !away.contains(day) else { continue }
      add(
        weight, "kg", on: day, minutes: 7 * 60 + 10,
        74.2 - 3.4 * progress + 0.5 * sin(progress * 4 * .pi) + 0.7 * wobble(index, 1))
      if index % 2 == 0 {
        add(
          bodyFat, "%", on: day, minutes: 7 * 60 + 10,
          0.245 - 0.02 * progress + 0.008 * wobble(index, 2))
      }
    }
    let database = try! HealthDatabase.make()
    try! database.write { db in try HealthSample.insert { samples }.execute(db) }
    return database
  }()

  /// Last week's heart rate (the data's two weeks end today), with made-up daily averages for
  /// resting and walking, unless they're still loading.
  @MainActor
  private func heartRateWithOverlays(overlays: Bool = true) -> some View {
    let chart = storedChart(heartRate, .week, offset: -1)
    let resting = MetricOverlay(
      name: "Resting", color: .blue,
      points: chart.points.enumerated().map { index, point in
        ChartPoint(start: point.start, value: 56 + Double(index % 3))
      })
    let walking = MetricOverlay(
      name: "Walking Average", color: .orange,
      points: chart.points.enumerated().map { index, point in
        ChartPoint(start: point.start, value: 96 + Double((index * 5) % 9))
      })
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
