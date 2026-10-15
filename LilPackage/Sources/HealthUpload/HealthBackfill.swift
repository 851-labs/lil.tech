public import Dependencies
public import Foundation
import HealthCatalog
import HealthKitAccess
import IssueReporting

/// What the backfill has done and is doing. Saved after every step, so a killed app resumes
/// where it was.
public struct HealthBackfillState: Codable, Equatable, Sendable {
  /// Each type's anchor: everything before it is on the server.
  public var anchors: [String: Data] = [:]
  /// Types whose history is all uploaded. Incremental sync continues from their anchors.
  public var finished: Set<String> = []
  /// Types that had nothing at the last run: no data, or no permission to read it (HealthKit
  /// doesn't say which). They keep no anchor, so if access is granted later their whole history
  /// is read, and every run checks them again.
  public var empty: Set<String> = []
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
    /// Types with nothing left to upload, as far as anyone can tell.
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
  private var resetting: Task<Void, Never>?

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
      finishedTypes: state.map { Self.doneTypes(types, $0) } ?? 0,
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
  /// uploading fails, or if it's cancelled, which cancels the run. A second call while one runs
  /// joins it.
  public func run() async throws {
    // A run asked for during a reset starts after it, from nothing.
    while let resetting { await resetting.value }
    let task: Task<Void, any Error>
    if let running {
      task = running
    } else {
      task = Task { try await backfill() }
      running = task
    }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// Forgets everything, e.g. on signing out: the next account starts from the beginning.
  public func reset() async {
    if let resetting { return await resetting.value }
    let task = Task {
      running?.cancel()
      _ = try? await running?.value
      // Even if the state can't be read, everything goes: `saveState(nil)` removes the files.
      if let pending = (try? storage.loadState())??.pending {
        for batch in pending.batches { try? storage.removeFile(batch) }
      }
      withErrorReporting { try storage.saveState(nil) }
      let total = types.count
      update {
        $0 = Progress(finishedTypes: 0, totalTypes: total, uploadedRecords: 0, isRunning: false)
      }
    }
    resetting = task
    await task.value
    resetting = nil
  }

  private func backfill() async throws {
    defer { running = nil }
    update {
      $0.isRunning = true
      $0.failure = nil
    }
    do {
      var state = try loadState()
      if let pending = state.pending {
        try await upload(pending, &state)
      }
      for type in types where !state.finished.contains(type.id) {
        var isLast = false
        while !isLast {
          try Task.checkCancellation()
          let anchor = state.anchors[type.id]
          let page = try await reader.page(type, anchor, Self.pageSize)
          if anchor == nil, page.mutations.isEmpty, !page.hasMore {
            // Nothing readable yet: keep no anchor, and check again next time.
            state.empty.insert(type.id)
            try storage.saveState(state)
            updateCounts(state)
            break
          }
          state.empty.remove(type.id)
          let (pending, files) = try write(page, of: type)
          // The page is saved before its files, so a kill in between leaves no orphans: the
          // missing files make the next run read the page again.
          state.pending = pending
          try storage.saveState(state)
          for (batch, file) in zip(pending.batches, files) { try storage.saveFile(batch, file) }
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

  /// The saved state, or a fresh start if it can't be read (e.g. it's corrupt).
  private func loadState() throws -> HealthBackfillState {
    do {
      return try storage.loadState() ?? HealthBackfillState()
    } catch is DecodingError {
      reportIssue("Starting the backfill over: its state couldn't be read")
      try storage.saveState(nil)
      return HealthBackfillState()
    }
  }

  /// Writes a page's mutations to batch files, in memory. A record too long for the server is
  /// skipped and reported, so it can't stop the backfill.
  private func write(_ page: HealthPage, of type: HealthBackfillType) throws
    -> (HealthBackfillState.PendingPage, [Data])
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
    let pending = HealthBackfillState.PendingPage(
      type: type.id, anchor: page.anchor, isLast: !page.hasMore,
      batches: files.map { _ in uuid().uuidString.lowercased() }, records: page.mutations.count)
    return (pending, files)
  }

  /// Uploads a page's batches, then commits its anchor.
  private func upload(
    _ pending: HealthBackfillState.PendingPage, _ state: inout HealthBackfillState
  ) async throws {
    for batch in pending.batches {
      try Task.checkCancellation()
      guard let file = try storage.loadFile(batch) else {
        // The run stopped before writing it: drop the page, and read it again from the anchor
        // before it. Records are keyed by UUID, so whatever already went up is harmless.
        for batch in pending.batches { try storage.removeFile(batch) }
        state.pending = nil
        try storage.saveState(state)
        return
      }
      try await uploader.upload(batch, file)
    }
    state.anchors[pending.type] = pending.anchor
    if pending.isLast { state.finished.insert(pending.type) }
    state.pending = nil
    state.uploadedRecords += pending.records
    try storage.saveState(state)
    for batch in pending.batches { try storage.removeFile(batch) }
    updateCounts(state)
  }

  private static func doneTypes(_ types: [HealthBackfillType], _ state: HealthBackfillState)
    -> Int
  {
    types.filter { state.finished.contains($0.id) || state.empty.contains($0.id) }.count
  }

  private func updateCounts(_ state: HealthBackfillState) {
    let done = Self.doneTypes(types, state)
    let uploaded = state.uploadedRecords
    update {
      $0.finishedTypes = done
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
    HealthBackfill(types: HealthBackfillType.all(availableOn: HealthAuthorization.currentVersion))
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
