public import Dependencies
public import Foundation
public import HealthCards
import HealthCatalog
public import HealthKit

// The iPhone's card engine (docs/decisions/cards.md, The iPhone): cards' shared core (`CardRun`)
// fed from HealthKit, local-first and offline. Totals come from HealthKit's statistics, which
// de-duplicate sources as Health does, and readings from sample queries, in catalog units, which
// the core weighs and aggregates exactly as the Mac's engine does (851-3199). Sleep and workout
// windows read sleep analysis records and workouts, which the core turns into nights and
// stretches, then the readings in those stretches (851-3200).

extension DependencyValues {
  /// Cards computed from this iPhone's HealthKit.
  public var healthKitCards: HealthKitCards {
    get { self[HealthKitCards.self] }
    set { self[HealthKitCards.self] = newValue }
  }
}

/// Cards from this iPhone's HealthKit: a card's page (`data`), its Summary row (`headline`), and
/// the editor's filter choices (`filterChoices`). Each is cancellable: cancelling the task stops
/// HealthKit's queries.
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
  /// The apps and device models a type's samples came from, for a series' filter in the editor
  /// (851-3213).
  public var filterChoices: @Sendable (_ type: String) async throws -> CardFilterChoices

  public init(
    data:
      @escaping @Sendable (
        _ spec: CardSpec, _ range: CardRange, _ date: Date, _ now: Date, _ calendar: Calendar
      ) async throws -> CardData,
    headline:
      @escaping @Sendable (_ spec: CardSpec, _ now: Date, _ calendar: Calendar) async throws
      -> CardHeadline?,
    filterChoices: @escaping @Sendable (_ type: String) async throws -> CardFilterChoices = { _ in
      CardFilterChoices()
    }
  ) {
    self.data = data
    self.headline = headline
    self.filterChoices = filterChoices
  }
}

/// HealthKit hasn't been asked for a type a card reads (851-4035): the person hasn't been through
/// Health access yet (a new install, or Not Now). HealthKit says so (`errorAuthorizationNotDetermined`)
/// rather than returning nothing, as it does for a type that was asked about and not allowed.
public struct HealthAccessNeeded: LocalizedError, Equatable {
  public init() {}

  public var errorDescription: String? {
    "lil health needs access to your Health data to show this card."
  }

  /// `error` as this, when it's HealthKit saying it hasn't been asked; otherwise `error`.
  public static func converting(_ error: any Error) -> any Error {
    (error as? HKError)?.code == .errorAuthorizationNotDetermined ? HealthAccessNeeded() : error
  }

  /// `body`'s value, or its error, converted.
  static func converting<Value>(_ body: () async throws -> Value) async throws -> Value {
    do {
      return try await body()
    } catch {
      throw converting(error)
    }
  }
}

extension HealthKitCards: DependencyKey {
  public static var liveValue: Self {
    let engine = HealthKitCardEngine(store: HKHealthStore())
    return Self(
      data: { spec, range, date, now, calendar in
        try await HealthAccessNeeded.converting {
          try await engine.data(
            CardRun(spec: spec, range: range, date: date, now: now, calendar: calendar))
        }
      },
      headline: { spec, now, calendar in
        try await HealthAccessNeeded.converting {
          try await engine.headline(spec, now: now, calendar: calendar)
        }
      },
      filterChoices: { type in
        try await HealthAccessNeeded.converting { try await engine.filterChoices(of: type) }
      }
    )
  }

  public static var testValue: Self {
    Self(
      data: unimplemented("HealthKitCards.data"),
      headline: unimplemented("HealthKitCards.headline"),
      filterChoices: unimplemented(
        "HealthKitCards.filterChoices", placeholder: CardFilterChoices())
    )
  }
}

/// The engine itself, over one health store: what `HealthKitCards` runs, and its parts.
public struct HealthKitCardEngine: Sendable {
  public let store: HKHealthStore

  public init(store: HKHealthStore) {
    self.store = store
  }

  /// A run's data, fetched from HealthKit: its window fetches first, then its fetches, all at
  /// once, as the core asks for them.
  public func data(_ run: CardRun) async throws -> CardData {
    var run = run
    if !run.windowFetches.isEmpty {
      run = run.windowed(try await concurrently(run.windowFetches) { try await window($0) })
    }
    let calendar = run.calendar
    let results = try await concurrently(run.fetches) { try await fetch($0, calendar: calendar) }
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
    case .stretchReadings(let stretches, let filter, let needsSampleIDs):
      return .readings(
        try await readings(
          of: fetch.type, in: stretches, filter: filter, needsSampleIDs: needsSampleIDs))
    }
  }

  /// One of a run's window fetches: the sleep records its nights are grouped from, or the
  /// workouts its workout windows keep.
  public func window(_ fetch: CardWindowFetch) async throws -> CardWindowFetchResult {
    switch fetch {
    case .sleep(let range): .sleep(try await sleepRecords(overlapping: range))
    case .workouts(let range): .workouts(try await workouts(overlapping: range))
    }
  }

  /// Sleep analysis records that end after `range` starts and start before it ends (Unix
  /// milliseconds), by start: every value (In Bed included) from every source, as `CardNights`
  /// groups them. In Bed records can start well before a night. Each with the zone it was
  /// recorded in (`HKMetadataKeyTimeZone`, 851-4176), which its night follows, when that's a name
  /// the tools take (`CardTimeZone.named`), as the Mac and the server read it.
  public func sleepRecords(overlapping range: Range<Int>) async throws -> [CardSleepRecord] {
    let records = try await samples(of: HKCategoryType(.sleepAnalysis), overlapping: range) {
      sample in
      (sample as? HKCategorySample).map { ($0, $0.metadata?[HKMetadataKeyTimeZone] as? String) }
    }
    // A few names among thousands of records: each checked once.
    var zones: [String: TimeZone?] = [:]
    return records.map { sample, zone in
      CardSleepRecord(
        start: sample.startDate.milliseconds, end: sample.endDate.milliseconds,
        value: sample.value, source: sample.sourceRevision.source.bundleIdentifier,
        timeZone: zone.flatMap { name in
          if let checked = zones[name] { return checked }
          let checked = CardTimeZone.named(name)
          zones[name] = checked
          return checked
        },
        // As written: Foundation names `UTC` `GMT`, and runs' ties compare the names (851-4177).
        timeZoneName: zone)
    }
  }

  /// Workouts of every activity that end after `range` starts and start before it ends (Unix
  /// milliseconds), from every source, by start, with their overall activity and whether they
  /// were indoors, as the Mac and the server read it from what the iPhone uploads.
  public func workouts(overlapping range: Range<Int>) async throws -> [CardWorkout] {
    try await samples(of: HKWorkoutType.workoutType(), overlapping: range) { sample in
      (sample as? HKWorkout).map {
        CardWorkout(
          start: $0.startDate.milliseconds, end: $0.endDate.milliseconds,
          activityType: Int($0.workoutActivityType.rawValue), indoor: Self.indoor($0))
      }
    }
  }

  /// Whether a workout was indoors: as its `HKMetadataKeyIndoorWorkout` says, else as its
  /// activities do (each one's metadata, else its configuration's `locationType`), if they
  /// agree; `nil` when nothing says.
  public static func indoor(_ workout: HKWorkout) -> Bool? {
    CardWorkout.indoor(
      workout: HealthMetadataValues.value(HKMetadataKeyIndoorWorkout, in: workout.metadata)?.bool,
      activities: workout.workoutActivities.map { activity in
        HealthMetadataValues.value(HKMetadataKeyIndoorWorkout, in: activity.metadata)?.bool
          ?? CardWorkout.indoor(
            locationType: Double(activity.workoutConfiguration.locationType.rawValue))
      })
  }

  /// Samples of `type` that end after `range` starts and start before it ends, by start, made
  /// into `Value`s on HealthKit's queue. The predicate compares HealthKit's dates; the range is
  /// applied again to the milliseconds every engine reads, so a sample a fraction of one past an
  /// end is placed as the Mac places it.
  private func samples<Value: Sendable>(
    of type: HKSampleType, overlapping range: Range<Int>,
    _ transform: @escaping @Sendable (HKSample) -> Value?
  ) async throws -> [Value] {
    let predicate = NSPredicate(
      format: "%K < %@ AND %K > %@", HKPredicateKeyPathStartDate,
      Date(milliseconds: range.upperBound) as NSDate, HKPredicateKeyPathEndDate,
      Date(milliseconds: range.lowerBound) as NSDate)
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
            samples.compactMap { sample in
              guard sample.startDate.milliseconds < range.upperBound,
                sample.endDate.milliseconds > range.lowerBound
              else { return nil }
              return transform(sample)
            }))
      }
    }
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
    guard let query = try await readingQuery(of: typeID, filter: filter) else { return [] }
    return try await readings(query, in: range, needsSampleIDs: needsSampleIDs)
  }

  /// A type's readings starting in one of `stretches` (in order and apart, Unix milliseconds),
  /// oldest first, as `readings(of:in:filter:needsSampleIDs:)` reads them, for a sleep or workout
  /// window.
  ///
  /// Stretches less than `stretchGap` apart are read as one range (a night's stretches asleep,
  /// with the minutes awake between them, which the core leaves out), and the ranges are read
  /// `stretchConcurrency` at a time. A year of nights asleep takes 0.42 s so, against 1.9 s for a
  /// query per stretch one after another, and 1.4 s for the year's span in one query
  /// (`HealthKitCardsBenchmark`).
  public func readings(
    of typeID: String, in stretches: [CardStretch], filter: CardSpec.Filter?,
    needsSampleIDs: Bool
  ) async throws -> [CardReading] {
    guard !stretches.isEmpty, let query = try await readingQuery(of: typeID, filter: filter)
    else { return [] }
    let ranges = Self.queryRanges(stretches)
    // Series once for every stretch (851-4172), beside the stretches' single samples: only those
    // near one have their values read.
    async let series = series(query, for: ranges, needsSampleIDs: needsSampleIDs)
    let singles = try await concurrently(ranges, width: Self.stretchConcurrency) {
      try await singleReadings(query, in: $0, needsSampleIDs: needsSampleIDs)
    }
    let allSeries = try await series
    return zip(ranges, singles).flatMap { range, singles in
      CardSeries.merged(singles, CardSeries.readings(of: allSeries, in: range))
    }
  }

  /// The ranges `readings(of:in:filter:needsSampleIDs:)` queries for `stretches` (in order and
  /// apart): stretches less than `stretchGap` apart as one.
  public static func queryRanges(_ stretches: [CardStretch]) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    for stretch in stretches {
      if let last = ranges.last, stretch.start - last.upperBound < stretchGap {
        ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, stretch.end)
      } else {
        ranges.append(stretch.start..<stretch.end)
      }
    }
    return ranges
  }

  /// Stretches closer than this (in milliseconds) are read in one query.
  public static let stretchGap = 3_600_000
  /// How many of a window's queries run at once.
  public static let stretchConcurrency = 8

  /// What a type's reading queries share: its type, catalog unit and the filter's predicates.
  /// `nil` when no reading can match: a type HealthKit doesn't know, or none of the type's
  /// sources being the filter's.
  private struct ReadingQuery: @unchecked Sendable {
    let type: HKQuantityType
    let unit: HKUnit
    let predicates: [NSPredicate]
  }

  private func readingQuery(of typeID: String, filter: CardSpec.Filter?) async throws
    -> ReadingQuery?
  {
    guard let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: typeID)),
      let unit = HealthCatalog.type(id: typeID)?.unit.map(HKUnit.init(from:))
    else { return nil }
    var predicates: [NSPredicate] = []
    if let bundleIDs = filter?.sources {
      let wanted = Set(bundleIDs)
      let sources: Set<HKSource> = try await run { finish in
        HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, error in
          guard let sources else {
            return finish(.failure(error ?? HKError(.errorHealthDataUnavailable)))
          }
          finish(.success(sources.filter { wanted.contains($0.bundleIdentifier) }))
        }
      }
      // No source of that type matches, so no reading can.
      guard !sources.isEmpty else { return nil }
      predicates.append(HKQuery.predicateForObjects(from: Set(sources)))
    }
    if let models = filter?.deviceModels {
      predicates.append(
        HKQuery.predicateForObjects(
          withDeviceProperty: HKDevicePropertyKeyModel, allowedValues: Set(models)))
    }
    return ReadingQuery(type: type, unit: unit, predicates: predicates)
  }

  /// The query's readings starting in `range`: single samples', and series' values in place of
  /// their samples (`CardSeries`, 851-4172), read at once.
  private func readings(_ query: ReadingQuery, in range: Range<Int>, needsSampleIDs: Bool)
    async throws -> [CardReading]
  {
    async let singles = singleReadings(query, in: range, needsSampleIDs: needsSampleIDs)
    async let series = series(query, for: [range], needsSampleIDs: needsSampleIDs)
    return CardSeries.merged(
      try await singles, CardSeries.readings(of: try await series, in: range))
  }

  /// The query's single samples' readings starting in `range`: its series are read by
  /// `series(_:for:needsSampleIDs:)`.
  private func singleReadings(_ query: ReadingQuery, in range: Range<Int>, needsSampleIDs: Bool)
    async throws -> [CardReading]
  {
    let predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: [
        // A millisecond early: a sample starting a fraction of one before the range is in it,
        // in the milliseconds every engine reads (`readings(_:unit:in:needsSampleIDs:)` keeps
        // the range exactly).
        HKQuery.predicateForSamples(
          withStart: Date(milliseconds: range.lowerBound - 1),
          end: Date(milliseconds: range.upperBound), options: .strictStartDate)
      ] + query.predicates)
    let unit = query.unit
    return try await run { finish in
      HKSampleQuery(
        sampleType: query.type, predicate: predicate, limit: HKObjectQueryNoLimit,
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

  /// The query's series (samples with a `count` over 1) that can have values in one of `ranges`
  /// (in order), by start then ID, each with every value, in order: those starting a week before
  /// one or later (`CardSeries.starts(for:)`), and before its end, whose samples end in it or
  /// later, since a series' values are within its sample. An `HKSampleQuery` for the series,
  /// then, when there are any, an `HKQuantitySeriesSampleQuery` for each one's values, by its
  /// ID. HealthKit's statistics split a series by its values too (851-4149). A values query
  /// can't find series by their `count`: then it left out a series' first and last values (iOS
  /// 27.2, 851-4172). Its async descriptor can't be stopped, so every query runs through `run`.
  private func series(
    _ query: ReadingQuery, for ranges: [Range<Int>], needsSampleIDs: Bool
  ) async throws -> [CardSeries.Series] {
    guard let first = ranges.first, let last = ranges.last else { return [] }
    let starts = CardSeries.starts(for: first.lowerBound..<last.upperBound)
    let predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: [
        // A millisecond early, as for single samples: the series' times are kept exactly.
        HKQuery.predicateForSamples(
          withStart: Date(milliseconds: starts.lowerBound - 1),
          end: Date(milliseconds: starts.upperBound), options: .strictStartDate),
        NSPredicate(
          format: "%K >= %@", HKPredicateKeyPathEndDate,
          Date(milliseconds: first.lowerBound - 1) as NSDate),
        NSPredicate(format: "%K > 1", HKPredicateKeyPathCount),
      ] + query.predicates)
    let unit = query.unit
    var series: [CardSeries.Series] = try await run { finish in
      HKSampleQuery(
        sampleType: query.type, predicate: predicate, limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
      ) { _, samples, error in
        guard let samples else {
          return finish(.failure(error ?? HKError(.errorHealthDataUnavailable)))
        }
        var series: [CardSeries.Series] = []
        // A series can have values in a range it starts at most a week before, and before its
        // end, and ends in or after. Of the ranges ending after its start, the first is the one
        // to check: later ones start later. Ranges are in order and apart, and the samples come
        // by start, so it only moves on.
        var next = 0
        for case let sample as HKQuantitySample in samples {
          let (start, end) = (sample.startDate.milliseconds, sample.endDate.milliseconds)
          while next < ranges.count, ranges[next].upperBound <= start { next += 1 }
          guard next < ranges.count, ranges[next].lowerBound <= end,
            CardSeries.starts(for: ranges[next]).contains(start)
          else { continue }
          series.append(
            CardSeries.Series(
              sample: CardReading(
                start: start, end: end, value: sample.quantity.doubleValue(for: unit),
                source: sample.sourceRevision.source.bundleIdentifier,
                sampleID: sample.uuid.uuidString.lowercased()),
              values: []))
        }
        finish(
          .success(
            series.sorted {
              ($0.sample.start, $0.sample.sampleID) < ($1.sample.start, $1.sample.sampleID)
            }))
      }
    }
    guard !series.isEmpty else { return [] }
    // Each series' values by its own ID, `seriesConcurrency` at a time, without its sample
    // (known already). With its sample (`includeSample`) a query by dates took 32 s for a year,
    // HealthKit making each of the 105,000 single samples; by many IDs at once, HealthKit's cost
    // grows faster than their number: 10 took 90 ms, 183 took 125 s, and one takes 4 ms
    // (`HealthKitCardsBenchmark`, 851-4172).
    let ids = series.map { UUID(uuidString: $0.sample.sampleID) }
    let values = try await concurrently(ids, width: Self.seriesConcurrency) { id -> [CardReading] in
      guard let id else { return [] }
      return try await run { finish in
        let collected = LockIsolated<[CardReading]>([])
        return HKQuantitySeriesSampleQuery(
          quantityType: query.type, predicate: HKQuery.predicateForObject(with: id)
        ) { _, quantity, interval, _, done, error in
          if let error { return finish(.failure(error)) }
          if let quantity, let interval {
            let reading = CardReading(
              start: interval.start.milliseconds, end: interval.end.milliseconds,
              value: quantity.doubleValue(for: unit), source: "", sampleID: "")
            collected.withValue { $0.append(reading) }
          }
          if done { finish(.success(collected.value)) }
        }
      }
    }
    for index in series.indices {
      let sample = series[index].sample
      var readings = values[index]
      for value in readings.indices {
        readings[value].source = sample.source
        readings[value].sampleID = needsSampleIDs ? sample.sampleID : ""
      }
      // In order: HealthKit gives them so, which this makes sure of.
      if zip(readings, readings.dropFirst()).contains(where: { $0.start > $1.start }) {
        readings.sort { $0.start < $1.start }
      }
      // A series whose values didn't come (deleted in between) is read as its sample. Of the
      // others, only the values that count are kept (`CardSeries.Series.counts`).
      series[index] = CardSeries.Series(sample: sample, values: readings.isEmpty ? nil : readings)
      if !needsSampleIDs { series[index].sample.sampleID = "" }
    }
    return series
  }

  /// How many series' values are read at once, a query each. The upload reads them so too
  /// (`HealthReader.seriesValues`, 851-4182).
  package static let seriesConcurrency = 8

  /// How many of a type's latest samples `filterChoices(of:)` reads device models from: a type can
  /// have millions, and the devices that matter are the ones recording it now.
  static let filterChoiceSamples = 1_000

  /// The apps a type's samples came from (HealthKit's sources, by name) and the device models of
  /// its latest samples (the most samples first), for a series' filter, as the Mac's Data Sources
  /// lists them. A filter's sources are bundle IDs and its devices models, as `readingQuery`
  /// matches them.
  public func filterChoices(of typeID: String) async throws -> CardFilterChoices {
    guard let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: typeID)) else {
      return CardFilterChoices()
    }
    // Both at once: neither needs the other.
    async let apps: [CardFilterChoices.App] = run { finish in
      HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, error in
        guard let sources else {
          return finish(.failure(error ?? HKError(.errorHealthDataUnavailable)))
        }
        finish(
          .success(
            sources.map { CardFilterChoices.App(id: $0.bundleIdentifier, name: $0.name) }
              .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }))
      }
    }
    async let models: [String] = run { finish in
      HKSampleQuery(
        sampleType: type, predicate: nil, limit: Self.filterChoiceSamples,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
      ) { _, samples, error in
        guard let samples else {
          return finish(.failure(error ?? HKError(.errorHealthDataUnavailable)))
        }
        finish(.success(Self.models(samples.compactMap { $0.device?.model })))
      }
    }
    return try await CardFilterChoices(apps: apps, deviceModels: models)
  }

  /// Each model once, the most common first, then by name.
  static func models(_ models: [String]) -> [String] {
    var counts: [String: Int] = [:]
    for model in models { counts[model, default: 0] += 1 }
    return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
  }

  /// A type's latest reading started by `now`, in its catalog unit; `nil` without one.
  /// A series' most recent value is its reading, as the Mac's and the server's tools take it
  /// (`HealthDatabase.latestReading`, 851-4171): HealthKit's value for a whole heart rate series
  /// is its average, which isn't a reading anyone took. A series that started before the latest
  /// sample (up to `CardSeries.reach`) whose most recent value is later, by `now`, is the latest
  /// (a workout's, past a strap's reading during it). Ties go to the higher ID.
  public func latestReading(of typeID: String, startedBy now: Date) async throws -> CardReading? {
    guard let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: typeID)),
      let unit = HealthCatalog.type(id: typeID)?.unit.map(HKUnit.init(from:))
    else { return nil }
    let predicate = NSPredicate(format: "%K <= %@", HKPredicateKeyPathStartDate, now as NSDate)
    let sample: HKQuantitySample? = try await run { finish in
      HKSampleQuery(
        sampleType: type, predicate: predicate, limit: 1,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
      ) { _, samples, error in
        guard let samples else {
          return finish(.failure(error ?? HKError(.errorHealthDataUnavailable)))
        }
        finish(.success(samples.first as? HKQuantitySample))
      }
    }
    guard let sample else { return nil }
    let latest = Self.mostRecent(of: sample, unit: unit)
    let start = sample.startDate.milliseconds
    let earlier = NSCompoundPredicate(
      andPredicateWithSubpredicates: [
        HKQuery.predicateForSamples(
          withStart: Date(milliseconds: start - CardSeries.reach - 1),
          end: Date(milliseconds: start + 1), options: .strictStartDate),
        NSPredicate(format: "%K > 1", HKPredicateKeyPathCount),
      ])
    let upper = now.milliseconds
    let later: CardReading? = try await run { finish in
      HKSampleQuery(
        sampleType: type, predicate: earlier, limit: HKObjectQueryNoLimit, sortDescriptors: nil
      ) { _, samples, error in
        guard let samples else {
          return finish(.failure(error ?? HKError(.errorHealthDataUnavailable)))
        }
        let candidates = samples.compactMap { sample -> CardReading? in
          guard let series = sample as? HKDiscreteQuantitySample, series.count > 1,
            (start - CardSeries.reach...start).contains(series.startDate.milliseconds)
          else { return nil }
          let reading = Self.mostRecent(of: series, unit: unit)
          return reading.start > latest.start && reading.start <= upper ? reading : nil
        }
        finish(.success(candidates.max { ($0.start, $0.sampleID) < ($1.start, $1.sampleID) }))
      }
    }
    return later ?? latest
  }

  /// A sample as a reading: a discrete series' most recent value, else its own.
  private static func mostRecent(of sample: HKQuantitySample, unit: HKUnit) -> CardReading {
    let id = sample.uuid.uuidString.lowercased()
    let source = sample.sourceRevision.source.bundleIdentifier
    if let series = sample as? HKDiscreteQuantitySample, series.count > 1 {
      let interval = series.mostRecentQuantityDateInterval
      return CardReading(
        start: interval.start.milliseconds, end: interval.end.milliseconds,
        value: series.mostRecentQuantity.doubleValue(for: unit), source: source, sampleID: id)
    }
    return CardReading(
      start: sample.startDate.milliseconds, end: sample.endDate.milliseconds,
      value: sample.quantity.doubleValue(for: unit), source: source, sampleID: id)
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
      // A series is read as its values (`series(_:for:needsSampleIDs:)`).
      guard range.contains(start), sample.count == 1 else { continue }
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
  /// Every query here runs through it.
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
      let (query, continuation) = running.withValue { running in
        (running.query, running.finish())
      }
      if let query { store.stop(query) }
      continuation?.resume(throwing: CancellationError())
    }
  }
}

/// A query `HealthKitCardEngine.run` is waiting on: answered or cancelled, whichever is first,
/// resumes its continuation, once. It lets go of the query then: the query's handler holds this,
/// so keeping it would keep both.
private struct Running<Value: Sendable>: @unchecked Sendable {
  var continuation: CheckedContinuation<Value, any Error>?
  var query: HKQuery?
  var isFinished = false

  /// The continuation to resume, if nothing has yet.
  mutating func finish() -> CheckedContinuation<Value, any Error>? {
    defer {
      continuation = nil
      query = nil
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

/// `body` of every item, `width` at a time (all at once by default), its results in the items'
/// order. The first to throw cancels the rest.
package func concurrently<Item: Sendable, Result: Sendable>(
  _ items: [Item], width: Int = .max,
  _ body: @escaping @Sendable (Item) async throws -> Result
) async throws -> [Result] {
  try await withThrowingTaskGroup(of: (Int, Result).self) { group in
    var results = [Result?](repeating: nil, count: items.count)
    for (index, item) in items.enumerated() {
      if index >= width, let done = try await group.next() {
        results[done.0] = done.1
      }
      group.addTask { (index, try await body(item)) }
    }
    for try await (index, result) in group { results[index] = result }
    return results.map { $0! }
  }
}
