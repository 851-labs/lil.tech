import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only: `makePreviewHealthDatabase()`.

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
  .frame(width: 560, height: 620)
}

#Preview("All data") {
  allData(heartRate, .loaded(previewSamples(heartRate), hasMore: true))
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
  .frame(width: 560, height: 620)
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
  .frame(width: 560, height: 360)
}

@MainActor
private func sources(_ state: DataSourcesContent.State) -> some View {
  NavigationStack {
    DataSourcesContent(type: heartRate, state: state)
  }
  .frame(width: 560, height: 420)
}

#Preview("Sources") {
  let found = try! makePreviewHealthDatabase().read { db in
    try HealthDatabase.sampleSources(of: heartRate.id, db)
  }
  return sources(.loaded(apps: found.apps, devices: found.devices))
}

#Preview("Several sources") {
  sources(
    .loaded(
      apps: [
        SampleSource(
          id: "com.apple.health.watch", name: "Apple Watch", count: 48_210, latest: .now),
        SampleSource(id: "com.example.strap", name: "Synthetic Strap", count: 1_204, latest: .now),
        SampleSource(id: "com.apple.health.iphone", name: "iPhone", count: 12, latest: .now),
      ],
      devices: [
        SampleDeviceSummary(
          device: SampleDevice(name: "Apple Watch", model: "Watch"), count: 48_210),
        SampleDeviceSummary(device: SampleDevice(name: "Strap", model: "S1"), count: 1_204),
      ]))
}

#Preview("Sources, empty") {
  sources(.loaded(apps: [], devices: []))
}

#Preview("Sources, loading") {
  sources(.loading)
}
