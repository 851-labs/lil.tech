#if os(macOS)
  import Foundation
  import HealthDatabase
  @testable import HealthPages
  import SwiftUI
  import Testing

  // Beat-to-beat measurements (`HeartbeatSeriesContent`) and a measurement's beats
  // (`HeartbeatSeriesDetailView`): made-up beats before `previewNow`. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: heartbeatSeriesCatalog.selectedStates)
    func heartbeatSeries(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let heartbeatSeriesCatalog = StateCatalog(
    "Heartbeat Series", width: 620, minHeight: 520,
    states: [
      CatalogState("Beat-to-beat measurements") { list(.loaded(measurements)) },
      CatalogState("Measurements, at the limit") {
        list(.loaded(Array(measurements.prefix(2))), limit: 2)
      },
      CatalogState("No measurements") { list(.loaded([])) },
      CatalogState("Measurements loading") { list(.loading) },
      CatalogState("Measurements failed") { list(.failed("The database couldn't be read.")) },
      // A measurement.
      CatalogState("A minute of beats", width: 760) { detail(measurements[0]) },
      CatalogState("Beats with a gap", width: 760) { detail(measurements[1]) },
      CatalogState("Too few beats", width: 760) {
        let start = previewNow.addingTimeInterval(-10_000).unixMilliseconds
        detail(
          HealthHeartbeatSeries(
            id: "6f1c2a40-0000-4000-8000-000000000009", startDate: start,
            endDate: start + 1_000, beats: "[0]", gaps: "[]", sourceName: "Apple Watch",
            sourceBundleID: "com.apple.health"))
      },
    ])

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
    let start = previewNow.addingTimeInterval(-hoursAgo * 3_600).unixMilliseconds
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
  private func list(
    _ state: HeartbeatSeriesContent.State, limit: Int = RecentHeartbeatSeries.limit
  ) -> some View {
    NavigationStack {
      HeartbeatSeriesContent(state: state, limit: limit)
    }
  }

  @MainActor
  private func detail(_ series: HealthHeartbeatSeries) -> some View {
    NavigationStack {
      HeartbeatSeriesDetailView(series: series)
    }
  }
#endif
