public import Dependencies
public import Foundation
import HealthCatalog
import IssueReporting

/// What the backfill has done and is doing. Saved after every step, so a killed app resumes
/// where it was.
public struct HealthBackfillState: Codable, Equatable, Sendable {
  /// Each type's anchor: everything before it is on the server.
  public var anchors: [String: Data] = [:]
  /// Types whose history is all uploaded. Incremental sync continues from their anchors.
  public var finished: Set<String> = []
  /// The page being uploaded, if any.
  public var pending: PendingPage?
  /// Records uploaded so far.
  public var uploadedRecords = 0

  public init() {}

  /// A page written to batch files. Its anchor is committed once every file is accepted.
  public struct PendingPage: Codable, Equatable, Sendable {
    public var type: String
    public var anchor: Data
    /// Whether this was the type's last page.
    public var isLast: Bool
    /// Batch IDs, which are also the files' names.
    public var batches: [String]
    public var records: Int
  }
}

/// Uploads a user's whole Health history (`docs/SYNC.md`): every type, a page at a time, with
/// anchored queries. A page's anchor is only saved once all of its batches are accepted, so if
/// the app is killed, the page is uploaded again (batch IDs make that safe) and nothing is
/// skipped.
public actor HealthBackfill {
  /// Objects per anchored query. Pages are split into batch files below the server's limits.
  static let pageSize = 2000

  public struct Progress: Equatable, Sendable {
    public var finishedTypes: Int
    public var totalTypes: Int
    public var uploadedRecords: Int
    public var isRunning: Bool
    /// Why the last run stopped early, if it did.
    public var failure: String?

    public var isFinished: Bool { finishedTypes == totalTypes }
  }

  private let types: [HealthBackfillType]
  private let reader: HealthReader
  private let storage: HealthBackfillStorage
  private let uploader: HealthBatchUploader
  private let uuid: UUIDGenerator
  private var progress: Progress
  private var observers: [UUID: AsyncStream<Progress>.Continuation] = [:]
  private var running: Task<Void, any Error>?

  public init(types: [HealthBackfillType]) {
    @Dependency(\.healthReader) var reader
    @Dependency(\.healthBackfillStorage) var storage
    @Dependency(\.healthBatchUploader) var uploader
    @Dependency(\.uuid) var uuid
    self.types = types
    self.reader = reader
    self.storage = storage
    self.uploader = uploader
    self.uuid = uuid
    let state = (try? storage.loadState()) ?? nil
    self.progress = Progress(
      finishedTypes: types.filter { state?.finished.contains($0.id) == true }.count,
      totalTypes: types.count, uploadedRecords: state?.uploadedRecords ?? 0, isRunning: false)
  }

  /// The progress now and after every change.
  public func progressUpdates() -> AsyncStream<Progress> {
    let (stream, continuation) = AsyncStream<Progress>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    observers[id] = continuation
    continuation.yield(progress)
    continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    return stream
  }

  /// Uploads everything not uploaded yet. Returns when every type is done; throws if reading or
  /// uploading fails, or if it's cancelled. A second call while one runs waits for it.
  public func run() async throws {
    if let running { return try await running.value }
    let task = Task { try await backfill() }
    running = task
    defer { running = nil }
    try await task.value
  }

  /// Forgets everything, e.g. on signing out: the next account starts from the beginning.
  public func reset() async throws {
    running?.cancel()
    _ = try? await running?.value
    if let pending = try storage.loadState()?.pending {
      for batch in pending.batches { try storage.removeFile(batch) }
    }
    try storage.saveState(nil)
    update {
      $0 = Progress(finishedTypes: 0, totalTypes: types.count, uploadedRecords: 0, isRunning: false)
    }
  }

  private func backfill() async throws {
    update {
      $0.isRunning = true
      $0.failure = nil
    }
    do {
      var state = try storage.loadState() ?? HealthBackfillState()
      if let pending = state.pending {
        try await upload(pending, &state)
      }
      for type in types where !state.finished.contains(type.id) {
        var isLast = false
        while !isLast {
          try Task.checkCancellation()
          let page = try await reader.page(type, state.anchors[type.id], Self.pageSize)
          let pending = try write(page, of: type)
          state.pending = pending
          try storage.saveState(state)
          try await upload(pending, &state)
          isLast = pending.isLast
        }
      }
      update { $0.isRunning = false }
    } catch {
      update {
        $0.isRunning = false
        $0.failure = error is CancellationError ? nil : error.localizedDescription
      }
      throw error
    }
  }

  /// Writes a page's mutations to batch files. A record too long for the server is skipped and
  /// reported, so it can't stop the backfill.
  private func write(_ page: HealthPage, of type: HealthBackfillType) throws
    -> HealthBackfillState.PendingPage
  {
    var writer = HealthBatchWriter()
    var files: [Data] = []
    for mutation in page.mutations {
      do {
        if let file = try writer.append(mutation) { files.append(file) }
      } catch let error as HealthBatchWriter.LineTooLong {
        reportIssue(error)
      }
    }
    if let file = try writer.finish() { files.append(file) }
    let batches = try files.map { file in
      let id = uuid().uuidString.lowercased()
      try storage.saveFile(id, file)
      return id
    }
    return HealthBackfillState.PendingPage(
      type: type.id, anchor: page.anchor, isLast: !page.hasMore, batches: batches,
      records: page.mutations.count)
  }

  /// Uploads a page's batches, then commits its anchor.
  private func upload(
    _ pending: HealthBackfillState.PendingPage, _ state: inout HealthBackfillState
  ) async throws {
    for batch in pending.batches {
      try Task.checkCancellation()
      // A missing file was uploaded and removed by a run that stopped before committing.
      guard let file = try storage.loadFile(batch) else { continue }
      try await uploader.upload(batch, file)
    }
    state.anchors[pending.type] = pending.anchor
    if pending.isLast { state.finished.insert(pending.type) }
    state.pending = nil
    state.uploadedRecords += pending.records
    try storage.saveState(state)
    for batch in pending.batches { try storage.removeFile(batch) }
    let finished = types.filter { state.finished.contains($0.id) }.count
    let uploaded = state.uploadedRecords
    update {
      $0.finishedTypes = finished
      $0.uploadedRecords = uploaded
    }
  }

  private func update(_ change: (inout Progress) -> Void) {
    change(&progress)
    for observer in observers.values { observer.yield(progress) }
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }
}

extension DependencyValues {
  /// The iPhone's Health backfill.
  public var healthBackfill: HealthBackfill {
    get { self[HealthBackfillKey.self] }
    set { self[HealthBackfillKey.self] = newValue }
  }
}

private enum HealthBackfillKey: DependencyKey {
  static var liveValue: HealthBackfill {
    #if os(iOS)
      let version = ProcessInfo.processInfo.operatingSystemVersion
      let ios = IOSVersion.ios(version.majorVersion, version.minorVersion)
    #else
      let ios = IOSVersion.ios(26)
    #endif
    return HealthBackfill(types: HealthBackfillType.all(availableOn: ios))
  }

  /// Nothing to back up, so features can start it in tests.
  static var testValue: HealthBackfill {
    withDependencies {
      $0.uuid = .incrementing
    } operation: {
      HealthBackfill(types: [])
    }
  }
}
