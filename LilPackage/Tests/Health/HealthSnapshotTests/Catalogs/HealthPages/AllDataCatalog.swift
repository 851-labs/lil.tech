#if os(macOS)
  import Foundation
  import HealthCatalog
  import HealthDatabase
  @testable import HealthPages
  import SQLiteData
  import SwiftUI
  import Testing

  // All Data (`AllDataContent`), a sample's details (`SampleDetailView`) and Data Sources
  // (`DataSourcesContent`). Synthetic data only: `catalogDatabase`'s samples, or samples made up
  // here, before `previewNow`.

  extension MacSnapshotTests {
    @Test(arguments: allDataCatalog.selectedStates)
    func allData(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let allDataCatalog = StateCatalog(
    "All Data", width: 560, minHeight: 620,
    states: [
      // The next page loading, as it does once the list's end is in view.
      CatalogState("All data") {
        allData(heartRate, .loaded(samples(heartRate), hasMore: true), isLoadingMore: true)
      },
      // A day with a reading every 5 minutes, as a Watch's heart rate during a workout can have:
      // one long section.
      CatalogState("All data, a long day") {
        allData(heartRate, .loaded(longDay, hasMore: false))
      },
      // A charted category's samples: each one's length (851-2831).
      CatalogState("All data, handwashing") {
        allData(handwashing, .loaded(handwashingSamples, hasMore: false))
      },
      // A symptom's samples: each one's severity as Health names it (851-2828).
      CatalogState("All data, symptoms") {
        allData(headache, .loaded(headacheSamples, hasMore: false))
      },
      CatalogState("All data, raw steps") {
        allData(steps, .loaded(samples(steps), hasMore: false))
      },
      CatalogState("All data, empty") { allData(heartRate, .loaded([], hasMore: false)) },
      CatalogState("All data, loading") { allData(heartRate, .loading) },
      CatalogState("All data, failed") {
        allData(heartRate, .failed("The database couldn't be read."))
      },
      CatalogState("Sample") {
        NavigationStack {
          SampleDetailView(type: heartRate, sample: samples(heartRate, limit: 1)[0])
        }
      },
      CatalogState("Sample without device", minHeight: 360) {
        NavigationStack {
          SampleDetailView(
            type: steps,
            sample: HealthSample(
              id: "synthetic", type: steps.id,
              startDate: previewNow.addingTimeInterval(-6 * 3600).unixMilliseconds,
              endDate: previewNow.addingTimeInterval(-6 * 3600 + 600).unixMilliseconds,
              value: 412, unit: "count", sourceName: "Pedometer++",
              sourceBundleID: "com.example.pedometer"))
        }
      },
      // Recorded in Tokyo (851-4179): a Time Zone row, with its start on Tokyo's clock. The times
      // stay on the Mac's.
      CatalogState("Sample recorded in Tokyo") {
        NavigationStack {
          SampleDetailView(
            type: heartRate, sample: recorded(in: "Asia/Tokyo", samples(heartRate, limit: 1)[0]))
        }
      },
      // In the Mac's own zone: the row, without a second clock.
      CatalogState("Sample recorded in Los Angeles") {
        NavigationStack {
          SampleDetailView(
            type: heartRate,
            sample: recorded(in: "America/Los_Angeles", samples(heartRate, limit: 1)[0]))
        }
      },
      // Apple's keys and values in words (851-4169): an enum's case, a date, a number and a
      // Boolean, by label, with the recorded zone in the Time Zone row rather than Metadata.
      CatalogState("Sample with metadata") {
        NavigationStack {
          SampleDetailView(type: cardioFitness, sample: cardioFitnessSample)
        }
      },
      CatalogState("Sources", minHeight: 420) {
        sources(
          .loaded(
            try! catalogDatabase.read { try HealthDatabase.sampleSources(of: heartRate.id, $0) }))
      },
      CatalogState("Several sources", minHeight: 420) {
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
      },
      CatalogState("Sources, empty", minHeight: 420) {
        sources(.loaded(SampleSources(apps: [], devices: [])))
      },
      CatalogState("Sources, loading", minHeight: 420) { sources(.loading) },
      CatalogState("Sources, failed", minHeight: 420) {
        sources(.failed("The database couldn't be read."))
      },
      // The next page failed: the last day's section closes, with a button to try again.
      CatalogState("All data, more failed", minHeight: 360) {
        NavigationStack {
          AllDataContent(
            type: heartRate, state: .loaded(samples(heartRate, limit: 3), hasMore: true),
            moreFailed: true, loadMore: {})
        }
      },
    ])

  private let heartRate = HealthCatalog.type(id: "HKQuantityTypeIdentifierHeartRate")!
  private let steps = HealthCatalog.type(id: "HKQuantityTypeIdentifierStepCount")!
  private let handwashing = HealthCatalog.type(id: HealthDatabase.handwashingType)!
  private let headache = HealthCatalog.type(id: "HKCategoryTypeIdentifierHeadache")!
  private let cardioFitness = HealthCatalog.type(id: "HKQuantityTypeIdentifierVO2Max")!

  /// A Watch's cardio fitness estimate, with the metadata such an estimate has.
  private let cardioFitnessSample: HealthSample = {
    let start = previewNow.addingTimeInterval(-26 * 3600)
    var sample = HealthSample(
      id: "synthetic-vo2max", type: cardioFitness.id, startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(1800).unixMilliseconds, value: 41.3, unit: "ml/(kg*min)",
      sourceName: "Apple Watch", sourceBundleID: "com.apple.health.watch")
    let earliest = previewCalendar.date(byAdding: .day, value: -30, to: start)!
    sample.metadata = """
      {"HKVO2MaxTestType":2,"HKAlgorithmVersion":2,"HKWasUserEntered":false,\
      "HKMetadataKeyAppleDeviceCalibrated":true,"HKTimeZone":"America/Los_Angeles",\
      "HKDateOfEarliestDataUsedForEstimate":{"date":"\(earliest.ISO8601Format())"}}
      """
    return sample
  }()

  /// The newest of a type's samples in `catalogDatabase`.
  private func samples(_ type: HealthDataType, limit: Int = 60) -> [HealthSample] {
    try! catalogDatabase.read { db in
      try HealthDatabase.samplePage(of: type.id, after: nil, limit: limit, db)
    }
  }

  /// `sample`, recorded in the zone named `zone` (`HKTimeZone`), with its other metadata.
  private func recorded(in zone: String, _ sample: HealthSample) -> HealthSample {
    var sample = sample
    sample.metadata = metadataRecorded(in: zone, sample.metadata)
    return sample
  }

  /// The day before `previewNow`, a reading every 5 minutes from 11:55 PM back to midnight.
  private let longDay: [HealthSample] = {
    let end = previewCalendar.startOfDay(for: previewNow).addingTimeInterval(-300)
    return (0..<288).map { index in
      let start = end.unixMilliseconds - index * 300_000
      return HealthSample(
        id: "synthetic-\(index)", type: heartRate.id, startDate: start, endDate: start,
        value: Double(62 + (index * 7) % 45), unit: "count/min", sourceName: "Synthetic Watch",
        sourceBundleID: "com.example.watch")
    }
  }()

  /// Every hour and a half before `previewNow`, each a few seconds longer than the next.
  private let handwashingSamples: [HealthSample] = (0..<8).map { index in
    let start = previewNow.unixMilliseconds - (index + 1) * 5_400_000
    return HealthSample(
      id: "synthetic-\(index)", type: handwashing.id, startDate: start,
      endDate: start + (14 + index * 3) * 1000, categoryValue: 0,
      sourceName: "Synthetic Watch", sourceBundleID: "com.example.watch")
  }

  /// Every four hours before `previewNow`, with each severity.
  private let headacheSamples: [HealthSample] = [3, 2, 1, 4, 0, 2].enumerated().map {
    index, value in
    let start = previewNow.unixMilliseconds - (index + 1) * 14_400_000
    return HealthSample(
      id: "synthetic-\(index)", type: headache.id, startDate: start,
      endDate: start + (index % 2) * 3_600_000, categoryValue: value,
      sourceName: "Synthetic iPhone", sourceBundleID: "com.example.iphone")
  }

  @MainActor
  private func allData(
    _ type: HealthDataType, _ state: AllDataContent.State, isLoadingMore: Bool = false
  ) -> some View {
    NavigationStack {
      AllDataContent(type: type, state: state, isLoadingMore: isLoadingMore, loadMore: {})
    }
  }

  @MainActor
  private func sources(_ state: DataSourcesContent.State) -> some View {
    NavigationStack {
      DataSourcesContent(type: heartRate, state: state)
    }
  }
#endif
