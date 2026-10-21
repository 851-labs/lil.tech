import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import SQLiteData
import SwiftUI

// Synthetic data only (AGENTS.md): `makePreviewHealthDatabase()`, and made-up overlays and sound
// levels.

@MainActor
private func detail(
  _ id: String, _ range: ChartRange, offset: Int = 0,
  state: ((HealthDataType) -> MetricDetailContent.State)? = nil
) -> some View {
  preparePreviewDatabase()
  let type = HealthCatalog.type(id: id)!
  let loaded = state?(type) ?? .loaded(previewChart(type, range, offset: offset))
  return NavigationStack {
    MetricDetailContent(
      type: type, range: .constant(range), offset: .constant(offset), state: loaded)
  }
  .previewFrame(width: 760, height: 820)
}

@MainActor
private func previewChart(
  _ type: HealthDataType, _ range: ChartRange, offset: Int = 0
) -> MetricChart {
  let database = makePreviewHealthDatabase()
  return try! database.read { db in
    try HealthDatabase.metricChart(
      of: type, range: range, offset: offset, now: .now, calendar: .current, db)
  }
}

private let steps = "HKQuantityTypeIdentifierStepCount"
private let heartRate = "HKQuantityTypeIdentifierHeartRate"

#Preview("Steps, week") {
  detail(steps, .week)
}

// Today and the next week are available (851-2821).
#Preview("Steps, the week before") {
  detail(steps, .week, offset: -1)
}

#Preview("Steps, day") {
  detail(steps, .day)
}

#Preview("Heart rate, month") {
  detail(heartRate, .month)
}

#Preview("Heart rate, day") {
  detail(heartRate, .day)
}

#Preview("Steps, 6 months") {
  // Two weeks of preview data: the last bars.
  detail(steps, .sixMonths)
}

#Preview("Heart rate, year") {
  detail(heartRate, .year)
}

#Preview("Not a quantity") {
  // A characteristic, which won't get a chart: the fallback's preview went stale once workouts got
  // their own screen (851-2708).
  let _ = preparePreviewDatabase()
  MetricDetailView(type: HealthCatalog.type(id: "HKCharacteristicTypeIdentifierBloodType")!)
    .previewFrame(width: 760, height: 400)
}

#Preview("No data") {
  detail(
    "HKQuantityTypeIdentifierBodyMass", .week,
    state: { _ in
      .loaded(
        MetricChart(
          interval: ChartRange.week.interval(offset: 0, now: .now, calendar: .current),
          points: [], summary: nil))
    })
}

#Preview("Loading") {
  detail(steps, .week, state: { _ in .loading })
}

#Preview("Failed") {
  detail(steps, .week, state: { _ in .failed("The database couldn't be read.") })
}

#Preview("Heart rate with resting and walking") {
  preparePreviewDatabase()
  let type = HealthCatalog.type(id: HealthDatabase.heartRateType)!
  let chart = try! makePreviewHealthDatabase().read { db in
    // Last week: the preview data's two weeks end today.
    try HealthDatabase.metricChart(
      of: type, range: .week, offset: -1, now: .now, calendar: .current, db)
  }
  // Made-up daily averages for the same week.
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
  return NavigationStack {
    MetricDetailContent(
      type: type, range: .constant(.week), offset: .constant(-1), state: .loaded(chart),
      overlays: [resting, walking])
  }
  .previewFrame(width: 760, height: 720)
}

#Preview("Environmental sound levels, week") {
  preparePreviewDatabase()
  // A week of daily ranges, two days loud.
  let calendar = Calendar.current
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
  return NavigationStack {
    MetricDetailContent(
      type: HealthCatalog.type(id: "HKQuantityTypeIdentifierEnvironmentalAudioExposure")!,
      range: .constant(.week), offset: .constant(0), state: .loaded(chart))
  }
  .previewFrame(width: 760, height: 720)
}

// Category types charted like metrics (851-2831), from made-up values.

@MainActor
private func categoryChart(
  _ id: String, _ range: ChartRange, values: [Double], summary: MetricChart.Summary?
) -> some View {
  let calendar = Calendar.current
  let interval = range.interval(offset: 0, now: .now, calendar: calendar)
  let points = values.enumerated().compactMap { index, value -> ChartPoint? in
    guard value > 0,
      let start = calendar.date(byAdding: range.barUnit, value: index, to: interval.start)
    else { return nil }
    return ChartPoint(start: start, value: value)
  }
  return detail(
    id, range,
    state: { _ in .loaded(MetricChart(interval: interval, points: points, summary: summary)) })
}

#Preview("Stand hours, day") {
  // Stood most hours from 7 AM to 7 PM.
  let hours = (0..<24).map { (7...19).contains($0) && $0 != 13 && $0 != 16 ? 1.0 : 0 }
  categoryChart(
    HealthDatabase.standHourType, .day, values: hours, summary: .total(hours.reduce(0, +)))
}

#Preview("Mindful minutes, week") {
  categoryChart(
    HealthDatabase.mindfulSessionType, .week, values: [10, 0, 15, 5, 20, 0, 12],
    summary: .dailyAverage(12.4))
}

#Preview("Handwashing, month") {
  categoryChart(
    HealthDatabase.handwashingType, .month,
    values: (0..<20).map { Double(4 + ($0 * 7) % 6) }, summary: .averageDuration(23))
}

#Preview("Toothbrushing, year") {
  categoryChart(
    HealthDatabase.toothbrushingType, .year,
    values: [1.8, 1.9, 2, 1.7, 2, 1.9, 2, 2, 1.6, 1.8], summary: .averageDuration(118))
}
