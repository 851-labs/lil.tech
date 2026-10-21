import HealthDatabase
import HealthUI
import SQLiteData
import SwiftUI

// Synthetic data only (AGENTS.md): the preview database's readings, through the page's own query.

@MainActor
private func chart(_ range: ChartRange) -> BloodPressureChart {
  try! makePreviewHealthDatabase().read { db in
    try HealthDatabase.bloodPressureChart(
      range: range, offset: 0, now: .now, calendar: .current, db)
  }
}

@MainActor
private func bloodPressure(_ range: ChartRange, _ state: BloodPressureContent.State) -> some View {
  preparePreviewDatabase()
  return NavigationStack {
    BloodPressureContent(range: .constant(range), offset: .constant(0), state: state)
  }
  .previewFrame(width: 760, height: 900)
}

#Preview("Blood pressure, week") {
  bloodPressure(.week, .loaded(chart(.week)))
}

#Preview("Blood pressure, month") {
  bloodPressure(.month, .loaded(chart(.month)))
}

#Preview("Blood pressure, year") {
  bloodPressure(.year, .loaded(chart(.year)))
}

// A reading without its diastolic: a point, and "–" in its place.
#Preview("A reading missing a value") {
  let interval = ChartRange.week.interval(offset: 0, now: .now, calendar: .current)
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

#Preview("No blood pressure") {
  bloodPressure(
    .week,
    .loaded(
      BloodPressureChart(
        interval: ChartRange.week.interval(offset: 0, now: .now, calendar: .current), points: [],
        readings: [])))
}

#Preview("Blood pressure loading") {
  bloodPressure(.week, .loading)
}

#Preview("Blood pressure failed") {
  bloodPressure(.week, .failed("The database couldn't be read."))
}
