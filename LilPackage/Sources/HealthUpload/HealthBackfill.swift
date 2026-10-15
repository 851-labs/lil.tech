public import Dependencies
public import Foundation
import HealthCatalog
import HealthKitAccess
import IssueReporting
import OpenAPIRuntime

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
  /// For cumulative types, the earliest time whose 30-minute sums need uploading again.
  public var statisticsFrom: [String: Date] = [:]
  /// When each cumulative type's sums last went up.
  public var statisticsUploadedAt: [String: Date] = [:]
  /// Records uploaded per type.
  public var uploadedByType: [String: Int] = [:]
  /// When something last went up.
  public var lastUploadAt: Date?

  public init() {}

  /// Fields added later may be missing from saved state.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    anchors = try container.decodeIfPresent([String: Data].self, forKey: .anchors) ?? [:]
    finished = try container.decodeIfPresent(Set<String>.self, forKey: .finished) ?? []
    empty = try container.decodeIfPresent(Set<String>.self, forKey: .empty) ?? []
    pending = try container.decodeIfPresent(PendingPage.self, forKey: .pending)
    uploadedRecords = try container.decodeIfPresent(Int.self, forKey: .uploadedRecords) ?? 0
    statisticsFrom =
      try container.decodeIfPresent([String: Date].self, forKey: .statisticsFrom) ?? [:]
    statisticsUploadedAt =
      try container.decodeIfPresent([String: Date].self, forKey: .statisticsUploadedAt) ?? [:]
    uploadedByType =
      try container.decodeIfPresent([String: Int].self, forKey: .uploadedByType) ?? [:]
    lastUploadAt = try container.decodeIfPresent(Date.self, forKey: .lastUploadAt)
  }

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

/// Uploads a user's Health data (`docs/SYNC.md`): first the whole history (the backfill), then
/// what changes, every type a page at a time with anchored queries. A page's anchor is only
/// saved once all of its batches are accepted, so if the app is killed, the page is uploaded
/// again (batch IDs make that safe) and nothing is skipped.
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
    /// Whether that was because there's no network: paused rather than failed.
    public var isOffline = false
    /// Whether that was because the account's storage is full, so nothing more uploads.
    public var isStorageFull = false
    /// Each type's progress, by HealthKit type identifier.
    public var types: [String: TypeProgress] = [:]
    public var lastUploadAt: Date?

    public init(
      finishedTypes: Int, totalTypes: Int, uploadedRecords: Int, isRunning: Bool,
      failure: String? = nil, isOffline: Bool = false, isStorageFull: Bool = false,
      types: [String: TypeProgress] = [:], lastUploadAt: Date? = nil
    ) {
      self.finishedTypes = finishedTypes
      self.totalTypes = totalTypes
      self.uploadedRecords = uploadedRecords
      self.isRunning = isRunning
      self.failure = failure
      self.isOffline = isOffline
      self.isStorageFull = isStorageFull
      self.types = types
      self.lastUploadAt = lastUploadAt
    }

    public var isFinished: Bool { finishedTypes == totalTypes }
  }

  public struct TypeProgress: Equatable, Sendable {
    /// Its history is all uploaded, or it has nothing to upload.
    public var isDone: Bool
    public var uploadedRecords: Int

    public init(isDone: Bool, uploadedRecords: Int) {
      self.isDone = isDone
      self.uploadedRecords = uploadedRecords
    }
  }

  private let types: [HealthBackfillType]
  private let reader: HealthReader
  private let storage: HealthBackfillStorage
  private let uploader: HealthBatchUploader
  private let statisticsReader: HealthStatisticsReader
  private let uuid: UUIDGenerator
  private let now: @Sendable () -> Date
  private var progress: Progress
  private var observers: [UUID: AsyncStream<Progress>.Continuation] = [:]
  /// The work loop running, with an ID so only it clears itself.
  private var running: (id: Int, task: Task<Void, any Error>)?
  private var nextRunID = 0
  private var resetting: Task<Void, Never>?
  /// Work asked for: every type (the backfill, and catching up), and types whose changes to
  /// upload.
  private var syncAllRequested = false
  var requestedTypes: Set<String> = []

  public init(types: [HealthBackfillType]) {
    @Dependency(\.healthReader) var reader
    @Dependency(\.healthBackfillStorage) var storage
    @Dependency(\.healthBatchUploader) var uploader
    @Dependency(\.uuid) var uuid
    @Dependency(\.healthStatisticsReader) var statisticsReader
    @Dependency(\.date) var date
    self.types = types
    self.reader = reader
    self.storage = storage
    self.uploader = uploader
    self.statisticsReader = statisticsReader
    self.uuid = uuid
    self.now = { date.now }
    let state = (try? storage.loadState()) ?? nil
    self.progress = Self.progress(types, state ?? HealthBackfillState())
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

  /// Uploads everything not on the server: the rest of the backfill, and anything that changed
  /// since each type's anchor, in case a change was missed (e.g. the app was killed before
  /// uploading it). Returns when that's done. Throws the first failure; types that failed are
  /// tried again on the next call, and the others go ahead. A second call while one runs joins it.
  public func run() async throws {
    syncAllRequested = true
    try await work()
  }

  /// Uploads what changed in `types` (HealthKit type identifiers) since their anchors: additions
  /// and deletions. Calls during a run are picked up by it, so bursts become one upload. Does
  /// nothing until `run()` started a backfill: after signing out, changes wait for the next
  /// account's backfill.
  public func syncChanges(of types: Set<String>) async throws {
    requestedTypes.formUnion(types)
    try await work()
  }

  /// Starts the work loop, or joins the one running, and waits for it. The loop is shared, so
  /// cancelling a caller doesn't stop it; `reset()` does.
  private func work() async throws {
    // A run asked for during a reset starts after it.
    while let resetting { await resetting.value }
    if let running, !running.task.isCancelled { return try await running.task.value }
    nextRunID += 1
    let id = nextRunID
    let task = Task { try await loop(id) }
    running = (id, task)
    try await task.value
  }

  /// Stops the run, e.g. when a background task's time is up. Everything is kept: the pending
  /// page goes up on the next run. Waits until it has stopped.
  public func pause() async {
    guard let running else { return }
    running.task.cancel()
    _ = try? await running.task.value
  }

  /// Forgets everything, e.g. on signing out: the next account starts from the beginning.
  public func reset() async {
    if let resetting { return await resetting.value }
    let task = Task {
      syncAllRequested = false
      requestedTypes = []
      running?.task.cancel()
      _ = try? await running?.task.value
      // Even if the state can't be read, everything goes: `saveState(nil)` removes the files.
      if let pending = (try? storage.loadState())??.pending {
        for batch in pending.batches { try? storage.removeFile(batch) }
      }
      withErrorReporting { try storage.saveState(nil) }
      let reset = Self.progress(types, HealthBackfillState())
      update { $0 = reset }
    }
    resetting = task
    await task.value
    resetting = nil
  }

  /// Does whatever was asked for, including what's asked for while it runs.
  private func loop(_ id: Int) async throws {
    // In the same turn as the last check for work, so a request can't join a finished loop.
    defer { if running?.id == id { running = nil } }
    update { $0.isRunning = true }
    var failures: [String: any Error] = [:]
    var syncedAll = false
    do {
      guard var state = try loadState(startingBackfill: syncAllRequested) else {
        // No backfill yet (or signed out): changes wait for one.
        requestedTypes = []
        update { $0.isRunning = false }
        return
      }
      if let pending = state.pending {
        try await upload(pending, &state)
      }
      repeat {
        while syncAllRequested || !requestedTypes.isEmpty {
          let wanted: Set<String>
          if syncAllRequested {
            syncAllRequested = false
            syncedAll = true
            wanted = Set(types.map(\.id))
          } else {
            wanted = requestedTypes
          }
          requestedTypes = []
          for type in types where wanted.contains(type.id) && failures[type.id] == nil {
            do {
              try await sync(type, &state)
            } catch {
              try stopIfRunEnds(error)
              // One type can't hold up the rest. Its page is read again next time.
              failures[type.id] = error
              if let pending = state.pending, pending.type == type.id {
                for batch in pending.batches { try? storage.removeFile(batch) }
                state.pending = nil
                try storage.saveState(state)
              }
            }
          }
        }
        // Sums for every type that has some due, including ones from a resumed page.
        try await uploadAllStatistics(&state, skipping: Set(failures.keys))
        // Requests made while the sums went up are handled before the loop ends.
      } while syncAllRequested || !requestedTypes.isEmpty
    } catch {
      let paused = Task.isCancelled || error is CancellationError || error is HealthReader.Locked
      update {
        $0.isRunning = false
        if !paused {
          $0.failure = error.localizedDescription
          $0.isOffline = Self.isOffline(error)
          $0.isStorageFull = error is HealthBatchUploader.StorageFull
        }
      }
      throw paused && !(error is HealthReader.Locked) ? CancellationError() : error
    }
    // Tried again on the next call.
    requestedTypes.formUnion(failures.keys)
    // The first in type order, so the same failures always report the same way.
    let ordered = types.compactMap { failures[$0.id] }
    if let failure = ordered.first {
      update {
        $0.isRunning = false
        $0.failure = failure.localizedDescription
        $0.isOffline = ordered.allSatisfy(Self.isOffline)
        $0.isStorageFull = false
      }
      throw failure
    }
    update {
      $0.isRunning = false
      // A run that covered everything clears an earlier failure; one for a few changes doesn't.
      if syncedAll {
        $0.failure = nil
        $0.isOffline = false
        $0.isStorageFull = false
      }
    }
  }

  /// Rethrows the error if it ends the whole run rather than one type's sync: cancelled (a
  /// cancelled upload throws a URL error), the device is locked, or the account's storage is full,
  /// which every other upload would hit too. The pending page is kept.
  private func stopIfRunEnds(_ error: any Error) throws {
    if Task.isCancelled || error is CancellationError { throw CancellationError() }
    if let locked = error as? HealthReader.Locked { throw locked }
    if let full = error as? HealthBatchUploader.StorageFull { throw full }
  }

  /// Uploads a type's pages from its anchor until there are no more.
  private func sync(_ type: HealthBackfillType, _ state: inout HealthBackfillState) async throws {
    var isLast = false
    while !isLast {
      try Task.checkCancellation()
      let anchor = state.anchors[type.id]
      let page = try await reader.page(type, anchor, Self.pageSize)
      if page.mutations.isEmpty {
        if anchor == nil, !page.hasMore {
          // Nothing readable yet: keep no anchor, and check again next time.
          guard !state.empty.contains(type.id) else { return }
          state.empty.insert(type.id)
        } else {
          // Nothing changed: just move the anchor, without a pending page.
          state.anchors[type.id] = page.anchor
          if !page.hasMore { state.finished.insert(type.id) }
        }
        try storage.saveState(state)
        updateCounts(state)
        isLast = !page.hasMore
        continue
      }
      state.empty.remove(type.id)
      markStatistics(of: type, changedBy: page.mutations, &state)
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

  /// How far back from a type's last sums a change with deletions recomputes: a deleted
  /// object has no dates.
  static let deletionWindow: TimeInterval = 7 * 86_400
  /// The most recent part of every recompute uploads empty buckets too, so sums that are gone
  /// are overwritten. Older parts (e.g. the backfill's history) upload only buckets with data.
  static let zeroFillWindow: TimeInterval = 31 * 86_400
  /// Sums are read and uploaded this much at a time, and the progress saved after each.
  static let statisticsChunk: TimeInterval = 90 * 86_400
  /// Samples can be logged ahead of time (e.g. a planned meal), so sums run this far ahead.
  static let statisticsLookahead: TimeInterval = 86_400

  /// Notes which of a cumulative type's sums a page of changes affects.
  private func markStatistics(
    of type: HealthBackfillType, changedBy mutations: [HealthMutation],
    _ state: inout HealthBackfillState
  ) {
    guard !type.isCorrelation, HealthCatalog.type(id: type.id)?.aggregation?.isCumulative == true
    else { return }
    var earliest = state.statisticsFrom[type.id]
    for mutation in mutations {
      let from: Date
      if mutation.op == .delete {
        // Covers deletions caught up after the app was away, too.
        let lastSums = state.statisticsUploadedAt[type.id] ?? now()
        from = min(now(), lastSums).addingTimeInterval(-Self.deletionWindow)
      } else if case .number(let start)? = mutation.row?["startDate"] {
        from = Date(timeIntervalSince1970: start / 1000)
      } else {
        continue
      }
      earliest = min(earliest ?? from, from)
    }
    state.statisticsFrom[type.id] = earliest
  }

  /// Uploads the sums of every type that has some due, then this iPhone's statistics status. A
  /// failure is kept for the next run and doesn't count against the type's samples.
  private func uploadAllStatistics(
    _ state: inout HealthBackfillState, skipping failed: Set<String>
  ) async throws {
    var uploaded = false
    for type in types where state.statisticsFrom[type.id] != nil && !failed.contains(type.id) {
      do {
        try await uploadStatistics(of: type, &state)
        uploaded = true
      } catch {
        try stopIfRunEnds(error)
        reportIssue(error, "Uploading \(type.id)'s sums; trying again next run")
      }
    }
    guard uploaded else { return }
    let paired = await statisticsReader.isPairedWithWatch()
    var writer = HealthBatchWriter()
    _ = try writer.append(HealthEncoder.statisticsDevice(pairedWithWatch: paired))
    if let file = try writer.finish() {
      do {
        try await uploader.upload(uuid().uuidString.lowercased(), file)
      } catch {
        try stopIfRunEnds(error)
      }
    }
  }

  /// Uploads a type's 30-minute sums from HealthKit, from the earliest time its changes affected,
  /// a chunk at a time, saving the progress after each. Upserts, so uploading again is harmless.
  private func uploadStatistics(
    of type: HealthBackfillType, _ state: inout HealthBackfillState
  ) async throws {
    guard let from = state.statisticsFrom[type.id],
      let unit = HealthCatalog.type(id: type.id)?.unit
    else {
      state.statisticsFrom[type.id] = nil
      return
    }
    var start = HealthEncoder.bucketStart(of: from)
    let end = HealthEncoder.bucketStart(
      of: max(now(), start).addingTimeInterval(Self.statisticsLookahead))
    let zeroFillFrom = now().addingTimeInterval(-Self.zeroFillWindow)
    while start < end {
      try Task.checkCancellation()
      let chunkEnd = min(end, start.addingTimeInterval(Self.statisticsChunk))
      var buckets = try await statisticsReader.buckets(type.id, start, chunkEnd)
      let found = Set(buckets.map(\.start))
      var bucket = max(start, HealthEncoder.bucketStart(of: zeroFillFrom))
      while bucket < chunkEnd {
        if !found.contains(bucket) { buckets.append(HealthBucket(start: bucket, sum: 0)) }
        bucket = bucket.addingTimeInterval(HealthEncoder.bucketSeconds)
      }
      var writer = HealthBatchWriter()
      var files: [Data] = []
      for bucket in buckets.sorted(by: { $0.start < $1.start }) {
        if let file = try writer.append(
          HealthEncoder.statistic(type: type.id, bucket: bucket, unit: unit))
        {
          files.append(file)
        }
      }
      if let file = try writer.finish() { files.append(file) }
      for file in files {
        try Task.checkCancellation()
        try await uploader.upload(uuid().uuidString.lowercased(), file)
      }
      start = chunkEnd
      state.statisticsFrom[type.id] = start < end ? start : nil
      try storage.saveState(state)
    }
    state.statisticsFrom[type.id] = nil
    state.statisticsUploadedAt[type.id] = now()
    state.lastUploadAt = now()
    try storage.saveState(state)
  }

  /// The saved state, or a fresh start if it can't be read (e.g. it's corrupt). Without saved
  /// state there's only something to do when starting the backfill.
  private func loadState(startingBackfill: Bool) throws -> HealthBackfillState? {
    do {
      if let state = try storage.loadState() { return state }
    } catch is DecodingError {
      reportIssue("Starting the backfill over: its state couldn't be read")
      try storage.saveState(nil)
    }
    return startingBackfill ? HealthBackfillState() : nil
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
    state.uploadedByType[pending.type, default: 0] += pending.records
    if !pending.batches.isEmpty { state.lastUploadAt = now() }
    try storage.saveState(state)
    for batch in pending.batches { try storage.removeFile(batch) }
    updateCounts(state)
  }

  /// The counts in `state`, not running and without a failure.
  private static func progress(_ types: [HealthBackfillType], _ state: HealthBackfillState)
    -> Progress
  {
    let byType = Dictionary(
      uniqueKeysWithValues: types.map { type in
        (
          type.id,
          TypeProgress(
            isDone: state.finished.contains(type.id) || state.empty.contains(type.id),
            uploadedRecords: state.uploadedByType[type.id] ?? 0)
        )
      })
    return Progress(
      finishedTypes: byType.values.filter(\.isDone).count, totalTypes: types.count,
      uploadedRecords: state.uploadedRecords, isRunning: false, types: byType,
      lastUploadAt: state.lastUploadAt)
  }

  private func updateCounts(_ state: HealthBackfillState) {
    let counts = Self.progress(types, state)
    update {
      $0.finishedTypes = counts.finishedTypes
      $0.uploadedRecords = counts.uploadedRecords
      $0.types = counts.types
      $0.lastUploadAt = counts.lastUploadAt
    }
  }

  /// Network errors mean the run is paused until there's a connection, not failing.
  static func isOffline(_ error: any Error) -> Bool {
    let offline: Set<URLError.Code> = [
      // Not `.timedOut`: a slow server isn't the phone being offline.
      .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
      .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
    ]
    if let error = error as? URLError { return offline.contains(error.code) }
    if let error = error as? ClientError { return isOffline(error.underlyingError) }
    return false
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
    HealthBackfill(types: HealthBackfillType.current)
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
