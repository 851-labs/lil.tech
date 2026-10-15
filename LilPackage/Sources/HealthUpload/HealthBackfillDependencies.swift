public import Dependencies
public import Foundation
public import HealthCatalog
import HealthKit
import HealthKitAccess
import LilAPI
import OpenAPIRuntime

/// A HealthKit type the backfill pages through with anchored queries.
public struct HealthBackfillType: Hashable, Sendable {
  public let id: String
  public let isCorrelation: Bool

  public init(id: String, isCorrelation: Bool = false) {
    self.id = id
    self.isCorrelation = isCorrelation
  }

  /// Every quantity and category type the app can read, and the correlations, which are read
  /// through their component types.
  public static func all(availableOn version: IOSVersion) -> [Self] {
    HealthCatalog.types(availableOn: version).compactMap { type in
      switch (type.kind, type.readAuthorization) {
      case (.quantity, .standard), (.category, .standard): Self(id: type.id)
      case (.correlation, _): Self(id: type.id, isCorrelation: true)
      default: nil
      }
    }
  }
}

/// One page of an anchored query, already encoded.
public struct HealthPage: Sendable {
  public var mutations: [HealthMutation]
  /// Where the next page starts, archived.
  public var anchor: Data
  public var hasMore: Bool

  public init(mutations: [HealthMutation], anchor: Data, hasMore: Bool) {
    self.mutations = mutations
    self.anchor = anchor
    self.hasMore = hasMore
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
}

extension HealthReader: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self { type, anchorData, limit in
      let sampleType: HKSampleType? =
        type.isCorrelation
        ? HKObjectType.correlationType(forIdentifier: .init(rawValue: type.id))
        : HealthCatalog.type(id: type.id)?.objectType as? HKSampleType
      guard let sampleType else { throw UnknownType(id: type.id) }
      let anchor = try anchorData.flatMap {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
      }
      let descriptor = HKAnchoredObjectQueryDescriptor(
        predicates: [.sample(type: sampleType)], anchor: anchor, limit: limit)
      let result = try await descriptor.result(for: store)
      var mutations: [HealthMutation] = []
      for sample in result.addedSamples {
        if let correlation = sample as? HKCorrelation {
          mutations += try HealthEncoder.correlation(correlation)
        } else {
          mutations.append(try HealthEncoder.sample(sample))
        }
      }
      mutations += result.deletedObjects.map {
        HealthEncoder.deleted($0.uuid, correlation: type.isCorrelation)
      }
      return HealthPage(
        mutations: mutations,
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

  /// Files in `directory`: the state as JSON, and each batch file.
  public static func directory(_ directory: URL) -> Self {
    let stateURL = directory.appending(path: "state.json")
    let file = { @Sendable (name: String) in directory.appending(path: "\(name).ndjson.gz") }
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

  public struct Rejected: Error, Equatable {
    public let statusCode: Int
  }
}

extension HealthBatchUploader: DependencyKey {
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
      case .undocumented(let statusCode, _): throw Rejected(statusCode: statusCode)
      }
    }
  }

  public static var testValue: Self {
    Self { _, _ in reportIssue("Unimplemented: @Dependency(\\.healthBatchUploader).upload") }
  }
}
