import HealthCatalog
import HealthDatabase
import HealthUI
import SQLiteData
import SwiftUI

// In their own file: previewing a file with a `List` (or a grouped `Form`, as Data Sources is) of
// `ForEach` rows trips an assertion in SwiftUI's macOS `List` (AGENTS.md). Synthetic data only: `makePreviewHealthDatabase()`.

private let heartRate = HealthCatalog.type(id: "HKQuantityTypeIdentifierHeartRate")!
private let steps = HealthCatalog.type(id: "HKQuantityTypeIdentifierStepCount")!

@MainActor
private func previewSamples(_ type: HealthDataType, limit: Int = 60) -> [HealthSample] {
  (try? makePreviewHealthDatabase().read { db in
    try HealthDatabase.samplePage(of: type.id, after: nil, limit: limit, db)
  }) ?? []
}

@MainActor
private func allData(_ type: HealthDataType, _ state: AllDataContent.State) -> some View {
  NavigationStack {
    AllDataContent(type: type, state: state, loadMore: {})
  }
  .previewFrame(width: 560, height: 620)
}

#Preview("All data") {
  allData(heartRate, .loaded(previewSamples(heartRate), hasMore: true))
}

// A day with a reading every 5 minutes, as a Watch's heart rate during a workout can have: one
// long card.
#Preview("All data, a long day") {
  // From 11:55 PM back to midnight.
  let day = Calendar.current.startOfDay(for: .now).addingTimeInterval(24 * 3600 - 300)
  let samples = (0..<288).map { index in
    let start = Int(day.timeIntervalSince1970 * 1000) - index * 300_000
    return HealthSample(
      id: "synthetic-\(index)", type: heartRate.id, startDate: start, endDate: start,
      value: Double(62 + (index * 7) % 45), unit: "count/min", sourceName: "Synthetic Watch",
      sourceBundleID: "com.example.watch")
  }
  return allData(heartRate, .loaded(samples, hasMore: false))
}

#Preview("All data, raw steps") {
  allData(steps, .loaded(previewSamples(steps), hasMore: false))
}

#Preview("All data, empty") {
  allData(heartRate, .loaded([], hasMore: false))
}

#Preview("All data, loading") {
  allData(heartRate, .loading)
}

#Preview("All data, failed") {
  allData(heartRate, .failed("The database couldn't be read."))
}

#Preview("Sample") {
  NavigationStack {
    SampleDetailView(type: heartRate, sample: previewSamples(heartRate, limit: 1)[0])
  }
  .previewFrame(width: 560, height: 620)
}

#Preview("Sample without device") {
  NavigationStack {
    SampleDetailView(
      type: steps,
      sample: HealthSample(
        id: "synthetic", type: steps.id, startDate: 1_760_400_000_000,
        endDate: 1_760_400_600_000, value: 412, unit: "count", sourceName: "Pedometer++",
        sourceBundleID: "com.example.pedometer"))
  }
  .previewFrame(width: 560, height: 360)
}

@MainActor
private func sources(_ state: DataSourcesContent.State) -> some View {
  NavigationStack {
    DataSourcesContent(type: heartRate, state: state)
  }
  .previewFrame(width: 560, height: 420)
}

#Preview("Sources") {
  let found = try! makePreviewHealthDatabase().read { db in
    try HealthDatabase.sampleSources(of: heartRate.id, db)
  }
  return sources(.loaded(found))
}

#Preview("Several sources") {
  sources(
    .loaded(
      SampleSources(
        apps: [
          SampleSource(id: "com.apple.health.watch", name: "Apple Watch", count: 48_210),
          SampleSource(id: "com.example.strap", name: "Synthetic Strap", count: 1_204),
          SampleSource(id: "com.apple.health.iphone", name: "iPhone", count: 12),
        ],
        devices: [
          SampleDeviceSummary(
            device: SampleDevice(name: "Apple Watch", model: "Watch"), count: 48_210),
          SampleDeviceSummary(device: SampleDevice(name: "Strap", model: "S1"), count: 1_204),
        ])))
}

#Preview("Sources, empty") {
  sources(.loaded(SampleSources(apps: [], devices: [])))
}

#Preview("Sources, loading") {
  sources(.loading)
}

#Preview("Sources, failed") {
  sources(.failed("The database couldn't be read."))
}

#Preview("All data, more failed") {
  NavigationStack {
    AllDataContent(
      type: heartRate, state: .loaded(previewSamples(heartRate, limit: 3), hasMore: true),
      moreFailed: true, loadMore: {})
  }
  .previewFrame(width: 560, height: 360)
}
