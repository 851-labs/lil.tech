import Foundation
import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only: made-up beats, and
// `makePreviewHealthDatabase()` for heart rate.

private let now = Date(timeIntervalSince1970: 1_760_400_000)

/// About a minute of beats around `bpm`, faster on each breath in (respiratory sinus
/// arrhythmia), with gaps before the beats in `gaps`.
private func series(
  _ index: Int, hoursAgo: Double, bpm: Double, seconds: Double = 60, gaps: [Int] = []
) -> HealthHeartbeatSeries {
  var times: [Double] = [0]
  while let last = times.last, last < seconds {
    let breathing = sin(2 * .pi * last / 5) * 0.06
    times.append(last + 60 / bpm * (1 - breathing))
  }
  let start = Int(now.addingTimeInterval(-hoursAgo * 3_600).timeIntervalSince1970 * 1000)
  let beats = times.map { String(format: "%.3f", $0) }.joined(separator: ",")
  return HealthHeartbeatSeries(
    id: "6f1c2a40-0000-4000-8000-\(String(format: "%012d", index))", startDate: start,
    endDate: start + Int(seconds * 1000), beats: "[\(beats)]", gaps: "\(gaps)",
    sourceName: "Apple Watch", sourceBundleID: "com.apple.health")
}

private let measurements = [
  series(1, hoursAgo: 1, bpm: 62),
  series(2, hoursAgo: 5, bpm: 71, gaps: [20, 21]),
  series(3, hoursAgo: 28, bpm: 58),
  series(4, hoursAgo: 30, bpm: 66),
  series(5, hoursAgo: 55, bpm: 74),
]

@MainActor
private func list(_ state: HeartbeatSeriesContent.State, limit: Int = RecentHeartbeatSeries.limit)
  -> some View
{
  NavigationStack {
    HeartbeatSeriesContent(state: state, limit: limit)
  }
  .frame(width: 620, height: 520)
}

@MainActor
private func detail(_ series: HealthHeartbeatSeries) -> some View {
  preparePreviewDatabase()
  return NavigationStack {
    HeartbeatSeriesDetailView(series: series)
  }
  .frame(width: 760, height: 640)
}

#Preview("Beat-to-beat measurements") {
  list(.loaded(measurements))
}

#Preview("Measurements, at the limit") {
  list(.loaded(Array(measurements.prefix(2))), limit: 2)
}

#Preview("No measurements") {
  list(.loaded([]))
}

#Preview("Measurements loading") {
  list(.loading)
}

#Preview("Measurements failed") {
  list(.failed("The database couldn't be read."))
}

#Preview("A minute of beats") {
  detail(measurements[0])
}

#Preview("Beats with a gap") {
  detail(measurements[1])
}

#Preview("Too few beats") {
  detail(
    HealthHeartbeatSeries(
      id: "6f1c2a40-0000-4000-8000-000000000009", startDate: 1_760_390_000_000,
      endDate: 1_760_390_001_000, beats: "[0]", gaps: "[]", sourceName: "Apple Watch",
      sourceBundleID: "com.apple.health"))
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
  .frame(width: 760, height: 720)
}
