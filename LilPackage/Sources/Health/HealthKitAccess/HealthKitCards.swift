public import Dependencies
public import Foundation
public import HealthCards
import HealthCatalog
public import HealthKit

// The iPhone's card engine (docs/decisions/cards.md, The iPhone): cards' shared core (`CardRun`)
// fed from HealthKit, local-first and offline. Totals come from HealthKit's statistics, which
// de-duplicate sources as Health does, and readings from sample queries, in catalog units, which
// the core weighs and aggregates exactly as the Mac's engine does (851-3199). Sleep and workout
// windows come with 851-3200.

extension DependencyValues {
  /// Cards computed from this iPhone's HealthKit.
  public var healthKitCards: HealthKitCards {
    get { self[HealthKitCards.self] }
    set { self[HealthKitCards.self] = newValue }
  }
}

/// Cards from this iPhone's HealthKit: a card's page (`data`) and its Summary row (`headline`).
/// Both are cancellable: cancelling the task stops HealthKit's queries.
public struct HealthKitCards: Sendable {
  /// A card over the period of `range` containing `date`, as its page shows it. `now` places 6M's
  /// periods (`CardRun`).
  public var data:
    @Sendable (
      _ spec: CardSpec, _ range: CardRange, _ date: Date, _ now: Date, _ calendar: Calendar
    ) async throws -> CardData
  /// What a card's Summary row shows, from data started by `now`; `nil` for No Data.
  public var headline:
    @Sendable (_ spec: CardSpec, _ now: Date, _ calendar: Calendar) async throws -> CardHeadline?

  public init(
    data:
      @escaping @Sendable (
        _ spec: CardSpec, _ range: CardRange, _ date: Date, _ now: Date, _ calendar: Calendar
      ) async throws -> CardData,
    headline:
      @escaping @Sendable (_ spec: CardSpec, _ now: Date, _ calendar: Calendar) async throws
      -> CardHeadline?
  ) {
    self.data = data
    self.headline = headline
  }
}

extension HealthKitCards: DependencyKey {
  public static var liveValue: Self {
    let engine = HealthKitCardEngine(store: HKHealthStore())
    return Self(
      data: { spec, range, date, now, calendar in
        try await engine.data(
          CardRun(spec: spec, range: range, date: date, now: now, calendar: calendar))
      },
      headline: { spec, now, calendar in
        try await engine.headline(spec, now: now, calendar: calendar)
      }
    )
  }

  public static var testValue: Self {
    Self(
      data: unimplemented("HealthKitCards.data"),
      headline: unimplemented("HealthKitCards.headline")
    )
  }
}

/// The engine itself, over one health store: what `HealthKitCards` runs, and its parts.
public struct HealthKitCardEngine: Sendable {
  public let store: HKHealthStore

  public init(store: HKHealthStore) {
    self.store = store
  }

  /// What HealthKit can't give a card yet.
  public enum Unsupported: Error, Equatable {
    /// Sleep and workout windows (851-3200).
    case eventWindows
  }

  /// A run's data, fetched from HealthKit: its window fetches first, then its fetches, all at
  /// once, as the core asks for them.
  public func data(_ run: CardRun) async throws -> CardData {
    var run = run
    if !run.windowFetches.isEmpty {
      var results: [CardWindowFetchResult] = []
      for fetch in run.windowFetches {
        results.append(try await window(fetch))
      }
      run = run.windowed(results)
    }
    let fetches = run.fetches
    let results = try await withThrowingTaskGroup(of: (Int, CardFetchResult).self) { group in
      for (index, fetch) in fetches.enumerated() {
        group.addTask { [calendar = run.calendar] in
          (index, try await self.fetch(fetch, calendar: calendar))
        }
      }
      var results = [CardFetchResult?](repeating: nil, count: fetches.count)
      for try await (index, result) in group { results[index] = result }
      return results.map { $0! }
    }
    try Task.checkCancellation()
    return run.compute(results)
  }

  /// What a card's Summary row shows (`CardHeadline`), from data started by `now`; `nil` for No
  /// Data. Found as the Mac finds it (`HealthDatabase.cardHeadline`).
  public func headline(_ spec: CardSpec, now: Date, calendar: Calendar) async throws
    -> CardHeadline?
  {
    func run(endingOn date: Date) async throws -> CardData {
      try await data(CardRun(headlineOf: spec, endingOn: date, calendar: calendar))
    }
    switch spec.headlineLookup {
    case nil:
      return nil
    case .latestReading(let type):
      guard let reading = try await latestReading(of: type, startedBy: now) else { return nil }
      let date = Date(milliseconds: reading.start)
      return CardHeadline(
        value: reading.value, date: date, kind: .reading, data: try await run(endingOn: date))
    case .latestData(let type):
      // HealthKit's samples are all there, so a total's latest data is its latest sample, as
      // the Mac's is its latest bucket or sample.
      guard let reading = try await latestReading(of: type, startedBy: now) else { return nil }
      return CardHeadline(
        latestBucketOf: try await run(endingOn: Date(milliseconds: reading.start)))
    case .search:
      for end in CardHeadline.searchEnds(for: spec, now: now, calendar: calendar) {
        if let headline = CardHeadline(latestBucketOf: try await run(endingOn: end)) {
          return headline
        }
      }
      return nil
    }
  }

  // MARK: - Fetches

  /// One of a run's fetches, from HealthKit.
  public func fetch(_ fetch: CardFetch, calendar: Calendar) async throws -> CardFetchResult {
    switch fetch.kind {
    case .totals(let range, let grain):
      return .totals(try await totals(of: fetch.type, in: range, by: grain, calendar: calendar))
    case .readings(let range, let filter, let needsSampleIDs):
      return .readings(
        try await readings(
          of: fetch.type, in: range, filter: filter, needsSampleIDs: needsSampleIDs))
    case .stretchReadings:
      throw Unsupported.eventWindows
    }
  }

  /// One of a run's window fetches: sleep records or workouts (851-3200).
  public func window(_ fetch: CardWindowFetch) async throws -> CardWindowFetchResult {
    throw Unsupported.eventWindows
  }

  /// A cumulative type's totals per bucket of `grain`, from the buckets starting in `range`:
  /// HealthKit's statistics, which de-duplicate overlapping sources by the person's source
  /// priority, as Health does.
  ///
  /// HealthKit sums by the hour from the range's start (a local midnight), and the hours are
  /// added up into the calendar's buckets here. So the buckets are `calendar`'s, whichever
  /// calendar HealthKit steps by, daylight saving days included, and a sample across an hour's
  /// end is shared between them, as the Mac's 30-minute statistics share it.
  public func totals(
    of typeID: String, in range: Range<Date>, by grain: CardGrain, calendar: Calendar
  ) async throws -> [CardTotal] {
    guard let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: typeID)),
      let unit = HealthCatalog.type(id: typeID)?.unit.map(HKUnit.init(from:))
    else { return [] }
    return try await run { finish in
      let query = HKStatisticsCollectionQuery(
        quantityType: type,
        quantitySamplePredicate: HKQuery.predicateForSamples(
          withStart: range.lowerBound, end: range.upperBound),
        options: .cumulativeSum, anchorDate: range.lowerBound,
        intervalComponents: DateComponents(hour: 1))
      query.initialResultsHandler = { _, collection, error in
        guard let collection else {
          return finish(.failure(error ?? HKError(.errorHealthDataUnavailable)))
        }
        var totals: [CardTotal] = []
        var bucketer = CardBucketer(grain, calendar: calendar)
        for statistics in collection.statistics() {
          guard range.contains(statistics.startDate),
            let sum = statistics.sumQuantity()?.doubleValue(for: unit)
          else { continue }
          let start = bucketer.start(of: statistics.startDate)
          if totals.last?.start == start {
            totals[totals.count - 1].sum += sum
          } else {
            totals.append(CardTotal(start: start, sum: sum))
          }
        }
        finish(.success(totals))
      }
      return query
    }
  }

  /// A type's readings starting in `range` (Unix milliseconds), oldest first, in its catalog
  /// unit, that match `filter`: sources by their bundle ID, devices by their model.
  public func readings(
    of typeID: String, in range: Range<Int>, filter: CardSpec.Filter?, needsSampleIDs: Bool
  ) async throws -> [CardReading] {
    guard let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: typeID)),
      let unit = HealthCatalog.type(id: typeID)?.unit.map(HKUnit.init(from:))
    else { return [] }
    var predicates = [
      HKQuery.predicateForSamples(
        withStart: Date(milliseconds: range.lowerBound),
        end: Date(milliseconds: range.upperBound), options: .strictStartDate)
    ]
    if let bundleIDs = filter?.sources {
      let wanted = Set(bundleIDs)
      let sources = try await HKSourceQueryDescriptor(predicate: .quantitySample(type: type))
        .result(for: store)
        .filter { wanted.contains($0.bundleIdentifier) }
      // No source of that type matches, so no reading can.
      guard !sources.isEmpty else { return [] }
      predicates.append(HKQuery.predicateForObjects(from: Set(sources)))
    }
    if let models = filter?.deviceModels {
      predicates.append(
        HKQuery.predicateForObjects(
          withDeviceProperty: HKDevicePropertyKeyModel, allowedValues: Set(models)))
    }
    let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    return try await run { finish in
      HKSampleQuery(
        sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
      ) { _, samples, error in
        guard let samples else {
          return finish(.failure(error ?? HKError(.errorHealthDataUnavailable)))
        }
        finish(
          .success(
            Self.readings(samples, unit: unit, in: range, needsSampleIDs: needsSampleIDs)))
      }
    }
  }

  /// A type's latest reading started by `now`, in its catalog unit; `nil` without one.
  public func latestReading(of typeID: String, startedBy now: Date) async throws -> CardReading? {
    guard let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: typeID)),
      let unit = HealthCatalog.type(id: typeID)?.unit.map(HKUnit.init(from:))
    else { return nil }
    let predicate = NSPredicate(format: "%K <= %@", HKPredicateKeyPathStartDate, now as NSDate)
    return try await run { finish in
      HKSampleQuery(
        sampleType: type, predicate: predicate, limit: 1,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
      ) { _, samples, error in
        guard let samples else {
          return finish(.failure(error ?? HKError(.errorHealthDataUnavailable)))
        }
        finish(
          .success(
            Self.readings(samples, unit: unit, in: .min ..< .max, needsSampleIDs: true).first))
      }
    }
  }

  /// Quantity samples (oldest first) as the core's readings, those starting in `range` (Unix
  /// milliseconds, half-open whatever HealthKit's end is). Made on HealthKit's queue, as its
  /// handler gets them, so a year's samples are never kept beside their readings.
  private static func readings(
    _ samples: [HKSample], unit: HKUnit, in range: Range<Int>, needsSampleIDs: Bool
  ) -> [CardReading] {
    var readings: [CardReading] = []
    readings.reserveCapacity(samples.count)
    // One string per run of a source's samples, as the Mac shares them, so the weights' source
    // comparisons are mostly of the same string.
    var source = ""
    for case let sample as HKQuantitySample in samples {
      let start = sample.startDate.milliseconds
      guard range.contains(start) else { continue }
      let bundleID = sample.sourceRevision.source.bundleIdentifier
      if bundleID != source { source = bundleID }
      readings.append(
        CardReading(
          start: start, end: sample.endDate.milliseconds,
          value: sample.quantity.doubleValue(for: unit), source: source,
          sampleID: needsSampleIDs ? sample.uuid.uuidString.lowercased() : ""))
    }
    return readings
  }

  /// Runs the query `make` returns, which calls `finish` once with its answer, and stops it when
  /// the task is cancelled, throwing `CancellationError` at once rather than waiting for a
  /// stopped query's handler, which HealthKit may never call. The async query descriptors don't
  /// stop theirs: a year of heart rate cancelled 50 ms in still read for 1.3 s.
  private func run<Value: Sendable>(
    _ make: (_ finish: @escaping @Sendable (Result<Value, any Error>) -> Void) -> HKQuery
  ) async throws -> Value {
    let running = LockIsolated(Running<Value>())
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let query = make { result in
          running.withValue { $0.finish() }?.resume(with: result)
        }
        let started = running.withValue { running in
          guard !running.isFinished else { return false }
          running.continuation = continuation
          running.query = query
          return true
        }
        guard started else { return continuation.resume(throwing: CancellationError()) }
        store.execute(query)
      }
    } onCancel: {
      let (continuation, query) = running.withValue { ($0.finish(), $0.query) }
      if let query { store.stop(query) }
      continuation?.resume(throwing: CancellationError())
    }
  }
}

/// A query `HealthKitCardEngine.run` is waiting on: answered or cancelled, whichever is first,
/// resumes its continuation, once.
private struct Running<Value: Sendable>: @unchecked Sendable {
  var continuation: CheckedContinuation<Value, any Error>?
  var query: HKQuery?
  var isFinished = false

  /// The continuation to resume, if nothing has yet.
  mutating func finish() -> CheckedContinuation<Value, any Error>? {
    defer {
      continuation = nil
      isFinished = true
    }
    return continuation
  }
}

extension Date {
  fileprivate init(milliseconds: Int) {
    self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
  }

  /// Unix milliseconds, as every engine reads times.
  fileprivate var milliseconds: Int { Int((timeIntervalSince1970 * 1000).rounded()) }
}
