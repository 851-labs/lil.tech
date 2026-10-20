import CryptoKit
public import Dependencies
public import Foundation
import HealthCatalog
import HealthKitAccess
import IssueReporting
import LilAPI
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
  /// A hash of the characteristics last uploaded, so they only go up again when they change.
  public var characteristicsHash: String?
  /// The characteristics last uploaded, so one that stops being readable is deleted.
  public var characteristicIDs: Set<String> = []
  /// A hash of the vision prescriptions last uploaded, and their IDs, as for characteristics.
  public var visionPrescriptionsHash: String?
  public var visionPrescriptionIDs: Set<String> = []
  /// When the Activity summaries were last read and uploaded; `nil` before the first time,
  /// which reads them all.
  public var activitySummariesUploadedAt: Date?
  /// Reads of each type that failed in a row because a series couldn't be read
  /// (`HealthReader.SeriesUnavailable`). Past `HealthBackfill.seriesAttempts`, the type skips
  /// unreadable series.
  public var seriesFailures: [String: Int] = [:]

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
    characteristicsHash = try container.decodeIfPresent(String.self, forKey: .characteristicsHash)
    characteristicIDs =
      try container.decodeIfPresent(Set<String>.self, forKey: .characteristicIDs) ?? []
    visionPrescriptionsHash = try container.decodeIfPresent(
      String.self, forKey: .visionPrescriptionsHash)
    visionPrescriptionIDs =
      try container.decodeIfPresent(Set<String>.self, forKey: .visionPrescriptionIDs) ?? []
    activitySummariesUploadedAt = try container.decodeIfPresent(
      Date.self, forKey: .activitySummariesUploadedAt)
    seriesFailures =
      try container.decodeIfPresent([String: Int].self, forKey: .seriesFailures) ?? [:]
  }

  /// A page written to batch files. Its anchor is committed once every file is accepted.
  public struct PendingPage: Codable, Equatable, Sendable {
    public var type: String
    public var anchor: Data
    /// Whether this was the type's last page.
    public var isLast: Bool
    /// Batch IDs, which are also the files' names.
    public var batches: [String]
    /// The page's blobs' SHA-256s. Their files are named `blobFile(_:)`.
    public var blobs: [String]
    public var records: Int

    init(
      type: String, anchor: Data, isLast: Bool, batches: [String], blobs: [String] = [],
      records: Int
    ) {
      self.type = type
      self.anchor = anchor
      self.isLast = isLast
      self.batches = batches
      self.blobs = blobs
      self.records = records
    }

    /// Pages saved before blobs existed have none.
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      type = try container.decode(String.self, forKey: .type)
      anchor = try container.decode(Data.self, forKey: .anchor)
      isLast = try container.decode(Bool.self, forKey: .isLast)
      batches = try container.decode([String].self, forKey: .batches)
      blobs = try container.decodeIfPresent([String].self, forKey: .blobs) ?? []
      records = try container.decode(Int.self, forKey: .records)
    }

    /// Where a blob of the page waits to go up.
    static func blobFile(_ sha256: String) -> String { "blob-\(sha256)" }

    /// Every file the page keeps until it's uploaded.
    var files: [String] { batches + blobs.map(Self.blobFile) }
  }
}

/// Uploads a user's Health data (`docs/SYNC.md`): first the whole history (the backfill), then
/// what changes, every type a page at a time with anchored queries. A page's anchor is only
/// saved once all of its batches are accepted, so if the app is killed, the page is uploaded
/// again (batch IDs make that safe) and nothing is skipped.
public actor HealthBackfill {
  /// Runs that try a page whose series can't be read before skipping the unreadable ones.
  static let seriesAttempts = 3

  /// How long an upload that fails for a moment (`isTransient`) waits before each new try: 15
  /// seconds in all, within a background HealthKit wake (`HealthObserver.completionDeadline`),
  /// then it fails as before.
  static let transientRetryDelays: [Duration] = [
    .seconds(1), .seconds(2), .seconds(4), .seconds(8),
  ]

  /// Whether an upload failed for a moment, so it's worth trying again shortly: the server busy
  /// or restarting (`HealthBatchUploader.Rejected.isTransient`), or the request timing out or
  /// being dropped.
  static func isTransient(_ error: any Error) -> Bool {
    if let error = error as? HealthBatchUploader.Rejected { return error.isTransient }
    if let error = error as? URLError {
      return error.code == .timedOut || error.code == .networkConnectionLost
    }
    if let error = error as? ClientError { return isTransient(error.underlyingError) }
    return false
  }

  /// Runs `upload`, trying again after each of `delays` while it fails for a moment.
  static func retryingTransient(
    _ delays: [Duration], clock: any Clock<Duration>, _ upload: () async throws -> Void
  ) async throws {
    for delay in delays {
      do {
        return try await upload()
      } catch  where isTransient(error) {
        try await clock.sleep(for: delay)
      }
    }
    try await upload()
  }

  /// The delays before trying an upload again in this run: none once one has used them all up
  /// without getting through, so a server that's down fails the run's other uploads at once
  /// rather than each waiting it out.
  private var retryDelays: [Duration] { serverFailing ? [] : Self.transientRetryDelays }

  /// Runs uploads that retry with `retryDelays`, noting whether the server was still failing
  /// after them.
  private func notingServerFailure<T>(_ uploads: () async throws -> T) async throws -> T {
    do {
      let result = try await uploads()
      serverFailing = false
      return result
    } catch  where Self.isTransient(error) {
      serverFailing = true
      throw error
    }
  }

  /// Uploads a batch file, retrying transient failures.
  private func upload(_ id: String, _ file: Data) async throws {
    try await notingServerFailure {
      try await Self.retryingTransient(retryDelays, clock: clock) {
        try await uploader.upload(id, file)
      }
    }
  }

  /// Objects per anchored query. Two are in memory at once (one uploading, the next read), so
  /// not bigger.
  static let pageSize = 10_000
  /// Records per batch file, so a page makes a couple that upload at once: an upload mostly
  /// waits on the server, not the network. Not fewer: each batch costs the server a fixed time to
  /// apply, so smaller ones apply slower (`docs/DECISIONS.md`).
  static let batchRecords = 5_000
  /// A page's batches uploaded at once: a page of samples makes about `pageSize / batchRecords`
  /// (two), and only pages of records that make several mutations each (e.g. correlations) more.
  static let batchConcurrency = 4

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
    /// All the records to upload, uploaded or not, once every type left has been counted
    /// (`HealthRecordCounter`), else `nil`. Never less than `uploadedRecords`. Close rather
    /// than exact: it counts samples, while some upload as several records (a blood pressure
    /// reading and its two values), and deletions upload as records too.
    public var totalRecords: Int?

    public init(
      finishedTypes: Int, totalTypes: Int, uploadedRecords: Int, isRunning: Bool,
      failure: String? = nil, isOffline: Bool = false, isStorageFull: Bool = false,
      types: [String: TypeProgress] = [:], lastUploadAt: Date? = nil, totalRecords: Int? = nil
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
      self.totalRecords = totalRecords
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
  private let blobUploader: HealthBlobUploader
  private let statisticsReader: HealthStatisticsReader
  private let characteristicsReader: HealthCharacteristicsReader
  private let visionPrescriptionsReader: HealthVisionPrescriptionsReader
  private let activitySummaryReader: HealthActivitySummaryReader
  private let counter: HealthRecordCounter
  /// Each type's records as counted (`HealthRecordCounter`): those uploaded when it was counted,
  /// plus those after its anchor then.
  private var countedRecords: [String: Int] = [:]
  /// Counting the types left, while a run of everything is going.
  private var counting: Task<Void, Never>?
  private let uuid: UUIDGenerator
  private let now: @Sendable () -> Date
  private let clock: any Clock<Duration>
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
  /// When an upload last found the account's storage full, until one goes through.
  private var storageFullAt: Date?
  /// Until when the server asked for no more uploads (a 429).
  private var rateLimitedUntil: Date?
  /// An upload in this run failed for a moment even after its retries (`retryDelays`).
  private var serverFailing = false
  /// While storage is full, how long uploads for changes wait between tries. `run()` (the app
  /// opening, Try Again) always tries.
  static let storageFullRetryInterval: TimeInterval = 6 * 60 * 60

  public init(types: [HealthBackfillType]) {
    @Dependency(\.healthReader) var reader
    @Dependency(\.healthBackfillStorage) var storage
    @Dependency(\.healthBatchUploader) var uploader
    @Dependency(\.healthBlobUploader) var blobUploader
    @Dependency(\.uuid) var uuid
    @Dependency(\.healthStatisticsReader) var statisticsReader
    @Dependency(\.healthCharacteristicsReader) var characteristicsReader
    @Dependency(\.healthVisionPrescriptionsReader) var visionPrescriptionsReader
    @Dependency(\.healthActivitySummaryReader) var activitySummaryReader
    @Dependency(\.healthRecordCounter) var counter
    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var clock
    self.types = types
    self.clock = clock
    self.reader = reader
    self.storage = storage
    self.uploader = uploader
    self.blobUploader = blobUploader
    self.statisticsReader = statisticsReader
    self.characteristicsReader = characteristicsReader
    self.visionPrescriptionsReader = visionPrescriptionsReader
    self.activitySummaryReader = activitySummaryReader
    self.counter = counter
    self.uuid = uuid
    self.now = { date.now }
    let state = (try? storage.loadState()) ?? nil
    self.progress = Self.progress(types, state ?? HealthBackfillState())
  }

  /// The progress now and after every change.
  /// The progress now.
  public func currentProgress() -> Progress { progress }

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
    counting?.cancel()
    counting = nil
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
      // A cancelled run asks again for the types it didn't reach.
      requestedTypes = []
      storageFullAt = nil
      rateLimitedUntil = nil
      // Even if the state can't be read, everything goes: `saveState(nil)` removes the files.
      if let pending = (try? storage.loadState())??.pending {
        for file in pending.files { try? storage.removeFile(file) }
      }
      withErrorReporting { try storage.saveState(nil) }
      counting?.cancel()
      counting = nil
      countedRecords = [:]
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
    if !syncAllRequested, let storageFullAt,
      now() < storageFullAt.addingTimeInterval(Self.storageFullRetryInterval)
    {
      // Every upload would be refused; the changes wait in `requestedTypes`.
      return
    }
    let fullRun = syncAllRequested
    serverFailing = false
    let started = ContinuousClock.now
    let limitedUntil = rateLimitedUntil.flatMap { now() < $0 ? $0 : nil }
    // Changes wait in `requestedTypes`. A run of everything (the app opening, Continue, a
    // background task) waits out the limit instead, unless it's paused meanwhile.
    if limitedUntil != nil, !syncAllRequested { return }
    update { $0.isRunning = true }
    if fullRun { startCounting() }
    if let limitedUntil {
      BackfillLog.write(
        "waiting out a rate limit for \(Int(limitedUntil.timeIntervalSince(now())))s")
      do {
        try await clock.sleep(for: .seconds(limitedUntil.timeIntervalSince(now())))
      } catch {
        BackfillLog.write("cancelled while waiting out a rate limit")
        update { $0.isRunning = false }
        throw CancellationError()
      }
    }
    var failures: [String: any Error] = [:]
    var syncedAll = false
    /// Types asked for that this run hasn't got to, asked for again if it ends early.
    var unreached: Set<String> = []
    /// Whether a run of everything still has the characteristics and summaries to read.
    var extrasDue = false
    do {
      guard var state = try loadState(startingBackfill: syncAllRequested) else {
        // No backfill yet (or signed out): changes wait for one.
        requestedTypes = []
        update { $0.isRunning = false }
        return
      }
      // Here, so every run logged as started is logged as ended or stopped.
      BackfillLog.write(
        syncAllRequested ? "run started: everything" : "run started: \(requestedTypes.count) types")
      if let pending = state.pending {
        try await upload(pending, &state)
      }
      repeat {
        while syncAllRequested || !requestedTypes.isEmpty {
          let wanted: Set<String>
          if syncAllRequested {
            syncAllRequested = false
            syncedAll = true
            extrasDue = true
            wanted = Set(types.map(\.id))
          } else {
            wanted = requestedTypes
          }
          requestedTypes = []
          unreached.formUnion(wanted)
          for type in types where wanted.contains(type.id) && failures[type.id] == nil {
            do {
              try await sync(type, &state)
              unreached.remove(type.id)
            } catch {
              // Ending the run, it's still unreached.
              try stopIfRunEnds(error)
              unreached.remove(type.id)
              if error is HealthReader.SeriesUnavailable {
                state.seriesFailures[type.id, default: 0] += 1
                try? storage.saveState(state)
              }
              // One type can't hold up the rest. Its page is read again next time.
              failures[type.id] = error
              if let pending = state.pending, pending.type == type.id {
                for file in pending.files { try? storage.removeFile(file) }
                state.pending = nil
                try storage.saveState(state)
              }
            }
          }
        }
        // Sums for every type that has some due, including ones from a resumed page.
        try await uploadAllStatistics(&state, skipping: Set(failures.keys))
        if extrasDue {
          extrasDue = false
          try await uploadExtras(&state)
        }
        // Requests made while the sums went up are handled before the loop ends.
      } while syncAllRequested || !requestedTypes.isEmpty
    } catch {
      BackfillLog.write("run stopped after \(BackfillLog.since(started)): \(error)")
      let cancelled = Task.isCancelled || error is CancellationError
      // Rate limited, it's paused for a moment rather than failed.
      let rateLimit = error as? HealthBatchUploader.RateLimited
      let paused = cancelled || error is HealthReader.Locked || rateLimit != nil
      requestedTypes.formUnion(unreached.union(failures.keys))
      if error is HealthBatchUploader.StorageFull { storageFullAt = now() }
      if let rateLimit {
        rateLimitedUntil = now().addingTimeInterval(rateLimit.retryAfter)
        // A run of everything carries on after the limit, as it would have if it started then.
        if fullRun || syncedAll, !cancelled {
          syncAllRequested = true
          return try await loop(id)
        }
      }
      update {
        $0.isRunning = false
        if !paused {
          $0.failure = error.localizedDescription
          $0.isOffline = Self.isOffline(error)
          $0.isStorageFull = error is HealthBatchUploader.StorageFull
        }
      }
      throw cancelled ? CancellationError() : error
    }
    // Tried again on the next call.
    requestedTypes.formUnion(failures.keys)
    BackfillLog.write(
      "run ended after \(BackfillLog.since(started)), failed: \(failures.keys.map(BackfillLog.name).sorted())"
    )
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
    // Its uploads went through, so there's room again.
    storageFullAt = nil
    update {
      $0.isRunning = false
      // A run that covered everything clears an earlier failure; one for a few changes doesn't,
      // except that storage was full, which its uploads just showed isn't so anymore.
      if syncedAll || $0.isStorageFull {
        $0.failure = nil
        $0.isOffline = false
        $0.isStorageFull = false
      }
    }
  }

  /// Rethrows the error if it ends the whole run rather than one type's sync: cancelled (a
  /// cancelled upload throws a URL error), the device is locked, or the account's storage is full,
  /// is rate limited or lacks consent, which every other upload would hit too. The pending page
  /// is kept.
  private func stopIfRunEnds(_ error: any Error) throws {
    if Task.isCancelled || error is CancellationError { throw CancellationError() }
    if let locked = error as? HealthReader.Locked { throw locked }
    if let full = error as? HealthBatchUploader.StorageFull { throw full }
    if let limited = error as? HealthBatchUploader.RateLimited { throw limited }
    if let consent = error as? HealthBatchUploader.ConsentRequired { throw consent }
  }

  /// Uploads a type's pages from its anchor until there are no more. The next page is read
  /// while one uploads; it's only kept, and its anchor saved, once the one before is accepted.
  private func sync(_ type: HealthBackfillType, _ state: inout HealthBackfillState) async throws {
    var isLast = false
    let limit = type.pageSize ?? Self.pageSize
    /// The next page, being read, with how long the read took.
    var next: Task<(HealthPage, Duration), any Error>?
    defer { next?.cancel() }
    do {
      while !isLast {
        try Task.checkCancellation()
        let anchor = state.anchors[type.id]
        // A series that couldn't be read keeps the page from moving on, until it's failed
        // `seriesAttempts` times: then it's skipped, so one record can't hold up the type
        // forever.
        var reading = type
        reading.skipsUnreadableSeries =
          state.seriesFailures[type.id, default: 0] >= Self.seriesAttempts
        let readStart = ContinuousClock.now
        let page: HealthPage
        let readTime: Duration
        do {
          if let read = next {
            next = nil
            (page, readTime) = try await read.value
          } else {
            page = try await reader.page(reading, anchor, limit)
            readTime = ContinuousClock.now - readStart
          }
        } catch {
          BackfillLog.write(
            "read \(BackfillLog.name(type.id)) failed after \(BackfillLog.since(readStart)): \(error)"
          )
          throw error
        }
        BackfillLog.write(
          "read \(BackfillLog.name(type.id)): \(page.mutations.count) in \(BackfillLog.seconds(readTime))\(page.hasMore ? "" : ", last")"
        )
        state.seriesFailures[type.id] = nil
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
        // Read while this page is encoded, saved and uploaded.
        if page.hasMore { next = Self.readAhead(type, after: page.anchor, limit, reader) }
        markStatistics(of: type, changedBy: page.mutations, &state)
        let (pending, files, blobs) = try write(page, of: type)
        // The page is saved before its files, so a kill in between leaves no orphans: the
        // missing files make the next run read the page again.
        state.pending = pending
        try storage.saveState(state)
        for (batch, file) in zip(pending.batches, files) { try storage.saveFile(batch, file) }
        for (sha256, blob) in blobs {
          try storage.saveFile(HealthBackfillState.PendingPage.blobFile(sha256), blob)
        }
        try await upload(pending, &state)
        // A page given up on (its files went missing) leaves the anchor where it was: the read
        // ahead started past it, so it's dropped and the loop reads from the anchor again.
        if state.anchors[type.id] != page.anchor, let read = next {
          read.cancel()
          _ = try? await read.value
          next = nil
        }
        isLast = pending.isLast
      }
    } catch {
      // Whatever failed, the read ahead stops before the run moves on, so it can't overlap the
      // next type's.
      next?.cancel()
      _ = try? await next?.value
      throw error
    }
  }

  /// Starts reading the page after `anchor`, as the loop would read it next: a good read clears
  /// the series failures, so nothing is skipped. Off the actor, so it overlaps the current page's
  /// encoding and saving.
  private nonisolated static func readAhead(
    _ type: HealthBackfillType, after anchor: Data?, _ limit: Int, _ reader: HealthReader
  ) -> Task<(HealthPage, Duration), any Error> {
    var following = type
    following.skipsUnreadableSeries = false
    return Task {
      let start = ContinuousClock.now
      let page = try await reader.page(following, anchor, limit)
      return (page, ContinuousClock.now - start)
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

  /// How far back each run reads Activity summaries again: recent days' numbers and goals can
  /// still change, e.g. when a Watch that was away for a while syncs.
  static let activitySummaryWindow: TimeInterval = 30 * 24 * 60 * 60

  /// Uploads what has no anchors: the characteristics and vision prescriptions, if they changed
  /// since they last went up, and the Activity summaries, all of them the first time and the last
  /// 30 days' after that. A failure is kept for the next run.
  private func uploadExtras(_ state: inout HealthBackfillState) async throws {
    do {
      try await uploadWhole(
        try await characteristicsReader.read(), as: HealthEncoder.characteristicEntity,
        hash: \.characteristicsHash, ids: \.characteristicIDs, &state)
    } catch {
      try stopIfRunEnds(error)
      reportIssue(error, "Uploading characteristics; trying again next run")
    }
    do {
      try await uploadWhole(
        try await visionPrescriptionsReader.read(), as: HealthEncoder.visionPrescriptionEntity,
        hash: \.visionPrescriptionsHash, ids: \.visionPrescriptionIDs, &state)
    } catch {
      try stopIfRunEnds(error)
      reportIssue(error, "Uploading vision prescriptions; trying again next run")
    }
    do {
      let readAt = now()
      let from = state.activitySummariesUploadedAt?.addingTimeInterval(
        -Self.activitySummaryWindow)
      let summaries = try await activitySummaryReader.read(from)
      try await uploadMutations(summaries)
      state.activitySummariesUploadedAt = readAt
      if !summaries.isEmpty { state.lastUploadAt = now() }
      try storage.saveState(state)
      updateCounts(state)
    } catch {
      try stopIfRunEnds(error)
      reportIssue(error, "Uploading Activity summaries; trying again next run")
    }
  }

  /// Uploads records read whole each run, if they changed since they last went up (`hash`).
  /// One that's no longer readable (access was turned off, or it was deleted) is deleted.
  private func uploadWhole(
    _ records: [HealthMutation], as entity: String,
    hash: WritableKeyPath<HealthBackfillState, String?>,
    ids: WritableKeyPath<HealthBackfillState, Set<String>>, _ state: inout HealthBackfillState
  ) async throws {
    let current = try Self.hash(records)
    guard current != state[keyPath: hash] else { return }
    let read = Set(records.map(\.id))
    let removed = state[keyPath: ids].subtracting(read).sorted().map {
      HealthMutation.delete(entity, id: $0)
    }
    try await uploadMutations(records + removed)
    state[keyPath: hash] = current
    state[keyPath: ids] = read
    if !records.isEmpty || !removed.isEmpty { state.lastUploadAt = now() }
    try storage.saveState(state)
    updateCounts(state)
  }

  /// Uploads mutations in as many batch files as they need. One too long for the server is
  /// reported and left out.
  private func uploadMutations(_ mutations: [HealthMutation]) async throws {
    var writer = HealthBatchWriter()
    var files: [Data] = []
    for mutation in mutations {
      do {
        if let file = try writer.append(mutation) { files.append(file) }
      } catch let error as HealthBatchWriter.LineTooLong {
        reportIssue(error)
      }
    }
    if let file = try writer.finish() { files.append(file) }
    for file in files {
      try Task.checkCancellation()
      try await upload(uuid().uuidString.lowercased(), file)
    }
  }

  /// A hash of mutations that doesn't depend on their order.
  static func hash(_ mutations: [HealthMutation]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let lines = try mutations.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
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
        try await upload(uuid().uuidString.lowercased(), file)
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
      try await uploadMutations(
        buckets.sorted { $0.start < $1.start }.map {
          HealthEncoder.statistic(type: type.id, bucket: $0, unit: unit)
        })
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

  /// Writes a page's mutations to batch files, in memory, and names its blobs. A record or blob
  /// too large for the server is skipped and reported, so it can't stop the backfill.
  private func write(_ page: HealthPage, of type: HealthBackfillType) throws
    -> (HealthBackfillState.PendingPage, [Data], [(sha256: String, data: Data)])
  {
    var blobs: [(sha256: String, data: Data)] = []
    var skippedBlobs: Set<String> = []
    for blob in page.blobs {
      let sha256 = HealthBlob.sha256(blob)
      guard blob.count <= HealthBlob.maxBytes else {
        reportIssue(HealthBlob.TooLarge(bytes: blob.count))
        skippedBlobs.insert(sha256)
        continue
      }
      if !blobs.contains(where: { $0.sha256 == sha256 }) { blobs.append((sha256, blob)) }
    }
    var writer = HealthBatchWriter(maxRecords: Self.batchRecords)
    var files: [Data] = []
    // A record whose blob was skipped goes too, so none refers to a blob that never arrives.
    let mutations = page.mutations.filter { mutation in
      skippedBlobs.isEmpty
        || !(mutation.row?.values.contains { value in
          if case .string(let string) = value { skippedBlobs.contains(string) } else { false }
        } ?? false)
    }
    for mutation in mutations {
      do {
        if let file = try writer.append(mutation) { files.append(file) }
      } catch let error as HealthBatchWriter.LineTooLong {
        reportIssue(error)
      }
    }
    if let file = try writer.finish() { files.append(file) }
    let pending = HealthBackfillState.PendingPage(
      type: type.id, anchor: page.anchor, isLast: !page.hasMore,
      batches: files.map { _ in uuid().uuidString.lowercased() }, blobs: blobs.map(\.sha256),
      records: mutations.count)
    return (pending, files, blobs)
  }

  /// Uploads a page's blobs, then its batches, so no row arrives before its blob. Then commits
  /// its anchor.
  private func upload(
    _ pending: HealthBackfillState.PendingPage, _ state: inout HealthBackfillState
  ) async throws {
    // The run stopped before writing them all: drop the page, and read it again from the anchor
    // before it. Records are keyed by UUID and blobs by hash, so whatever already went up is
    // harmless.
    func dropPage() throws {
      for file in pending.files { try storage.removeFile(file) }
      state.pending = nil
      try storage.saveState(state)
    }
    // A few blobs at a time. Each leaves the pending page once it's accepted, so a page that's
    // resumed carries on where it stopped.
    var missingBlob = false
    let delays = retryDelays
    // Only with blobs: nothing going up isn't the server answering again.
    if !pending.blobs.isEmpty {
      try await notingServerFailure {
        try await withThrowingTaskGroup(of: String?.self) { group in
          var queue = pending.blobs[...]
          for _ in 0..<Self.blobConcurrency {
            guard let sha256 = queue.popFirst() else { break }
            group.addTask { [storage, blobUploader, clock] in
              try await Self.uploadBlob(
                sha256, storage: storage, uploader: blobUploader, delays: delays, clock: clock)
            }
          }
          while let uploaded = try await group.next() {
            guard let sha256 = uploaded else {
              missingBlob = true
              group.cancelAll()
              break
            }
            state.pending?.blobs.removeAll { $0 == sha256 }
            try storage.saveState(state)
            try storage.removeFile(HealthBackfillState.PendingPage.blobFile(sha256))
            if let next = queue.popFirst() {
              group.addTask { [storage, blobUploader, clock] in
                try await Self.uploadBlob(
                  next, storage: storage, uploader: blobUploader, delays: delays, clock: clock)
              }
            }
          }
        }
      }
    }
    if missingBlob { return try dropPage() }
    let uploading = ContinuousClock.now
    // A few at a time, in any order: the anchor only moves once they're all accepted, and a
    // batch that went up before a failure is known to the server by its ID when it's tried again.
    // A page's records are each its own object (HealthKit's are immutable), so their order
    // doesn't matter. Each file is loaded as it goes up; one missing drops the page.
    var missingBatch = false
    do {
      // Read now: the blobs' uploads above may have found the server answering again.
      let delays = retryDelays
      missingBatch = try await notingServerFailure {
        try await withThrowingTaskGroup(of: Bool.self) { group in
          var queue = pending.batches[...]
          func uploadNext() {
            guard let batch = queue.popFirst() else { return }
            group.addTask { [storage, uploader, clock] in
              try Task.checkCancellation()
              guard let file = try storage.loadFile(batch) else { return false }
              try await Self.retryingTransient(delays, clock: clock) {
                try await uploader.upload(batch, file)
              }
              return true
            }
          }
          for _ in 0..<Self.batchConcurrency { uploadNext() }
          while let uploaded = try await group.next() {
            guard uploaded else {
              group.cancelAll()
              return true
            }
            uploadNext()
          }
          return false
        }
      }
    } catch {
      BackfillLog.write(
        "upload \(BackfillLog.name(pending.type)) failed after \(BackfillLog.since(uploading)): \(error)"
      )
      throw error
    }
    if missingBatch { return try dropPage() }
    BackfillLog.write(
      "uploaded \(BackfillLog.name(pending.type)): \(pending.records) records, \(pending.batches.count) batches, \(pending.blobs.count) blobs in \(BackfillLog.since(uploading))"
    )
    state.anchors[pending.type] = pending.anchor
    if pending.isLast { state.finished.insert(pending.type) }
    state.pending = nil
    state.uploadedRecords += pending.records
    state.uploadedByType[pending.type, default: 0] += pending.records
    if !pending.batches.isEmpty { state.lastUploadAt = now() }
    try storage.saveState(state)
    for file in pending.files { try storage.removeFile(file) }
    updateCounts(state)
  }

  /// Blobs uploaded at once. They're independent, and only have to arrive before the page's
  /// batches.
  static let blobConcurrency = 4

  /// Uploads a pending page's blob from its file. Returns its SHA-256, or `nil` if the file is
  /// missing.
  private static func uploadBlob(
    _ sha256: String, storage: HealthBackfillStorage, uploader: HealthBlobUploader,
    delays: [Duration], clock: any Clock<Duration>
  ) async throws -> String? {
    try Task.checkCancellation()
    guard let blob = try storage.loadFile(HealthBackfillState.PendingPage.blobFile(sha256))
    else { return nil }
    try await retryingTransient(delays, clock: clock) { try await uploader.upload(sha256, blob) }
    return sha256
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
      $0.totalRecords = totalRecords(counts)
    }
  }

  /// Counts the records of every type left, once per launch, for the progress's
  /// `totalRecords`. Each from the anchor in the saved state, with that state's uploaded records,
  /// so the two agree however far the upload has got meanwhile. Best-effort: a type that can't
  /// be counted leaves the total unknown.
  private func startCounting() {
    guard counting == nil,
      let state = try? storage.loadState() ?? HealthBackfillState()
    else { return }
    let left = types.filter {
      !state.finished.contains($0.id) && countedRecords[$0.id] == nil
    }
    guard !left.isEmpty else { return }
    counting = Task { [counter] in
      BackfillLog.write("counting \(left.count) types")
      for type in left {
        let start = ContinuousClock.now
        guard let records = try? await counter.count(type, state.anchors[type.id]) else {
          // Paused or reset: stop, leaving `counting` to the task that replaced this one.
          guard !Task.isCancelled else { return }
          BackfillLog.write(
            "count \(BackfillLog.name(type.id)) failed after \(BackfillLog.since(start))")
          continue
        }
        BackfillLog.write(
          "counted \(BackfillLog.name(type.id)): \(records) in \(BackfillLog.since(start))")
        // Reset or paused meanwhile: the count may be another account's, or stale.
        guard !Task.isCancelled else { return }
        counted(type.id, records: (state.uploadedByType[type.id] ?? 0) + records)
      }
      // Types that couldn't be counted (e.g. the phone locked) are tried again next run.
      counting = nil
    }
  }

  private func counted(_ type: String, records: Int) {
    countedRecords[type] = records
    update { $0.totalRecords = totalRecords($0) }
  }

  /// Every type's records: what's uploaded for a finished type, as counted for the rest. `nil`
  /// while a type left hasn't been counted.
  private func totalRecords(_ progress: Progress) -> Int? {
    var total = 0
    for type in types {
      let uploaded = progress.types[type.id]?.uploadedRecords ?? 0
      if progress.types[type.id]?.isDone == true {
        total += uploaded
      } else if let counted = countedRecords[type.id] {
        // New samples may have been counted since; deletions can make it smaller.
        total += max(counted, uploaded)
      } else {
        return nil
      }
    }
    return max(total, progress.uploadedRecords)
  }

  /// Network errors mean the run is paused until there's a connection, not failing.
  static func isOffline(_ error: any Error) -> Bool { isOfflineError(error) }

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
