import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

// Synthetic data only (AGENTS.md): `makePreviewHealthDatabase()`.

@MainActor
private func detail(
  _ id: String, _ range: ChartRange, state: ((HealthDataType) -> MetricDetailContent.State)? = nil
) -> some View {
  let type = HealthCatalog.type(id: id)!
  let loaded = state?(type) ?? .loaded(previewChart(type, range))
  return NavigationStack {
    MetricDetailContent(type: type, range: .constant(range), offset: .constant(0), state: loaded)
  }
  .frame(width: 760, height: 820)
}

@MainActor
private func previewChart(_ type: HealthDataType, _ range: ChartRange) -> MetricChart {
  let database = makePreviewHealthDatabase()
  return try! database.read { db in
    try HealthDatabase.metricChart(
      of: type, range: range, offset: 0, now: .now, calendar: .current, db)
  }
}

private let steps = "HKQuantityTypeIdentifierStepCount"
private let heartRate = "HKQuantityTypeIdentifierHeartRate"

#Preview("Steps, week") {
  detail(steps, .week)
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
  MetricDetailView(type: HealthCatalog.type(id: "HKWorkoutTypeIdentifier")!)
    .frame(width: 760, height: 400)
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
