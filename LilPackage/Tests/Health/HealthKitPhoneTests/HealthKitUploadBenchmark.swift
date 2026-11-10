import Darwin
import Foundation
import HealthKit
import HealthUpload
import Synchronization
import Testing

/// How long the iPhone's upload takes to read a year of a Watch's workout heart rate (851-4182):
/// a 60-minute workout every day, recorded as a Watch records one, a series of a value every 5 s
/// (365 series of 720 values, 262,800 values), beside heart rate every 5 minutes the rest of the
/// day (about 100,000 single samples). Both reads: the type's pages, as the backfill uploads them,
/// and the one-time read of its series again (`HealthBackfill.readSeriesAgain`). Every series must
/// come with all its values, the first and last included. Then the same for 5,000 small series
/// (`manySmallSeries`). Only when asked, since writing them takes a while:
/// `TEST_RUNNER_LIL_HEALTHKIT_BENCHMARK=1 scripts/test-iphone-healthkit HealthKitUploadBenchmark`.
@Suite(
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["LIL_HEALTHKIT_BENCHMARK"] == "1"))
struct HealthKitUploadBenchmark {
  @Test
  func aYearOfWorkoutHeartRateSeries() async throws {
    let health = try await SyntheticHealthKit.empty()
    let bpm = HKUnit.count().unitDivided(by: .minute())
    let clock = ContinuousClock()
    let saving = clock.now
    var singles: [HKQuantitySample] = []
    var saved: [HKQuantitySample] = []
    var day = date(1, 1)
    for _ in 0..<365 {
      let workout = day.addingTimeInterval(7 * 3600)
      for minute in stride(from: 0, to: 24 * 60, by: 5) {
        let at = day.addingTimeInterval(Double(minute) * 60)
        if at >= workout, at < workout.addingTimeInterval(3600) { continue }
        singles.append(
          SyntheticHealthKit.sample(heartRate, 50 + Double((minute * 37) % 70), at: at))
      }
      let builder = HKQuantitySeriesSampleBuilder(
        healthStore: health.store, quantityType: HKQuantityType(.heartRate),
        startDate: workout, device: nil)
      for second in stride(from: 0, to: 3600, by: 5) {
        try builder.insert(
          HKQuantity(unit: bpm, doubleValue: 120 + Double((second * 7) % 50)),
          at: workout.addingTimeInterval(Double(second)))
      }
      saved += try await builder.finishSeries(
        metadata: nil, endDate: workout.addingTimeInterval(3595))
      _ = try await health.workout(.running, at: workout, minutes: 60)
      day = london.date(byAdding: .day, value: 1, to: day)!
    }
    try await health.save(singles)
    let series = Set(saved.map { $0.uuid.uuidString.lowercased() })
    print(
      "Benchmark: saved \(singles.count) samples, \(series.count) workouts and their series of 720 values in \(clock.now - saving)"
    )

    // Values queries by many IDs (851-4172 saw 183 take 125 s), and by fewer.
    let type = HKQuantityType(.heartRate)
    func byIDs(
      _ samples: [HKQuantitySample], includeSample: Bool, and others: [NSPredicate] = []
    ) async throws -> Int {
      let predicate = NSCompoundPredicate(
        andPredicateWithSubpredicates: [HKQuery.predicateForObjects(with: Set(samples.map(\.uuid)))]
          + others)
      let descriptor = HKQuantitySeriesSampleQueryDescriptor(
        predicate: .quantitySample(type: type, predicate: predicate),
        options: includeSample ? .includeSample : [])
      var count = 0
      for try await _ in descriptor.results(for: health.store) { count += 1 }
      return count
    }
    for (name, chunks, includeSample) in [
      ("183 IDs, with samples", [Array(saved.prefix(183))], true),
      ("183 IDs, without", [Array(saved.prefix(183))], false),
      ("10 IDs, without", [Array(saved.prefix(10))], false),
      ("1 ID, without", [Array(saved.prefix(1))], false),
    ] {
      let start = clock.now
      var values = 0
      for chunk in chunks { values += try await byIDs(chunk, includeSample: includeSample) }
      print("Benchmark:   values by \(name): \(values) values in \(clock.now - start)")
    }
    let year = HKQuery.predicateForSamples(
      withStart: date(1, 1), end: date(1, 1).addingTimeInterval(366 * 86_400))
    let isSeries = NSPredicate(format: "%K > 1", HKPredicateKeyPathCount)
    for (name, others) in [("and the year's dates", [year]), ("and count > 1", [isSeries])] {
      let start = clock.now
      let values = try await byIDs(Array(saved.prefix(183)), includeSample: false, and: others)
      print("Benchmark:   values by 183 IDs \(name): \(values) values in \(clock.now - start)")
    }
    do {
      // The callback query, by 183 IDs.
      let start = clock.now
      let values: Int = try await withCheckedThrowingContinuation { continuation in
        let count = Mutex(0)
        health.store.execute(
          HKQuantitySeriesSampleQuery(
            quantityType: type,
            predicate: HKQuery.predicateForObjects(with: Set(saved.prefix(183).map(\.uuid)))
          ) { _, quantity, _, _, done, error in
            if let error { return continuation.resume(throwing: error) }
            if quantity != nil { count.withLock { $0 += 1 } }
            if done { continuation.resume(returning: count.withLock { $0 }) }
          })
      }
      print(
        "Benchmark:   values by 183 IDs, callback query: \(values) values in \(clock.now - start)")
    }
    try await Self.compareChunks(saved, store: health.store)

    let backfillType = HealthBackfillType(id: HKQuantityTypeIdentifier.heartRate.rawValue)
    for (name, read) in [
      ("the type's pages", HealthReader.liveValue.page),
      ("its series again", HealthReader.liveValue.series),
    ] {
      let footprint = Self.footprint()
      // The highest footprint while it reads, sampled every 20 ms.
      let peak = Task {
        var peak = footprint
        while !Task.isCancelled {
          peak = max(peak, Self.footprint())
          try? await Task.sleep(for: .milliseconds(20))
        }
        return peak
      }
      var anchor: Data?
      var pages: [Duration] = []
      var rows: [String: [String: JSONValue]] = [:]
      while true {
        let start = clock.now
        let page = try await read(backfillType, anchor, 10_000)
        pages.append(clock.now - start)
        for mutation in page.mutations where mutation.entity == "health_quantity_series" {
          rows[mutation.id] = mutation.row
        }
        anchor = page.anchor
        if !page.hasMore { break }
      }
      peak.cancel()
      let highest = await peak.value
      let total = pages.reduce(Duration.zero, +)
      print(
        "Benchmark: \(name): \(total) (\(pages.count) pages, slowest \(pages.max()!)), memory at most +\((Int64(highest) - Int64(footprint)) / 1_048_576) MB"
      )
      #expect(Set(rows.keys) == series)
      // Every value, the first and last included: a values query with `count` in its predicate
      // left them out (iOS 27.2, 851-4172).
      for (id, row) in rows {
        let times = numbers(row["times"])
        #expect(row["count"] == 720, "\(id)")
        #expect(times.count == 720, "\(id)")
        #expect(times.first == 0 && times.last == 3595, "\(id)")
      }
    }
  }

  /// Many small series (851-4182 code review): 5,000 of 4 heart rates a minute apart, an hour
  /// apart, as an app writing a few values at a time with `HKQuantitySeriesSampleBuilder` would,
  /// where a query each costs HealthKit's overhead per query more than the values.
  @Test
  func manySmallSeries() async throws {
    let health = try await SyntheticHealthKit.empty()
    let bpm = HKUnit.count().unitDivided(by: .minute())
    let clock = ContinuousClock()
    let saving = clock.now
    var saved: [HKQuantitySample] = []
    for index in 0..<5_000 {
      let start = date(1, 1).addingTimeInterval(Double(index) * 3600)
      let builder = HKQuantitySeriesSampleBuilder(
        healthStore: health.store, quantityType: HKQuantityType(.heartRate), startDate: start,
        device: nil)
      for minute in 0..<4 {
        try builder.insert(
          HKQuantity(unit: bpm, doubleValue: Double(60 + (index + minute) % 60)),
          at: start.addingTimeInterval(Double(minute) * 60))
      }
      saved += try await builder.finishSeries(metadata: nil, endDate: nil)
    }
    print("Benchmark: saved \(saved.count) series of 4 values in \(clock.now - saving)")
    try await Self.compareChunks(saved, store: health.store)

    let backfillType = HealthBackfillType(id: HKQuantityTypeIdentifier.heartRate.rawValue)
    for (name, read) in [
      ("the type's pages", HealthReader.liveValue.page),
      ("its series again", HealthReader.liveValue.series),
    ] {
      let start = clock.now
      var anchor: Data?
      var series = 0
      while true {
        let page = try await read(backfillType, anchor, 10_000)
        series += page.mutations.count { $0.entity == "health_quantity_series" }
        anchor = page.anchor
        if !page.hasMore { break }
      }
      print("Benchmark: small series, \(name): \(series) series in \(clock.now - start)")
      #expect(series == saved.count)
    }
  }

  /// Times reading the series' values in chunks of at most so many series and values, a query
  /// each, so many at once: one of a single series without its sample, one of more with each
  /// value's sample, to tell whose it is.
  private static func compareChunks(_ samples: [HKQuantitySample], store: HKHealthStore)
    async throws
  {
    let clock = ContinuousClock()
    for (ids, values, width) in [
      (500, 100_000, 1), (1, 1, 8), (50, 1_000, 8), (100, 2_000, 8), (500, 5_000, 8),
      (500, 10_000, 8),
    ] {
      var chunks: [[HKQuantitySample]] = []
      var chunkValues = 0
      for sample in samples {
        if chunks.isEmpty || chunks[chunks.count - 1].count == ids
          || chunkValues + sample.count > values
        {
          chunks.append([])
          chunkValues = 0
        }
        chunks[chunks.count - 1].append(sample)
        chunkValues += sample.count
      }
      let start = clock.now
      let read = try await withThrowingTaskGroup(of: Int.self) { group in
        var read = 0
        for (index, chunk) in chunks.enumerated() {
          if index >= width, let done = try await group.next() { read += done }
          let ids = Set(chunk.map(\.uuid))
          group.addTask {
            let descriptor = HKQuantitySeriesSampleQueryDescriptor(
              predicate: .quantitySample(
                type: HKQuantityType(.heartRate), predicate: HKQuery.predicateForObjects(with: ids)),
              options: ids.count > 1 ? .includeSample : [])
            var count = 0
            for try await _ in descriptor.results(for: store) { count += 1 }
            return count
          }
        }
        for try await done in group { read += done }
        return read
      }
      print(
        "Benchmark:   values in chunks of \(ids) series or \(values) values, \(width) at once (\(chunks.count) queries): \(read) values in \(clock.now - start)"
      )
    }
  }

  /// The process's memory footprint, in bytes, as Xcode's gauge and jetsam count it.
  private static func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
}
