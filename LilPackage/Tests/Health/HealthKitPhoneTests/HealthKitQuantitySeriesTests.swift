import Foundation
import HealthKit
import HealthUpload
import Testing

/// How the iPhone reads quantity series out of HealthKit for its upload (851-4149): samples whose
/// `count` is over 1, as a Watch writes heart rate in a workout or an app writes with
/// `HKQuantitySeriesSampleBuilder`. Each goes up as its sample, whose value is HealthKit's
/// `quantity` for the whole series, and a `health_quantity_series` record with every value.
@Suite(.serialized)
struct HealthKitQuantitySeriesTests {
  let start = Date(timeIntervalSince1970: 1_790_000_000)
  let bpm = HKUnit.count().unitDivided(by: .minute())

  /// What HealthKit makes of a series, which the encoding relies on: one sample, whose quantity is
  /// HealthKit's average of it (time-weighted for heart rate, so not the values' plain mean), with
  /// its count, extremes and most recent value.
  @Test
  func aSeriesIsOneSampleWithItsCountAndSummary() async throws {
    let health = try await SyntheticHealthKit.empty()
    let samples = try await heartRateSeries(health, values: zigzag(120), every: 5)
    let sample = try #require(samples.first as? HKDiscreteQuantitySample)
    #expect(samples.count == 1)
    #expect(sample.count == 120)
    #expect(sample.quantity == sample.averageQuantity)
    #expect(sample.averageQuantity.doubleValue(for: bpm) != 119.5)
    #expect(sample.minimumQuantity.doubleValue(for: bpm) == 60)
    #expect(sample.maximumQuantity.doubleValue(for: bpm) == 179)
    #expect(sample.mostRecentQuantity.doubleValue(for: bpm) == zigzag(120).last)
    #expect(sample.mostRecentQuantityDateInterval.start == start.addingTimeInterval(595))
    // An anchored query, as the backfill reads, finds it as one sample.
    let read = try await HKAnchoredObjectQueryDescriptor(
      predicates: [.quantitySample(type: HKQuantityType(.heartRate))], anchor: nil
    ).result(for: health.store)
    #expect(read.addedSamples.map(\.count) == [120])
  }

  @Test
  func aPageHasEachSeriesWithItsValues() async throws {
    let health = try await SyntheticHealthKit.empty()
    let heart = try await heartRateSeries(health, values: zigzag(120), every: 5)
    let single = SyntheticHealthKit.sample(
      HKQuantityTypeIdentifier.heartRate.rawValue, 70, at: start.addingTimeInterval(-60))
    try await health.save([single])

    let (mutations, _) = try await readAll(
      HealthBackfillType(id: HKQuantityTypeIdentifier.heartRate.rawValue))
    let id = heart[0].uuid.uuidString.lowercased()
    // The single reading alone; the series' sample, then its values, in the order HealthKit
    // saved them.
    let upserts = mutations.filter { $0.op == .upsert }
    #expect(
      upserts.map { "\($0.entity) \($0.id)" } == [
        "health_sample \(id)", "health_quantity_series \(id)",
        "health_sample \(single.uuid.uuidString.lowercased())",
      ])
    let row = try #require(upserts.first { $0.entity == "health_quantity_series" }?.row)
    #expect(row["count"] == 120)
    #expect(row["startDate"] == .number(ms(start).asDouble))
    #expect(row["times"] == .array((0..<120).map { .number(Double($0) * 5) }))
    #expect(row["durations"] == .array(Array(repeating: 0, count: 120)))
    // Read back in the catalog's unit, a value can be a rounding off what was written.
    #expect(numbers(row["values"]).map { $0.rounded() } == zigzag(120))
    #expect(row["minimum"] == 60)
    #expect(row["maximum"] == 179)
    #expect(row["mostRecent"] == .number(zigzag(120).last!))
    #expect(row["mostRecentStartDate"] == .number(ms(start.addingTimeInterval(595)).asDouble))
    #expect(row["mostRecentEndDate"] == .number(ms(start.addingTimeInterval(595)).asDouble))
  }

  @Test
  func aCumulativeSeriesKeepsEachValuesInterval() async throws {
    let health = try await SyntheticHealthKit.empty()
    let builder = HKQuantitySeriesSampleBuilder(
      healthStore: health.store, quantityType: HKQuantityType(.stepCount), startDate: start,
      device: nil)
    for minute in 0..<60 {
      try builder.insert(
        HKQuantity(unit: .count(), doubleValue: Double(10 + minute)),
        for: DateInterval(start: start.addingTimeInterval(Double(minute) * 60), duration: 60))
    }
    let samples = try await builder.finishSeries(metadata: nil, endDate: nil)
    #expect(samples.map(\.count) == [60])
    #expect(samples.first is HKCumulativeQuantitySample)

    let (mutations, _) = try await readAll(
      HealthBackfillType(id: HKQuantityTypeIdentifier.stepCount.rawValue))
    let upserts = mutations.filter { $0.op == .upsert }
    #expect(upserts.map(\.entity) == ["health_sample", "health_quantity_series"])
    // The sample's value is the sum.
    #expect(upserts.first?.row?["value"] == 2370)
    let row = try #require(upserts.last?.row)
    #expect(row["times"] == .array((0..<60).map { .number(Double($0) * 60) }))
    #expect(row["durations"] == .array(Array(repeating: 60, count: 60)))
    #expect(row["values"] == .array((0..<60).map { .number(Double(10 + $0)) }))
    #expect(row["minimum"] == .null)
    #expect(row["mostRecent"] == .null)
  }

  /// The once-only read of series uploaded before their values (`HealthBackfill.readSeriesAgain`)
  /// finds only series, and sends only their values' records.
  @Test
  func readingSeriesAgainFindsOnlySeries() async throws {
    let health = try await SyntheticHealthKit.empty()
    let first = try await heartRateSeries(health, values: zigzag(12), every: 5)
    let second = try await heartRateSeries(
      health, values: [100, 101, 102], every: 30, from: start.addingTimeInterval(3600))
    try await health.save([
      SyntheticHealthKit.sample(
        HKQuantityTypeIdentifier.heartRate.rawValue, 70, at: start.addingTimeInterval(-60))
    ])
    let type = HealthBackfillType(id: HKQuantityTypeIdentifier.heartRate.rawValue)

    // A page at a time. (Earlier suites' deletions, thousands of heart rates in CI's run, count
    // against a page's limit, but aren't sent.)
    let (mutations, _) = try await readAll(type, series: true)
    #expect(
      mutations.map { "\($0.entity) \($0.id)" }.sorted()
        == (first + second).map { "health_quantity_series \($0.uuid.uuidString.lowercased())" }
        .sorted())
  }

  /// Each series' values are its own, every one of them, from both reads, with more series than
  /// are read at once (851-4182). Each is 4 values 30 minutes apart: a values query with `count`
  /// in its predicate left out such a series' first and last (iOS 27.2, 851-4172).
  @Test
  func everySeriesHasAllItsOwnValues() async throws {
    var written: [String: [Double]] = [:]
    let health = try await SyntheticHealthKit.empty()
    for index in 0..<20 {
      let values = (0..<4).map { Double(60 + index * 4 + $0) }
      let series = try await heartRateSeries(
        health, values: values, every: 1800, from: start.addingTimeInterval(Double(index) * 86_400))
      written[series[0].uuid.uuidString.lowercased()] = values
    }
    let type = HealthBackfillType(id: HKQuantityTypeIdentifier.heartRate.rawValue)
    for series in [false, true] {
      let (mutations, _) = try await readAll(type, series: series)
      let rows = mutations.filter { $0.entity == "health_quantity_series" }
      #expect(Set(rows.map(\.id)) == Set(written.keys))
      for row in rows {
        #expect(row.row?["times"] == .array([0, 1800, 3600, 5400].map { .number($0) }))
        #expect(numbers(row.row?["values"]).map { $0.rounded() } == written[row.id])
      }
    }
  }

  /// A deleted series goes up as its sample's deletion, which deletes its values on the server.
  @Test
  func aDeletedSeriesIsItsSamplesDeletion() async throws {
    let health = try await SyntheticHealthKit.empty()
    let series = try await heartRateSeries(health, values: zigzag(12), every: 5)
    let type = HealthBackfillType(id: HKQuantityTypeIdentifier.heartRate.rawValue)
    let (_, anchor) = try await readAll(type)
    try await health.store.delete(series)
    let (mutations, _) = try await readAll(type, after: anchor)
    #expect(mutations == [.delete("health_sample", id: series[0].uuid.uuidString.lowercased())])
  }

  /// Every page of a type after `anchor`, as the backfill reads them, and the anchor after them.
  /// A read from no anchor has earlier tests' deletions too, so it can take more than one page.
  private func readAll(
    _ type: HealthBackfillType, after anchor: Data? = nil, limit: Int = 10_000,
    series: Bool = false
  ) async throws -> ([HealthMutation], Data?) {
    var mutations: [HealthMutation] = []
    var anchor = anchor
    while true {
      let page =
        series
        ? try await HealthReader.liveValue.series(type, anchor, limit)
        : try await HealthReader.liveValue.page(type, anchor, limit)
      mutations += page.mutations
      anchor = page.anchor
      if !page.hasMore { break }
    }
    return (mutations, anchor)
  }

  /// A heart rate series of `values`, `every` seconds apart from `from` (the test's start), each an
  /// instant, as a Watch records one.
  private func heartRateSeries(
    _ health: SyntheticHealthKit, values: [Double], every interval: TimeInterval,
    from: Date? = nil
  ) async throws -> [HKQuantitySample] {
    let from = from ?? start
    let builder = HKQuantitySeriesSampleBuilder(
      healthStore: health.store, quantityType: HKQuantityType(.heartRate), startDate: from,
      device: nil)
    for (index, value) in values.enumerated() {
      try builder.insert(
        HKQuantity(unit: bpm, doubleValue: value),
        at: from.addingTimeInterval(Double(index) * interval))
    }
    return try await builder.finishSeries(metadata: nil, endDate: nil)
  }

  private func numbers(_ value: JSONValue?) -> [Double] {
    guard case .array(let values) = value else { return [] }
    return values.compactMap { if case .number(let number) = $0 { number } else { nil } }
  }

  /// `count` heart rates from 60 bpm up and down, each once.
  private func zigzag(_ count: Int) -> [Double] {
    (0..<count).map { Double(60 + ($0 * 37) % 120) }
  }
}

extension Int {
  fileprivate var asDouble: Double { Double(self) }
}
