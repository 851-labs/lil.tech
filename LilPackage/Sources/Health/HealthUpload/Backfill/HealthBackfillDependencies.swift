import CryptoKit
public import Dependencies
public import Foundation
public import HealthCatalog
import HealthKit
import HealthKitAccess
import IssueReporting
import LilAPI
import OpenAPIRuntime

/// A HealthKit type the backfill pages through with anchored queries.
public struct HealthBackfillType: Hashable, Sendable {
  public let id: String
  public let isCorrelation: Bool
  /// Skip (and report) a series whose values can't be read, rather than reading the page again:
  /// set after the type's reads kept failing, so one unreadable record can't hold it up forever.
  public var skipsUnreadableSeries = false

  public init(id: String, isCorrelation: Bool = false) {
    self.id = id
    self.isCorrelation = isCorrelation
  }

  /// Every quantity and category type the app can read, workouts and their routes, State of
  /// Mind, scored assessments, audiograms, ECGs, heartbeat series, medication dose events (those
  /// of the medications Health shares, 851-2571), and the correlations, which are read through
  /// their component types. Vision prescriptions, medications and Health Documents are read whole
  /// each run instead (``HealthVisionPrescriptionsReader``, ``HealthMedicationsReader``,
  /// ``HealthDocumentsReader``): Health shares them one by one.
  public static func all(availableOn version: IOSVersion) -> [Self] {
    HealthCatalog.types(availableOn: version).compactMap { type in
      switch (type.kind, type.readAuthorization) {
      case (.quantity, .standard), (.category, .standard), (.workout, .standard),
        (.stateOfMind, .standard), (.scoredAssessment, .standard), (.audiogram, .standard),
        (.electrocardiogram, .standard), (.heartbeatSeries, .standard),
        (.workoutRoute, .standard), (.medicationDoseEvent, .perObject):
        Self(id: type.id)
      case (.correlation, _): Self(id: type.id, isCorrelation: true)
      default: nil
      }
    }
  }
}

extension HealthBackfillType {
  /// The server entity its records are, so deletions go to the right one.
  public var entity: String {
    if isCorrelation { return HealthEncoder.correlationEntity }
    switch HealthCatalog.type(id: id)?.kind {
    case .workout: return HealthEncoder.workoutEntity
    case .stateOfMind: return HealthEncoder.stateOfMindEntity
    case .scoredAssessment: return HealthEncoder.scoredAssessmentEntity
    case .audiogram: return HealthEncoder.audiogramEntity
    case .electrocardiogram: return HealthEncoder.electrocardiogramEntity
    case .heartbeatSeries: return HealthEncoder.heartbeatSeriesEntity
    case .workoutRoute: return HealthEncoder.workoutRouteEntity
    case .medicationDoseEvent: return HealthEncoder.medicationDoseEntity
    default: return HealthEncoder.sampleEntity
    }
  }

  /// Whether its records are quantity samples, which may be series (851-4149).
  public var isQuantity: Bool {
    !isCorrelation && HealthCatalog.type(id: id)?.kind == .quantity
  }

  /// Objects per page, if not the backfill's default: types with blobs read fewer, since a
  /// page's blobs are held in memory until they're saved, and so do types with a series query
  /// per object.
  public var pageSize: Int? {
    switch HealthCatalog.type(id: id)?.kind {
    case .electrocardiogram: 50
    case .heartbeatSeries: 200
    // An hour's route is ~160 KB.
    case .workoutRoute: 10
    default: nil
    }
  }

  /// The HealthKit type to query and observe, or `nil` if HealthKit doesn't know it.
  var sampleType: HKSampleType? {
    isCorrelation
      ? HKObjectType.correlationType(forIdentifier: .init(rawValue: id))
      : HealthCatalog.type(id: id)?.objectType as? HKSampleType
  }
}

/// One page of an anchored query, already encoded.
public struct HealthPage: Sendable {
  public var mutations: [HealthMutation]
  /// Payloads too big for rows (e.g. an ECG's voltages), which the mutations refer to by SHA-256
  /// (`HealthBlob.sha256`). They go up before the page's batches.
  public var blobs: [Data]
  /// Where the next page starts, archived.
  public var anchor: Data
  public var hasMore: Bool
  /// The IDs of the objects read that couldn't be encoded (or whose series couldn't be read, once
  /// the type skips them), which the backfill holds back to try again (851-4151).
  public var failed: [String]

  public init(
    mutations: [HealthMutation], blobs: [Data] = [], anchor: Data, hasMore: Bool,
    failed: [String] = []
  ) {
    self.mutations = mutations
    self.blobs = blobs
    self.anchor = anchor
    self.hasMore = hasMore
    self.failed = failed
  }
}

public enum HealthBlob {
  /// The largest blob the server takes, as for batch files.
  public static let maxBytes = 16 * 1024 * 1024

  /// Names a blob as the server does: the SHA-256 of its bytes, in lowercase hex.
  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// A blob over `maxBytes`, which the server would always refuse.
  public struct TooLarge: Error, Equatable {
    public let bytes: Int
  }
}

extension DependencyValues {
  /// Reads HealthKit history a page at a time.
  public var healthReader: HealthReader {
    get { self[HealthReader.self] }
    set { self[HealthReader.self] = newValue }
  }

  /// Where the backfill keeps its state and the batch files it hasn't uploaded yet.
  public var healthBackfillStorage: HealthBackfillStorage {
    get { self[HealthBackfillStorage.self] }
    set { self[HealthBackfillStorage.self] = newValue }
  }

  /// Uploads a batch file.
  public var healthBatchUploader: HealthBatchUploader {
    get { self[HealthBatchUploader.self] }
    set { self[HealthBatchUploader.self] = newValue }
  }

  /// Uploads a blob.
  public var healthBlobUploader: HealthBlobUploader {
    get { self[HealthBlobUploader.self] }
    set { self[HealthBlobUploader.self] = newValue }
  }
}

public struct HealthReader: Sendable {
  /// Up to `limit` added and deleted objects of `type` after `anchor` (from the start if `nil`).
  public var page:
    @Sendable (_ type: HealthBackfillType, _ anchor: Data?, _ limit: Int) async throws -> HealthPage
  /// The objects of `type` with these IDs (lowercase UUIDs), encoded as a page is, for records
  /// held back to try again (851-4151). Those Health no longer has are left out. Its anchor and
  /// `hasMore` mean nothing.
  public var records:
    @Sendable (_ type: HealthBackfillType, _ ids: [String]) async throws -> HealthPage
  /// Up to `limit` of a quantity type's series (samples with `count` over 1) after `anchor`, as
  /// their values' records only, without deletions (`HealthBackfill.readSeriesAgain`, 851-4149).
  public var series:
    @Sendable (_ type: HealthBackfillType, _ anchor: Data?, _ limit: Int) async throws -> HealthPage

  public init(
    page:
      @escaping @Sendable (_ type: HealthBackfillType, _ anchor: Data?, _ limit: Int) async throws
      -> HealthPage,
    records:
      @escaping @Sendable (_ type: HealthBackfillType, _ ids: [String]) async throws -> HealthPage =
      { _, _ in
        reportIssue("Unimplemented: @Dependency(\\.healthReader).records")
        throw Unimplemented()
      },
    series:
      @escaping @Sendable (_ type: HealthBackfillType, _ anchor: Data?, _ limit: Int) async throws
      -> HealthPage = { _, _, _ in
        reportIssue("Unimplemented: @Dependency(\\.healthReader).series")
        throw Unimplemented()
      }
  ) {
    self.page = page
    self.records = records
    self.series = series
  }

  struct UnknownType: Error {
    let id: String
  }

  /// A reader made without `records`: trying held-back records fails their type, rather than
  /// stopping the run as a cancellation would.
  public struct Unimplemented: Error {
    public init() {}
  }

  /// A series (an ECG's voltages, a heartbeat series' beats) couldn't be read: its query failed.
  /// Unlike an encoding error, it isn't the record's fault, so the page is read again rather
  /// than the record skipped, which would move the anchor past it.
  public struct SeriesUnavailable: Error, Equatable {
    public let expected: Int
    public let read: Int
  }

  /// A series' query finished with a different number of values than its sample says. It's
  /// uploaded as read and reported: reading it again would only get the same.
  public struct SeriesCountMismatch: Error, Equatable {
    public let expected: Int
    public let read: Int
  }

  /// Reads a series' values (`transform` applied to each), mapping a locked device and
  /// cancellation through, and any other failure to `SeriesUnavailable`. A count other than
  /// `expected` is reported, and the values are kept as read.
  static func readSeries<Values: AsyncSequence, Value>(
    expected: Int, _ values: Values, _ transform: (Values.Element) -> Value
  ) async throws -> [Value] {
    var read: [Value] = []
    read.reserveCapacity(expected)
    do {
      for try await element in values { read.append(transform(element)) }
    } catch {
      let mapped = Locked.mapped(error)
      if mapped is Locked || mapped is CancellationError { throw mapped }
      throw SeriesUnavailable(expected: expected, read: read.count)
    }
    try Task.checkCancellation()
    if read.count != expected {
      reportIssue(SeriesCountMismatch(expected: expected, read: read.count))
    }
    return read
  }

  static func unarchiveAnchor(_ data: Data?) throws -> HKQueryAnchor? {
    try data.flatMap {
      try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
    }
  }

  /// One anchored page of a type's samples and deletions after `anchor`, through `Locked`.
  static func anchoredPage(
    _ type: HKSampleType, after anchor: HKQueryAnchor?, limit: Int, in store: HKHealthStore
  ) async throws -> HKAnchoredObjectQueryDescriptor<HKSample>.Result {
    do {
      return try await HKAnchoredObjectQueryDescriptor(
        predicates: [.sample(type: type)], anchor: anchor, limit: limit
      ).result(for: store)
    } catch {
      throw Locked.mapped(error)
    }
  }

  /// Health can't be read while the device is locked. Not a failure: the work waits until it's
  /// unlocked.
  public struct Locked: Error, Equatable {
    public init() {}

    /// `Locked` for HealthKit's "database inaccessible" (the device is locked), otherwise the
    /// error itself. Async queries catch and rethrow through this inline, since their
    /// descriptors aren't Sendable.
    static func mapped(_ error: any Error) -> any Error {
      (error as? HKError)?.code == .errorDatabaseInaccessible ? Locked() : error
    }

    /// Runs a synchronous HealthKit read, through `mapped`.
    static func mapping<T>(_ read: () throws -> T) throws -> T {
      do {
        return try read()
      } catch {
        throw mapped(error)
      }
    }
  }
}

extension HealthReader: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self(
      page: { type, anchorData, limit in
        guard let sampleType = type.sampleType else { throw UnknownType(id: type.id) }
        let anchor = try unarchiveAnchor(anchorData)
        var limit = limit
        var result = try await anchoredPage(sampleType, after: anchor, limit: limit, in: store)
        // Fewer samples, if their series' values would be too many for one page.
        if let fewer = withinSeriesBudget(result.addedSamples) {
          limit = fewer
          result = try await anchoredPage(sampleType, after: anchor, limit: limit, in: store)
        }
        var page = try await encode(result.addedSamples, of: type, store: store)
        // A sample's series goes with it, on the server (851-4149).
        let entity = type.entity
        page.mutations += result.deletedObjects.map {
          .delete(entity, id: HealthEncoder.id($0.uuid))
        }
        page.anchor = try NSKeyedArchiver.archivedData(
          withRootObject: result.newAnchor, requiringSecureCoding: true)
        page.hasMore = result.addedSamples.count + result.deletedObjects.count >= limit
        return page
      },
      records: { type, ids in
        guard let sampleType = type.sampleType else { throw UnknownType(id: type.id) }
        let uuids = Set(ids.compactMap(UUID.init(uuidString:)))
        guard !uuids.isEmpty else {
          return HealthPage(mutations: [], anchor: Data(), hasMore: false)
        }
        let samples: [HKSample]
        do {
          samples = try await HKSampleQueryDescriptor(
            predicates: [
              .sample(type: sampleType, predicate: HKQuery.predicateForObjects(with: uuids))
            ],
            sortDescriptors: []
          ).result(for: store)
        } catch {
          throw Locked.mapped(error)
        }
        return try await encode(samples, of: type, store: store)
      },
      series: { type, anchor, limit in
        try await seriesPage(type, after: anchor, limit: limit, store: store)
      })
  }

  /// Encodes samples of `type` as mutations, with their blobs. One that can't be encoded is
  /// reported and left out, with its ID in `failed`, so it can't stop the rest (851-4151).
  static func encode(
    _ samples: [HKSample], of type: HealthBackfillType, store: HKHealthStore
  ) async throws -> HealthPage {
    var mutations: [HealthMutation] = []
    var blobs: [Data] = []
    var failed: [String] = []
    // The values of the page's quantity series (851-4149), read together.
    let series = samples.compactMap { $0 as? HKQuantitySample }.filter(HealthEncoder.isSeries)
    let (values, unreadable) = try await Self.seriesValues(
      of: series, skippingUnreadable: type.skipsUnreadableSeries, store: store)
    for sample in samples {
      if unreadable.contains(sample.uuid) {
        failed.append(HealthEncoder.id(sample.uuid))
        continue
      }
      do {
        if let correlation = sample as? HKCorrelation {
          mutations += try HealthEncoder.correlation(correlation)
        } else if let workout = sample as? HKWorkout {
          mutations.append(HealthEncoder.workout(try await WorkoutRecord(workout)))
        } else if let log = sample as? HKStateOfMind {
          mutations.append(HealthEncoder.stateOfMind(log))
        } else if let assessment = sample as? HKScoredAssessment {
          mutations.append(try HealthEncoder.scoredAssessment(assessment))
        } else if let audiogram = sample as? HKAudiogramSample {
          mutations.append(HealthEncoder.audiogram(audiogram))
        } else if let route = sample as? HKWorkoutRoute {
          let (mutation, blob) = HealthEncoder.workoutRoute(
            try await WorkoutRouteRecord(route, store: store))
          mutations.append(mutation)
          if let blob { blobs.append(blob) }
        } else if let series = sample as? HKHeartbeatSeriesSample {
          mutations.append(
            HealthEncoder.heartbeatSeries(try await HeartbeatSeriesRecord(series, store: store)))
        } else if let dose = sample as? HKMedicationDoseEvent {
          mutations.append(HealthEncoder.medicationDose(MedicationDoseRecord(dose)))
        } else if let ecg = sample as? HKElectrocardiogram {
          let (mutation, blob) = HealthEncoder.electrocardiogram(
            try await ElectrocardiogramRecord(ecg, store: store))
          mutations.append(mutation)
          if let blob { blobs.append(blob) }
        } else if let quantity = sample as? HKQuantitySample, HealthEncoder.isSeries(quantity) {
          // Both or neither: the sample's line, then its values'.
          let record = try QuantitySeriesRecord(quantity, values: values[quantity.uuid])
          mutations += [try HealthEncoder.sample(sample), HealthEncoder.quantitySeries(record)]
        } else {
          mutations.append(try HealthEncoder.sample(sample))
        }
      } catch let error as Locked {
        // Not this sample's fault: the page is read again once the device is unlocked.
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as SeriesUnavailable {
        // Not the record's fault either: skipping it would move the anchor past it, unless
        // the type's reads kept failing. Then it's held back and tried again.
        guard type.skipsUnreadableSeries else { throw error }
        reportIssue(error)
        failed.append(HealthEncoder.id(sample.uuid))
      } catch {
        reportIssue(error)
        failed.append(HealthEncoder.id(sample.uuid))
      }
    }
    return HealthPage(
      mutations: mutations, blobs: blobs, anchor: Data(), hasMore: false, failed: failed)
  }

  /// The most series, and the most of their values, one query reads (851-4182), a page's queries
  /// running `HealthKitCardEngine.seriesConcurrency` at once. A query costs a few milliseconds
  /// however few its values, so a query per series is slow for many short ones, and one of
  /// 100,000 values leaves the other cores idle: this read a year of daily workouts' values about
  /// 3 times faster than either, and 5,000 series of 4 values faster than both
  /// (`HealthKitUploadBenchmark`, `docs/BENCHMARK.md` › The iPhone's upload).
  static let seriesPerQuery = 500
  static let seriesValuesPerQuery = 5_000
  /// The most series values a page holds (about 50 MB as they're encoded): a page whose samples'
  /// series have more is read again with fewer samples (`withinSeriesBudget`).
  static let seriesValuesPerPage = 500_000

  /// How many of a page's objects to read instead, if its samples' series (those read with their
  /// values) have more than `seriesValuesPerPage` values: those before the one that passes it,
  /// at least one. `nil` if they fit.
  static func withinSeriesBudget(_ samples: [HKSample]) -> Int? {
    var values = 0
    for (index, sample) in samples.enumerated() {
      guard let quantity = sample as? HKQuantitySample, HealthEncoder.isSeries(quantity),
        quantity.count <= HealthEncoder.maxSeriesValues
      else { continue }
      values += quantity.count
      if values > seriesValuesPerPage { return max(1, index) }
    }
    return nil
  }

  /// The values of quantity series (samples with `count` over 1, all of one type), by sample, in
  /// the type's catalog unit (851-4149), with a query per `seriesPerQuery` of them or
  /// `seriesValuesPerQuery` of their values, whichever comes first, several at once. A series
  /// with more than `HealthEncoder.maxSeriesValues` isn't read (it goes up without them). A query
  /// that fails throws `SeriesUnavailable`, so the page is read again, unless
  /// `skippingUnreadable`: then its series are returned as `unreadable`, to hold back.
  static func seriesValues(
    of samples: [HKQuantitySample], skippingUnreadable: Bool, store: HKHealthStore
  ) async throws -> (values: [UUID: [QuantitySeriesRecord.Value]], unreadable: Set<UUID>) {
    let read = samples.filter { $0.count <= HealthEncoder.maxSeriesValues }
    guard let type = read.first?.quantityType else { return ([:], []) }
    let unit = try HealthEncoder.unit(for: type)
    var chunks: [[(id: UUID, count: Int)]] = []
    var chunkValues = 0
    for sample in read {
      if chunks.isEmpty || chunks[chunks.count - 1].count == seriesPerQuery
        || chunkValues + sample.count > seriesValuesPerQuery
      {
        chunks.append([])
        chunkValues = 0
      }
      chunks[chunks.count - 1].append((sample.uuid, sample.count))
      chunkValues += sample.count
    }
    let results = try await concurrently(chunks, width: HealthKitCardEngine.seriesConcurrency) {
      chunk -> Result<[UUID: [QuantitySeriesRecord.Value]], SeriesUnavailable> in
      do {
        return .success(try await seriesValues(of: chunk, type: type, unit: unit, store: store))
      } catch let error as SeriesUnavailable where skippingUnreadable {
        return .failure(error)
      }
    }
    var values: [UUID: [QuantitySeriesRecord.Value]] = [:]
    var unreadable: Set<UUID> = []
    var failure: SeriesUnavailable?
    for (chunk, result) in zip(chunks, results) {
      switch result {
      case .success(let read):
        values.merge(read) { $1 }
      case .failure(let error):
        failure = failure ?? error
        unreadable.formUnion(chunk.map(\.id))
      }
    }
    // Once, however many queries failed.
    if let failure {
      reportIssue(failure, "\(unreadable.count) series' values couldn't be read")
    }
    return (values, unreadable)
  }

  /// The values of a few series (`seriesValues(of:skippingUnreadable:store:)`), by one query. A
  /// series alone is read without its sample, which is known already; several with each value's
  /// sample, to tell whose it is. One whose values didn't come (changed or deleted meanwhile)
  /// throws `SeriesUnavailable`, so it's read again, rather than going up as if it had too many.
  private static func seriesValues(
    of series: [(id: UUID, count: Int)], type: HKQuantityType, unit: HKUnit, store: HKHealthStore
  ) async throws -> [UUID: [QuantitySeriesRecord.Value]] {
    let descriptor = HKQuantitySeriesSampleQueryDescriptor(
      predicate: .quantitySample(
        type: type, predicate: HKQuery.predicateForObjects(with: Set(series.map(\.id)))),
      options: series.count > 1 ? .includeSample : [])
    let only = series.count == 1 ? series.first?.id : nil
    let results = try await readSeries(
      expected: series.reduce(0) { $0 + $1.count }, descriptor.results(for: store)
    ) { result in
      (
        id: only ?? result.sample?.uuid,
        value: QuantitySeriesRecord.Value(
          start: result.dateInterval.start, end: result.dateInterval.end,
          value: result.quantity.doubleValue(for: unit))
      )
    }
    var values: [UUID: [QuantitySeriesRecord.Value]] = [:]
    for result in results {
      guard let id = result.id else { continue }
      values[id, default: []].append(result.value)
    }
    if let missing = series.first(where: { values[$0.id] == nil }) {
      throw SeriesUnavailable(expected: missing.count, read: 0)
    }
    return values
  }

  /// Only a type's quantity series (`count` over 1) after `anchor`, as their values' records alone,
  /// for reading series uploaded before their values were (`HealthBackfill.readSeriesAgain`):
  /// their samples are on the server already. Deletions are left to the type's own anchor.
  static func seriesPage(
    _ type: HealthBackfillType, after anchorData: Data?, limit: Int, store: HKHealthStore
  ) async throws -> HealthPage {
    guard let sampleType = type.sampleType as? HKQuantityType else {
      throw UnknownType(id: type.id)
    }
    let anchor = try unarchiveAnchor(anchorData)
    func read(_ limit: Int) async throws -> HKAnchoredObjectQueryDescriptor<HKQuantitySample>.Result
    {
      do {
        return try await HKAnchoredObjectQueryDescriptor(
          predicates: [
            .quantitySample(
              type: sampleType, predicate: NSPredicate(format: "%K > 1", HKPredicateKeyPathCount))
          ],
          anchor: anchor, limit: limit
        ).result(for: store)
      } catch {
        throw Locked.mapped(error)
      }
    }
    var limit = limit
    var result = try await read(limit)
    if let fewer = withinSeriesBudget(result.addedSamples) {
      limit = fewer
      result = try await read(limit)
    }
    let series = result.addedSamples.filter(HealthEncoder.isSeries)
    let (values, unreadable) = try await seriesValues(
      of: series, skippingUnreadable: type.skipsUnreadableSeries, store: store)
    var mutations: [HealthMutation] = []
    var failed: [String] = []
    for sample in series {
      if unreadable.contains(sample.uuid) {
        failed.append(HealthEncoder.id(sample.uuid))
        continue
      }
      do {
        mutations.append(
          HealthEncoder.quantitySeries(
            try QuantitySeriesRecord(sample, values: values[sample.uuid])))
      } catch {
        reportIssue(error)
        failed.append(HealthEncoder.id(sample.uuid))
      }
    }
    return HealthPage(
      mutations: mutations,
      anchor: try NSKeyedArchiver.archivedData(
        withRootObject: result.newAnchor, requiringSecureCoding: true),
      hasMore: result.addedSamples.count + result.deletedObjects.count >= limit, failed: failed)
  }

  public static var testValue: Self {
    Self { _, _, _ in
      reportIssue("Unimplemented: @Dependency(\\.healthReader).page")
      throw CancellationError()
    }
  }
}

public struct HealthBackfillStorage: Sendable {
  public var loadState: @Sendable () throws -> HealthBackfillState?
  public var saveState: @Sendable (HealthBackfillState?) throws -> Void
  public var saveFile: @Sendable (_ name: String, _ data: Data) throws -> Void
  /// A saved file, or `nil` if it's gone.
  public var loadFile: @Sendable (_ name: String) throws -> Data?
  public var removeFile: @Sendable (_ name: String) throws -> Void

  public init(
    loadState: @escaping @Sendable () throws -> HealthBackfillState?,
    saveState: @escaping @Sendable (HealthBackfillState?) throws -> Void,
    saveFile: @escaping @Sendable (_ name: String, _ data: Data) throws -> Void,
    loadFile: @escaping @Sendable (_ name: String) throws -> Data?,
    removeFile: @escaping @Sendable (_ name: String) throws -> Void
  ) {
    self.loadState = loadState
    self.saveState = saveState
    self.saveFile = saveFile
    self.loadFile = loadFile
    self.removeFile = removeFile
  }

  /// In memory, for tests and catalogs.
  public static func inMemory() -> Self {
    let state = LockIsolated<HealthBackfillState?>(nil)
    let files = LockIsolated<[String: Data]>([:])
    return Self(
      loadState: { state.value },
      saveState: { state.setValue($0) },
      saveFile: { name, data in files.withValue { $0[name] = data } },
      loadFile: { name in files.value[name] },
      removeFile: { name in files.withValue { $0[name] = nil } }
    )
  }

  /// Files in `directory`: the state as JSON, each batch file, each blob, and other files the
  /// backfill keeps (named with their extension, e.g. `medication-doses.json`).
  public static func directory(_ directory: URL) -> Self {
    let stateURL = directory.appending(path: "state.json")
    let file = { @Sendable (name: String) in
      directory.appending(
        path: name.hasPrefix("blob-")
          ? "\(name).bin" : name.contains(".") ? name : "\(name).ndjson.gz")
    }
    let prepare = { @Sendable in
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return Self(
      loadState: {
        guard FileManager.default.fileExists(atPath: stateURL.path(percentEncoded: false))
        else { return nil }
        return try JSONDecoder().decode(HealthBackfillState.self, from: Data(contentsOf: stateURL))
      },
      saveState: { state in
        guard let state else {
          try? FileManager.default.removeItem(at: directory)
          return
        }
        try prepare()
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
      },
      saveFile: { name, data in
        try prepare()
        try data.write(to: file(name), options: .atomic)
      },
      loadFile: { name in
        let url = file(name)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
          return nil
        }
        return try Data(contentsOf: url)
      },
      removeFile: { name in try? FileManager.default.removeItem(at: file(name)) }
    )
  }
}

extension HealthBackfillStorage: DependencyKey {
  public static var liveValue: Self {
    .directory(liveDirectory(for: .current()))
  }

  /// The backfill state's folder for `environment` (851-2977): `HealthBackfill` in Application
  /// Support, as always, on a device, which only uses prod, and a folder per server inside it on
  /// a simulator (`HealthBackfill/Servers/api.staging.lil.tech`), so switching servers keeps
  /// each one's backfill, and signing out of one resets only its own.
  static func liveDirectory(
    for environment: APIEnvironment,
    allowsOverride: Bool = APIEnvironment.allowsOverride,
    applicationSupport: URL = .applicationSupportDirectory
  ) -> URL {
    environment.localDirectory(
      in: applicationSupport.appending(path: "HealthBackfill", directoryHint: .isDirectory),
      allowsOverride: allowsOverride)
  }

  public static var testValue: Self { .inMemory() }
}

public struct HealthBatchUploader: Sendable {
  /// Uploads a batch file under its ID. Returns once the server accepted it; uploading the same
  /// ID again is safe.
  public var upload: @Sendable (_ id: String, _ file: Data) async throws -> Void

  public init(upload: @escaping @Sendable (_ id: String, _ file: Data) async throws -> Void) {
    self.upload = upload
  }

  public struct Rejected: LocalizedError, Equatable {
    public let statusCode: Int

    public var errorDescription: String? {
      "lil health's server couldn't take this upload (HTTP \(statusCode))."
    }

    /// The server failing for a moment (e.g. the user's store busy or restarting), so the upload
    /// is worth trying again shortly. Not a 500: that's usually the server failing on this very
    /// upload, every time.
    public var isTransient: Bool { [502, 503, 504].contains(statusCode) }
  }

  /// Too many requests (a 429): nothing more uploads for `retryAfter` seconds.
  public struct RateLimited: LocalizedError, Equatable {
    public let retryAfter: TimeInterval

    public init(retryAfter: TimeInterval) {
      self.retryAfter = retryAfter
    }

    public var errorDescription: String? { "Uploading paused for a moment" }
  }

  /// The account's storage is full (a 507): nothing more uploads until there's room.
  public struct StorageFull: LocalizedError, Equatable {
    public init() {}

    public var errorDescription: String? { "Your lil account's storage is full" }
  }

  /// The user hasn't consented to the current privacy policy (a 403), so new Health data isn't
  /// taken (`GET /v1/me/consents/health`).
  public struct ConsentRequired: LocalizedError, Equatable {
    public init() {}

    public var errorDescription: String? { "lil health needs your consent to upload Health data" }
  }
}

extension HealthBatchUploader: DependencyKey {
  /// Through the API client, whose middleware adds the token and retries once after a 401. Not a
  /// background `URLSession`: iOS schedules transfers started in the background at its own
  /// discretion, too late for HealthKit's and background tasks' deadlines. An upload cut off by
  /// suspension is just sent again, which batch IDs make safe.
  public static var liveValue: Self {
    @Dependency(\.api) var api
    return Self { id, file in
      let output = try await api.healthUploadBatch(
        path: .init(id: id), body: .applicationGzip(HTTPBody(file)))
      switch output {
      case .accepted: return
      case .unauthorized: throw Rejected(statusCode: 401)
      case .contentTooLarge: throw Rejected(statusCode: 413)
      case .serviceUnavailable: throw Rejected(statusCode: 503)
      case .tooManyRequests(let response):
        let seconds = Components.Schemas.TooManyRequests.retryAfterSeconds {
          try response.body.json
        }
        throw RateLimited(retryAfter: TimeInterval(seconds))
      case .forbidden: throw ConsentRequired()
      case .code507: throw StorageFull()
      case .undocumented(let statusCode, _): throw Rejected(statusCode: statusCode)
      }
    }
  }

  public static var testValue: Self {
    Self { _, _ in reportIssue("Unimplemented: @Dependency(\\.healthBatchUploader).upload") }
  }
}

extension DependencyValues {
  /// Counts the records the backfill has left, for its progress.
  public var healthRecordCounter: HealthRecordCounter {
    get { self[HealthRecordCounter.self] }
    set { self[HealthRecordCounter.self] = newValue }
  }
}

/// Counts a type's samples after an anchor, so the upload's progress has a real total. Much
/// faster than the upload: nothing is encoded or sent.
public struct HealthRecordCounter: Sendable {
  public var count: @Sendable (_ type: HealthBackfillType, _ anchor: Data?) async throws -> Int

  public init(
    count: @escaping @Sendable (_ type: HealthBackfillType, _ anchor: Data?) async throws -> Int
  ) {
    self.count = count
  }

  /// Counting isn't available (tests that don't count): the total stays unknown.
  public struct Unavailable: Error {}

  /// Objects per counting query: enough to be quick, few enough to keep memory down while the
  /// upload runs alongside.
  static let pageSize = 5_000
}

extension HealthRecordCounter: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self { type, anchorData in
      guard let sampleType = type.sampleType else { throw HealthReader.UnknownType(id: type.id) }
      var anchor = try HealthReader.unarchiveAnchor(anchorData)
      var count = 0
      while true {
        try Task.checkCancellation()
        let result = try await HealthReader.anchoredPage(
          sampleType, after: anchor, limit: pageSize, in: store)
        count += result.addedSamples.count
        anchor = result.newAnchor
        if result.addedSamples.count + result.deletedObjects.count < pageSize { return count }
      }
    }
  }

  /// Not reported as unimplemented: counting is best-effort, and most backfill tests don't count.
  public static var testValue: Self {
    Self { _, _ in throw Unavailable() }
  }
}

/// Uploads a blob (`PUT /v1/health/blobs/{sha256}`) before the batches whose rows refer to it.
/// Failures are `HealthBatchUploader`'s errors, so the backfill treats them alike.
public struct HealthBlobUploader: Sendable {
  /// Uploads `data` under its SHA-256. Uploading a blob the server has already is safe.
  public var upload: @Sendable (_ sha256: String, _ data: Data) async throws -> Void

  public init(upload: @escaping @Sendable (_ sha256: String, _ data: Data) async throws -> Void) {
    self.upload = upload
  }
}

extension HealthBlobUploader: DependencyKey {
  /// Through the API client, like batches (`HealthBatchUploader.liveValue`).
  public static var liveValue: Self {
    @Dependency(\.api) var api
    return Self { sha256, data in
      let output = try await api.healthUploadBlob(
        path: .init(sha256: sha256), body: .binary(HTTPBody(data)))
      switch output {
      case .ok: return
      case .badRequest: throw HealthBatchUploader.Rejected(statusCode: 400)
      case .unauthorized: throw HealthBatchUploader.Rejected(statusCode: 401)
      case .forbidden: throw HealthBatchUploader.ConsentRequired()
      case .contentTooLarge: throw HealthBatchUploader.Rejected(statusCode: 413)
      case .serviceUnavailable: throw HealthBatchUploader.Rejected(statusCode: 503)
      case .tooManyRequests(let response):
        let seconds = Components.Schemas.TooManyRequests.retryAfterSeconds {
          try response.body.json
        }
        throw HealthBatchUploader.RateLimited(retryAfter: TimeInterval(seconds))
      case .code507: throw HealthBatchUploader.StorageFull()
      case .undocumented(let statusCode, _):
        throw HealthBatchUploader.Rejected(statusCode: statusCode)
      }
    }
  }

  public static var testValue: Self {
    Self { _, _ in reportIssue("Unimplemented: @Dependency(\\.healthBlobUploader).upload") }
  }
}

extension DependencyValues {
  /// Asks the server how uploaded batches went.
  public var healthBatchStatusReader: HealthBatchStatusReader {
    get { self[HealthBatchStatusReader.self] }
    set { self[HealthBatchStatusReader.self] = newValue }
  }
}

/// What the server did with an uploaded batch (`POST /v1/health/batches/status`, 851-4151): the
/// queue applies it after the upload is accepted, and may refuse some of its lines, or fail it
/// whole.
public struct HealthBatchStatus: Equatable, Sendable {
  public var id: String
  /// `queued`, `applying`, `applied` or `failed`.
  public var status: String
  /// Lines refused, of an applied batch.
  public var rejected: Int
  /// The first 100 of them, with the records they were (when the server could tell).
  public var rejectedLines: [RejectedLine]
  /// Why a failed batch failed.
  public var failure: String?

  public init(
    id: String, status: String, rejected: Int = 0, rejectedLines: [RejectedLine] = [],
    failure: String? = nil
  ) {
    self.id = id
    self.status = status
    self.rejected = rejected
    self.rejectedLines = rejectedLines
    self.failure = failure
  }

  public struct RejectedLine: Equatable, Sendable {
    public var entity: String?
    public var id: String?

    public init(entity: String?, id: String?) {
      self.entity = entity
      self.id = id
    }
  }
}

public struct HealthBatchStatusReader: Sendable {
  /// The statuses of up to `maxBatches` batches, those the server never received left out.
  public var statuses: @Sendable (_ ids: [String]) async throws -> [HealthBatchStatus]

  public init(
    statuses: @escaping @Sendable (_ ids: [String]) async throws -> [HealthBatchStatus]
  ) {
    self.statuses = statuses
  }

  /// The most the server answers for at once.
  public static let maxBatches = 100
}

extension HealthBatchStatusReader: DependencyKey {
  public static var liveValue: Self {
    @Dependency(\.api) var api
    return Self { ids in
      let output = try await api.healthBatchStatus(body: .json(.init(ids: ids)))
      switch output {
      case .ok(let response):
        return try response.body.json.batches.map { batch in
          HealthBatchStatus(
            id: batch.id, status: batch.status, rejected: batch.rejected ?? 0,
            rejectedLines: (batch.rejectedLines ?? []).map {
              .init(entity: $0.entity, id: $0.id)
            },
            failure: batch.failure)
        }
      case .unauthorized: throw HealthBatchUploader.Rejected(statusCode: 401)
      case .serviceUnavailable: throw HealthBatchUploader.Rejected(statusCode: 503)
      case .tooManyRequests(let response):
        let seconds = Components.Schemas.TooManyRequests.retryAfterSeconds {
          try response.body.json
        }
        throw HealthBatchUploader.RateLimited(retryAfter: TimeInterval(seconds))
      case .undocumented(let statusCode, _):
        throw HealthBatchUploader.Rejected(statusCode: statusCode)
      }
    }
  }

  /// Every batch applied whole, so tests that don't check batches needn't answer: not reported
  /// as unimplemented.
  public static var testValue: Self {
    Self { ids in ids.map { HealthBatchStatus(id: $0, status: "applied") } }
  }
}
