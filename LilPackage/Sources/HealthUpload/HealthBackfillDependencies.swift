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
  /// Mind, scored assessments, audiograms, ECGs, heartbeat series, vision prescriptions (those the
  /// person shared, one by one), and the correlations, which are read through their component
  /// types.
  public static func all(availableOn version: IOSVersion) -> [Self] {
    HealthCatalog.types(availableOn: version).compactMap { type in
      switch (type.kind, type.readAuthorization) {
      case (.quantity, .standard), (.category, .standard), (.workout, .standard),
        (.stateOfMind, .standard), (.scoredAssessment, .standard), (.audiogram, .standard),
        (.electrocardiogram, .standard), (.heartbeatSeries, .standard),
        (.workoutRoute, .standard), (.visionPrescription, .perObject):
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
    case .visionPrescription: return HealthEncoder.visionPrescriptionEntity
    default: return HealthEncoder.sampleEntity
    }
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

  public init(mutations: [HealthMutation], blobs: [Data] = [], anchor: Data, hasMore: Bool) {
    self.mutations = mutations
    self.blobs = blobs
    self.anchor = anchor
    self.hasMore = hasMore
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

  public init(
    page:
      @escaping @Sendable (_ type: HealthBackfillType, _ anchor: Data?, _ limit: Int) async throws
      -> HealthPage
  ) {
    self.page = page
  }

  struct UnknownType: Error {
    let id: String
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
    return Self { type, anchorData, limit in
      guard let sampleType = type.sampleType else { throw UnknownType(id: type.id) }
      let result = try await anchoredPage(
        sampleType, after: try unarchiveAnchor(anchorData), limit: limit, in: store)
      var mutations: [HealthMutation] = []
      var blobs: [Data] = []
      for sample in result.addedSamples {
        // One sample that can't be encoded is reported and skipped, so it can't stop the rest.
        do {
          if let correlation = sample as? HKCorrelation {
            mutations += try HealthEncoder.correlation(correlation)
          } else if let workout = sample as? HKWorkout {
            mutations.append(HealthEncoder.workout(WorkoutRecord(workout)))
          } else if let log = sample as? HKStateOfMind {
            mutations.append(HealthEncoder.stateOfMind(log))
          } else if let assessment = sample as? HKScoredAssessment {
            mutations.append(try HealthEncoder.scoredAssessment(assessment))
          } else if let audiogram = sample as? HKAudiogramSample {
            mutations.append(HealthEncoder.audiogram(audiogram))
          } else if let prescription = sample as? HKVisionPrescription {
            mutations.append(HealthEncoder.visionPrescription(prescription))
          } else if let route = sample as? HKWorkoutRoute {
            let (mutation, blob) = HealthEncoder.workoutRoute(
              try await WorkoutRouteRecord(route, store: store))
            mutations.append(mutation)
            if let blob { blobs.append(blob) }
          } else if let series = sample as? HKHeartbeatSeriesSample {
            mutations.append(
              HealthEncoder.heartbeatSeries(try await HeartbeatSeriesRecord(series, store: store)))
          } else if let ecg = sample as? HKElectrocardiogram {
            let (mutation, blob) = HealthEncoder.electrocardiogram(
              try await ElectrocardiogramRecord(ecg, store: store))
            mutations.append(mutation)
            if let blob { blobs.append(blob) }
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
          // the type's reads kept failing.
          guard type.skipsUnreadableSeries else { throw error }
          reportIssue(error)
        } catch {
          reportIssue(error)
        }
      }
      let entity = type.entity
      mutations += result.deletedObjects.map { .delete(entity, id: HealthEncoder.id($0.uuid)) }
      return HealthPage(
        mutations: mutations, blobs: blobs,
        anchor: try NSKeyedArchiver.archivedData(
          withRootObject: result.newAnchor, requiringSecureCoding: true),
        hasMore: result.addedSamples.count + result.deletedObjects.count >= limit)
    }
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

  /// In memory, for tests and previews.
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

  /// Files in `directory`: the state as JSON, each batch file, and each blob.
  public static func directory(_ directory: URL) -> Self {
    let stateURL = directory.appending(path: "state.json")
    let file = { @Sendable (name: String) in
      directory.appending(path: name.hasPrefix("blob-") ? "\(name).bin" : "\(name).ndjson.gz")
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
    .directory(URL.applicationSupportDirectory.appending(path: "HealthBackfill"))
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

    public var errorDescription: String? { "The server answered HTTP \(statusCode)" }

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

  /// Counting isn't available (tests that don't count, previews): the total stays unknown.
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
