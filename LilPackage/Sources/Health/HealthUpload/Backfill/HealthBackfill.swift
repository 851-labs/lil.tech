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
  /// The Health Documents uploaded, so only new ones are read with their XML, and one no longer
  /// shared is deleted. Documents never change. Those too large to upload are here too, so they
  /// aren't read again every run.
  public var documentIDs: Set<String> = []
  /// A hash of the medications last uploaded, and their concept IDs, as for characteristics. The
  /// doses uploaded for each are in a file of their own (`HealthBackfill.medicationDosesFile`).
  public var medicationsHash: String?
  public var medicationIDs: Set<String> = []
  /// When the Activity summaries were last read and uploaded; `nil` before the first time,
  /// which reads them all.
  public var activitySummariesUploadedAt: Date?
  /// Reads of each type that failed in a row because a series couldn't be read
  /// (`HealthReader.SeriesUnavailable`). Past `HealthBackfill.seriesAttempts`, the type skips
  /// unreadable series.
  public var seriesFailures: [String: Int] = [:]
  /// The ``HealthEncoder/workoutEncoding`` the workouts uploaded so far were read with; 0 before
  /// it was kept. Older ones are read again (`HealthBackfill.readAgainIfOlder`).
  public var workoutEncoding = 0
  /// The ``HealthEncoder/quantitySeriesEncoding`` each quantity type's samples were read with;
  /// missing for types read before it was kept. A type read with an older one has its series read
  /// again, once (`HealthBackfill.readSeriesAgain`, 851-4149).
  public var quantitySeriesEncodings: [String: Int] = [:]
  /// How far each type's series have been read again: the anchor of a query of its series alone.
  public var seriesAgainAnchors: [String: Data] = [:]
  /// Each type's records that didn't go up (851-4151): Sync Status counts them, and runs of
  /// everything try them again.
  public var heldBack: [String: HeldBack] = [:]
  /// Pages uploaded whose batches the server hasn't been asked about yet, oldest first.
  public var uploaded: [UploadedPage] = []

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
    documentIDs = try container.decodeIfPresent(Set<String>.self, forKey: .documentIDs) ?? []
    medicationsHash = try container.decodeIfPresent(String.self, forKey: .medicationsHash)
    medicationIDs =
      try container.decodeIfPresent(Set<String>.self, forKey: .medicationIDs) ?? []
    activitySummariesUploadedAt = try container.decodeIfPresent(
      Date.self, forKey: .activitySummariesUploadedAt)
    seriesFailures =
      try container.decodeIfPresent([String: Int].self, forKey: .seriesFailures) ?? [:]
    workoutEncoding = try container.decodeIfPresent(Int.self, forKey: .workoutEncoding) ?? 0
    quantitySeriesEncodings =
      try container.decodeIfPresent([String: Int].self, forKey: .quantitySeriesEncodings) ?? [:]
    seriesAgainAnchors =
      try container.decodeIfPresent([String: Data].self, forKey: .seriesAgainAnchors) ?? [:]
    heldBack = try container.decodeIfPresent([String: HeldBack].self, forKey: .heldBack) ?? [:]
    uploaded = try container.decodeIfPresent([UploadedPage].self, forKey: .uploaded) ?? []
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
    /// The anchor it was read from, for checking its batches (`UploadedPage.from`).
    public var from: Data?
    /// For held-back records sent again (851-4151): those in the page. Its anchor is the type's.
    public var retried: [String]?

    init(
      type: String, anchor: Data, isLast: Bool, batches: [String], blobs: [String] = [],
      records: Int, from: Data? = nil, retried: [String]? = nil
    ) {
      self.type = type
      self.anchor = anchor
      self.isLast = isLast
      self.batches = batches
      self.blobs = blobs
      self.records = records
      self.from = from
      self.retried = retried
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
      from = try container.decodeIfPresent(Data.self, forKey: .from)
      retried = try container.decodeIfPresent([String].self, forKey: .retried)
    }

    /// Where a blob of the page waits to go up.
    static func blobFile(_ sha256: String) -> String { "blob-\(sha256)" }

    /// Every file the page keeps until it's uploaded.
    var files: [String] { batches + blobs.map(Self.blobFile) }
  }
}

/// Uploads a user's Health data (`docs/sync/protocol.md`): first the whole history (the backfill),
/// then what changes, every type a page at a time with anchored queries. A page's anchor is only
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
    /// Records that didn't go up, by type (851-4151): they couldn't be read, were too large, or
    /// the server refused them.
    public var heldBack: [String: Int]

    public init(
      finishedTypes: Int, totalTypes: Int, uploadedRecords: Int, isRunning: Bool,
      failure: String? = nil, isOffline: Bool = false, isStorageFull: Bool = false,
      types: [String: TypeProgress] = [:], lastUploadAt: Date? = nil, totalRecords: Int? = nil,
      heldBack: [String: Int] = [:]
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
      self.heldBack = heldBack
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
  private let documentsReader: HealthDocumentsReader
  private let medicationsReader: HealthMedicationsReader
  private let activitySummaryReader: HealthActivitySummaryReader
  private let counter: HealthRecordCounter
  private let statusReader: HealthBatchStatusReader
  /// The app's build, which held-back records note: those too long or refused are tried again
  /// once it changes.
  private let build: String
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
  /// Batches uploaded since the server was last asked about them: between types, it's asked
  /// again only once as many as it answers for have gone up, not about the same queued ones.
  private var uploadedSinceCheck = 0
  /// While storage is full, how long uploads for changes wait between tries. `run()` (the app
  /// opening, Try Again) always tries.
  static let storageFullRetryInterval: TimeInterval = 6 * 60 * 60

  /// The app's version and build, e.g. `1.4 (212)`.
  public static var appBuild: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    return "\(version) (\(info?["CFBundleVersion"] as? String ?? "?"))"
  }

  public init(types: [HealthBackfillType], build: String = HealthBackfill.appBuild) {
    @Dependency(\.healthReader) var reader
    @Dependency(\.healthBackfillStorage) var storage
    @Dependency(\.healthBatchUploader) var uploader
    @Dependency(\.healthBlobUploader) var blobUploader
    @Dependency(\.uuid) var uuid
    @Dependency(\.healthStatisticsReader) var statisticsReader
    @Dependency(\.healthCharacteristicsReader) var characteristicsReader
    @Dependency(\.healthVisionPrescriptionsReader) var visionPrescriptionsReader
    @Dependency(\.healthDocumentsReader) var documentsReader
    @Dependency(\.healthMedicationsReader) var medicationsReader
    @Dependency(\.healthActivitySummaryReader) var activitySummaryReader
    @Dependency(\.healthRecordCounter) var counter
    @Dependency(\.healthBatchStatusReader) var statusReader
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
    self.documentsReader = documentsReader
    self.medicationsReader = medicationsReader
    self.activitySummaryReader = activitySummaryReader
    self.counter = counter
    self.statusReader = statusReader
    self.build = build
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

  /// Reads every type's history again from the start, for what the server is missing (851-2662),
  /// e.g. once Health shares more of it. It first catches up from where each type got to, so
  /// deletions since go up, then forgets only that, the counts (which the new pass makes again)
  /// and when Activity summaries were read. What it needs to delete records no longer readable
  /// (including the doses uploaded for each medication), and the account's limits, stay. The next
  /// run reads from the start. Throws if catching up fails, changing nothing.
  public func uploadAgain() async throws {
    try await run()
    // A run for changes that started meanwhile finishes first: it saves the state as it goes.
    while let running { _ = try? await running.task.value }
    var state = try storage.loadState() ?? HealthBackfillState()
    state.anchors = [:]
    state.finished = []
    state.empty = []
    state.uploadedRecords = 0
    state.uploadedByType = [:]
    state.activitySummariesUploadedAt = nil
    // Read again with the rest: those that still don't go up are held back again, and pages
    // read before mustn't move an anchor back after the new pass has started.
    state.heldBack = [:]
    state.uploaded = []
    try storage.saveState(state)
    countedRecords = [:]
    updateCounts(state)
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
      try? storage.removeFile(Self.medicationDosesFile)
      medicationDoses = nil
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
      // What the server did with the batches uploaded before, e.g. by the last run.
      try await checkUploads(&state)
      repeat {
        while syncAllRequested || !requestedTypes.isEmpty {
          let wanted: Set<String>
          var medicationsDue = false
          /// Whether records held back are tried again.
          var heldBackDue = false
          if syncAllRequested {
            syncAllRequested = false
            syncedAll = true
            extrasDue = true
            medicationsDue = true
            heldBackDue = true
            wanted = Set(types.map(\.id))
          } else {
            wanted = requestedTypes
          }
          requestedTypes = []
          unreached.formUnion(wanted)
          // Before the types, so doses a medication shared since needs are read in this run.
          if medicationsDue { try await uploadMedications(&state) }
          for type in types where wanted.contains(type.id) && failures[type.id] == nil {
            do {
              // Before the type's changes, so what this run holds back waits for the next.
              if heldBackDue { try await retryHeldBack(type, &state) }
              let wasRead = state.anchors[type.id] != nil
              noteSeriesEncoding(of: type, &state)
              try await sync(type, &state)
              try await readAgainIfOlder(type, wasRead: wasRead, &state)
              if heldBackDue {
                try await readAgainIfUnnamed(type, &state)
                try await readSeriesAgain(type, &state)
              }
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
            // A backfill uploads many: they're checked as they add up, between types.
            if uploadedSinceCheck >= HealthBatchStatusReader.maxBatches {
              try await checkUploads(&state)
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
        // A page whose records all failed still has them to hold back.
        if page.mutations.isEmpty, page.failed.isEmpty {
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
        let pending = try await uploadPage(page, of: type, from: anchor ?? Data(), &state)
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

  /// Writes a page of `type` to batch files, holds back what it couldn't send, saves it as
  /// pending and uploads it. `from` is the anchor it was read from (empty for the type's first
  /// page), or `nil` for held-back records sent again (`retried`, those of them in the page).
  private func uploadPage(
    _ page: HealthPage, of type: HealthBackfillType, from: Data?, retried: [String]? = nil,
    _ state: inout HealthBackfillState
  ) async throws -> HealthBackfillState.PendingPage {
    markStatistics(of: type, changedBy: page.mutations, &state)
    if type.entity == HealthEncoder.medicationDoseEntity {
      try recordDoses(page.mutations)
    }
    // Deleted from Health: there's nothing left to send.
    release(
      page.mutations.filter { $0.op == .delete }.map(\.id), of: type.id, because: "deleted",
      &state)
    var (pending, files, blobs, tooLarge) = try write(page, of: type)
    pending.from = from
    pending.retried = retried.map { ids in ids.filter { !tooLarge.contains($0) } }
    hold(page.failed, of: type.id, .unreadable, &state)
    hold(tooLarge, of: type.id, .tooLarge, &state)
    // The page is saved before its files, so a kill in between leaves no orphans: the
    // missing files make the next run read the page again.
    state.pending = pending
    try storage.saveState(state)
    for (batch, file) in zip(pending.batches, files) { try storage.saveFile(batch, file) }
    for (sha256, blob) in blobs {
      try storage.saveFile(HealthBackfillState.PendingPage.blobFile(sha256), blob)
    }
    let committed = try await upload(pending, &state)
    // Whatever went up isn't held back anymore, e.g. read again after a batch failed.
    if committed, state.heldBack[type.id] != nil {
      let skipped = Set(tooLarge)
      release(
        page.mutations.filter { $0.op == .upsert && !skipped.contains($0.id) }.map(\.id),
        of: type.id, because: "went up", &state)
      try storage.saveState(state)
    }
    return pending
  }

  /// A type's held-back records at most, by ID. Past it they're only counted, and after an
  /// update the type is read again from the start instead.
  static let maxHeldRecords = 1_000

  /// Holds back records of `type` that didn't go up, to count them and try them again (851-4151).
  private func hold(
    _ ids: [String], of type: String, _ reason: HealthBackfillState.HoldReason,
    _ state: inout HealthBackfillState
  ) {
    guard !ids.isEmpty else { return }
    var held = state.heldBack[type] ?? .init()
    var unnamed = 0
    for id in ids {
      if held.records[id] != nil || held.records.count < Self.maxHeldRecords {
        held.records[id] = .init(reason: reason, build: build)
      } else {
        unnamed += 1
      }
    }
    state.heldBack[type] = held
    if unnamed > 0 { holdUnnamed(unnamed, of: type, &state) }
    BackfillLog.write("held back \(ids.count) of \(BackfillLog.name(type)): \(reason.rawValue)")
  }

  /// Counts records of `type` that didn't go up and aren't known by ID.
  private func holdUnnamed(_ count: Int, of type: String, _ state: inout HealthBackfillState) {
    state.heldBack[type, default: .init()].unnamed += count
    state.heldBack[type]?.unnamedBuild = build
  }

  /// Holds back records whose samples went up but whose series didn't (851-4149). Each is
  /// uncounted once, as it's first held, since sending it again counts its sample again.
  private func holdSeries(
    _ ids: [String], of type: String, _ reason: HealthBackfillState.HoldReason,
    _ state: inout HealthBackfillState
  ) {
    let newlyHeld = ids.filter { state.heldBack[type]?.records[$0] == nil }
    hold(ids, of: type, reason, &state)
    uncount(newlyHeld.count, of: type, &state)
  }

  /// Stops holding back records: they went up, or Health no longer has them.
  private func release(
    _ ids: [String], of type: String, because reason: String, _ state: inout HealthBackfillState
  ) {
    guard var held = state.heldBack[type], !held.records.isEmpty else { return }
    let before = held.records.count
    for id in ids { held.records[id] = nil }
    guard held.records.count != before else { return }
    state.heldBack[type] = held.count == 0 ? nil : held
    BackfillLog.write(
      "\(before - held.records.count) held back of \(BackfillLog.name(type)) \(reason)")
  }

  /// Reads a type again from the start, once it's caught up from its anchor (a read from the
  /// start finds no deletions), if records an older build held back aren't known by ID (past
  /// `maxHeldRecords`, or refused without being named), so what's still in Health goes up.
  private func readAgainIfUnnamed(
    _ type: HealthBackfillType, _ state: inout HealthBackfillState
  ) async throws {
    guard let held = state.heldBack[type.id], held.unnamed > 0, held.unnamedBuild != build
    else { return }
    forgetHowFarRead(
      type, because: "\(held.unnamed) held back by an older build weren't named", &state)
    try storage.saveState(state)
    updateCounts(state)
    startCounting()
    try await sync(type, &state)
  }

  /// Tries a type's held-back records again, in a run of everything: by ID, as a page of their
  /// own at the type's anchor, so nothing else moves.
  private func retryHeldBack(
    _ type: HealthBackfillType, _ state: inout HealthBackfillState
  ) async throws {
    guard let held = state.heldBack[type.id], let anchor = state.anchors[type.id] else { return }
    let due = held.records.filter { $0.value.isDue(build: build) }.keys.sorted()
    guard !due.isEmpty else { return }
    BackfillLog.write("trying \(due.count) held back of \(BackfillLog.name(type.id)) again")
    // A series that still can't be read is held back again, rather than failing the type.
    var reading = type
    reading.skipsUnreadableSeries = true
    var page = try await reader.records(reading, due)
    let sent = Set(page.mutations.map(\.id))
    let found = sent.union(page.failed)
    // Gone from Health, so gone from the server too: deleting one it doesn't have does nothing,
    // and a deletion it refused goes up this way.
    let gone = due.filter { !found.contains($0) }
    page.mutations += gone.map { .delete(type.entity, id: $0) }
    release(gone, of: type.id, because: "aren't in Health", &state)
    page.anchor = anchor
    page.hasMore = !state.finished.contains(type.id)
    _ = try await uploadPage(
      page, of: type, from: nil, retried: due.filter(sent.contains), &state)
  }

  /// At most this many batches wait to be checked; past it the oldest pages aren't.
  static let maxUncheckedBatches = 1_000

  /// Asks the server how the oldest uploaded batches went (851-4151), up to as many as it
  /// answers at once. Records it refused are held back, and a batch it failed (it never
  /// applied, e.g. its store kept failing) sends its page again: its type goes back to the
  /// anchor the page was read from. Batches still queued wait for the next check. Can't be
  /// asked (offline, an older server): they wait too.
  private func checkUploads(_ state: inout HealthBackfillState) async throws {
    let asked = Array(
      state.uploaded.lazy.flatMap(\.batches).prefix(HealthBatchStatusReader.maxBatches))
    uploadedSinceCheck = 0
    guard !asked.isEmpty else { return }
    let statuses: [String: HealthBatchStatus]
    do {
      statuses = Dictionary(
        try await statusReader.statuses(asked).map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first })
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      BackfillLog.write("checking \(asked.count) batches failed: \(error)")
      return
    }
    let isAsked = Set(asked)
    /// Types sent again from an earlier page: their later pages go up again too. Those read
    /// again from the start keep none of their pages.
    var rewound: Set<String> = []
    var restarted: Set<String> = []
    var kept: [HealthBackfillState.UploadedPage] = []
    for var page in state.uploaded {
      let name = BackfillLog.name(page.type)
      if rewound.contains(page.type), page.from != nil {
        uncount(page.records, of: page.type, &state)
        continue
      }
      let answered = page.batches.compactMap { isAsked.contains($0) ? statuses[$0] : nil }
      for batch in page.batches where isAsked.contains(batch) && statuses[batch] == nil {
        BackfillLog.write("batch \(batch) of \(name) is unknown to the server")
      }
      let waiting = page.batches.filter { batch in
        !isAsked.contains(batch) || ["queued", "applying"].contains(statuses[batch]?.status)
      }
      let failed = answered.filter { $0.status == "failed" }
      for status in failed {
        BackfillLog.write(
          "batch \(status.id) of \(name) failed: \(status.failure ?? "no reason")")
      }
      for status in answered
      where !["queued", "applying", "applied", "failed"].contains(status.status) {
        BackfillLog.write("batch \(status.id) of \(name) is \(status.status)")
      }
      // A page sent again whole needn't hold back what its other batches refused: it's all
      // read again.
      if failed.isEmpty || page.from == nil {
        for status in answered where status.status == "applied" && status.rejected > 0 {
          holdRefused(status, of: page, &state)
        }
      }
      if !failed.isEmpty {
        if let from = page.from {
          rewind(page, to: from, &state)
          rewound.insert(page.type)
          if from.isEmpty { restarted.insert(page.type) }
        } else if let retried = page.retried {
          // A page of series read again (851-4149) counted none, but its samples are counted:
          // held back, they're uncounted once, since sending them again counts them again.
          let newlyHeld = retried.filter { state.heldBack[page.type]?.records[$0] == nil }
          uncount(max(page.records, newlyHeld.count), of: page.type, &state)
          hold(retried, of: page.type, .failed, &state)
        } else {
          // Saved before pages were checked: not known by ID or anchor.
          uncount(page.records, of: page.type, &state)
          holdUnnamed(page.records, of: page.type, &state)
        }
        continue
      }
      page.batches = waiting
      if !page.batches.isEmpty { kept.append(page) }
    }
    state.uploaded = kept.filter { !restarted.contains($0.type) }
    try storage.saveState(state)
    updateCounts(state)
  }

  /// Holds back the records of a page's batch the server refused: those it names, by ID, and
  /// the rest (past the 100 it lists) by count. They're no longer counted as uploaded.
  private func holdRefused(
    _ status: HealthBatchStatus, of page: HealthBackfillState.UploadedPage,
    _ state: inout HealthBackfillState
  ) {
    BackfillLog.write(
      "batch \(status.id) of \(BackfillLog.name(page.type)): \(status.rejected) lines refused")
    let type = types.first { $0.id == page.type }
    var named: [String] = []
    /// Series whose values were refused (851-4149), though their samples went up.
    var seriesRefused: [String] = []
    var unnamed = max(0, status.rejected - status.rejectedLines.count)
    for line in status.rejectedLines {
      if let entity = line.entity, let id = line.id {
        if entity == type?.entity {
          named.append(id)
        } else if entity == HealthEncoder.quantitySeriesEntity {
          seriesRefused.append(id)
        } else if type?.isCorrelation == true, entity == HealthEncoder.sampleEntity {
          // A correlation's sample is read with it, so it can't be looked up by its own ID:
          // the type (a small one) is read again instead.
          unnamed += 1
        }
        // Otherwise a provenance record, which isn't a record of the type.
      } else {
        unnamed += 1
      }
    }
    hold(named, of: page.type, .refused, &state)
    holdSeries(seriesRefused.filter { !named.contains($0) }, of: page.type, .refused, &state)
    if unnamed > 0 { holdUnnamed(unnamed, of: page.type, &state) }
    uncount(named.count + unnamed, of: page.type, &state)
  }

  /// Sends a page again whose batch the server failed, and every later one of its type: the type
  /// goes back to the anchor it was read from, and is asked for again.
  private func rewind(
    _ page: HealthBackfillState.UploadedPage, to from: Data, _ state: inout HealthBackfillState
  ) {
    guard let type = types.first(where: { $0.id == page.type }) else { return }
    if from.isEmpty {
      forgetHowFarRead(type, because: "a batch of its first page failed", &state)
    } else {
      uncount(page.records, of: type.id, &state)
      state.anchors[type.id] = from
      state.finished.remove(type.id)
      BackfillLog.write("reading \(BackfillLog.name(type.id)) again from a page whose batch failed")
    }
    requestedTypes.insert(type.id)
  }

  /// Takes records that turned out not to go up out of the counts.
  private func uncount(_ records: Int, of type: String, _ state: inout HealthBackfillState) {
    let count = min(records, state.uploadedByType[type, default: 0])
    guard count > 0 else { return }
    state.uploadedByType[type, default: 0] -= count
    state.uploadedRecords = max(0, state.uploadedRecords - count)
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
    // Not a series' values (851-4149): their sample says the same, and a page of series read
    // again (`readSeriesAgain`) changes no sums.
    for mutation in mutations where mutation.entity == type.entity {
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
  /// since they last went up, the Activity summaries, all of them the first time and the last 30
  /// days' after that, and the Health Documents shared since. A failure is kept for the next run.
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
    // Last: its query may wait on Health's sheet for new documents.
    do {
      try await uploadDocuments(&state)
    } catch {
      try stopIfRunEnds(error)
      reportIssue(error, "Uploading Health Documents; trying again next run")
    }
  }

  /// Health Documents read with their XML and uploaded at once: each one's XML is in memory until
  /// it's gone up, and may be megabytes.
  static let documentPage = 10

  /// Uploads the Health Documents Health shares that haven't gone up, with their XML as blobs,
  /// and deletes those it no longer shares (851-2836). Health shares them one by one, asking the
  /// person about new ones when they're queried, and may stop sharing one at any time, so which
  /// ones are shared is read every run, as for vision prescriptions. They never change, so only
  /// new ones are read with their XML, a page at a time, each page saved once it's up.
  private func uploadDocuments(_ state: inout HealthBackfillState) async throws {
    let shared = try await documentsReader.shared()
    let removed = state.documentIDs.subtracting(shared)
    if !removed.isEmpty {
      try await uploadMutations(
        removed.sorted().map { HealthMutation.delete(HealthEncoder.documentEntity, id: $0) })
      state.documentIDs.subtract(removed)
      state.lastUploadAt = now()
      try storage.saveState(state)
      updateCounts(state)
    }
    let added = shared.subtracting(state.documentIDs).sorted()
    for start in stride(from: 0, to: added.count, by: Self.documentPage) {
      try Task.checkCancellation()
      let page = Array(added[start..<min(start + Self.documentPage, added.count)])
      var rows: [HealthMutation] = []
      var handled: [String] = []
      for document in try await documentsReader.read(page) {
        let (mutation, blob) = HealthEncoder.document(document)
        handled.append(mutation.id)
        // Skipped for good: it would be refused every time, and documents never change.
        guard blob.count <= HealthBlob.maxBytes else {
          reportIssue(HealthBlob.TooLarge(bytes: blob.count))
          continue
        }
        // Before the row that refers to it, by its SHA-256.
        guard case .string(let sha256)? = mutation.row?["xml"] else { continue }
        try await notingServerFailure {
          try await Self.retryingTransient(retryDelays, clock: clock) {
            try await blobUploader.upload(sha256, blob)
          }
        }
        rows.append(mutation)
      }
      try await uploadMutations(rows)
      // Documents no longer shared since `shared` aren't read, and stay out.
      state.documentIDs.formUnion(handled)
      if !rows.isEmpty { state.lastUploadAt = now() }
      try storage.saveState(state)
      updateCounts(state)
    }
  }

  /// The doses uploaded for each medication: a JSON object of medication concept IDs to their
  /// doses' IDs. A file rather than part of the state, which is saved after every step, since
  /// there may be thousands.
  static let medicationDosesFile = "medication-doses.json"
  /// Its contents, once read, so each page of doses doesn't read it again.
  private var medicationDoses: [String: Set<String>]?

  /// Uploads the medications, if they changed since they last went up, before a run of
  /// everything reads the types (851-2571). Health shares them one by one and may share one
  /// added long ago, or stop sharing one, at any time, like vision prescriptions:
  /// - One no longer shared is deleted, and so is every dose uploaded for it (its doses can't be
  ///   read anymore, so their deletions never come through the dose type's anchor).
  /// - One shared since comes with doses from before the dose type's anchor, which reading on
  ///   from it would miss, so the dose type is read again from the start, in this run. The
  ///   server skips the doses it already has unchanged. Otherwise doses are only read from their
  ///   anchor, so thousands of them don't go up again every run.
  ///
  /// A failure is kept for the next run, and so is how far the doses were read: until the
  /// medications go up, reading every dose again would repeat each run.
  private func uploadMedications(_ state: inout HealthBackfillState) async throws {
    let before = state
    do {
      let medications = try await medicationsReader.read()
      let read = Set(medications.map(\.id))
      let removed = before.medicationIDs.subtracting(read)
      // Only needed to delete a medication no longer shared with its doses.
      var doses = removed.isEmpty ? [:] : try loadMedicationDoses()
      // In the state the upload saves, so the app being killed after it can't lose it.
      if !read.isSubset(of: before.medicationIDs) { readDosesAgain(&state) }
      try await uploadWhole(
        medications, as: HealthEncoder.medicationEntity, hash: \.medicationsHash,
        ids: \.medicationIDs, &state
      ) { removed in
        removed.flatMap { medication in
          (doses[medication] ?? []).sorted().map {
            HealthMutation.delete(HealthEncoder.medicationDoseEntity, id: $0)
          }
        }
      }
      if !removed.isEmpty {
        for medication in removed { doses[medication] = nil }
        try saveMedicationDoses(doses)
      }
    } catch {
      keepDoseProgress(from: before, &state)
      try stopIfRunEnds(error)
      reportIssue(error, "Uploading medications; trying again next run")
    }
  }

  /// Forgets how far the dose type was read, so it's read from the start: what it uploaded is
  /// counted again as it goes up again.
  private func readDosesAgain(_ state: inout HealthBackfillState) {
    for type in types
    where type.entity == HealthEncoder.medicationDoseEntity && state.anchors[type.id] != nil {
      forgetHowFarRead(type, because: "medications shared since", &state)
    }
  }

  /// Forgets how far a type was read, so it's read from the start: what it uploaded is counted
  /// again as it goes up again. A read from the start finds no deletions, so a type is caught up
  /// from its anchor first, or its deletions since are lost.
  private func forgetHowFarRead(
    _ type: HealthBackfillType, because reason: String, _ state: inout HealthBackfillState
  ) {
    state.anchors[type.id] = nil
    state.finished.remove(type.id)
    state.uploadedRecords = max(
      0, state.uploadedRecords - state.uploadedByType[type.id, default: 0])
    state.uploadedByType[type.id] = nil
    // Every record is read again: those that still don't go up are held back again, and its
    // pages read before mustn't move its anchor back.
    state.heldBack[type.id] = nil
    state.uploaded.removeAll { $0.type == type.id }
    // Read from the start, every series goes up with its values (851-4149).
    noteSeriesEncoding(of: type, &state)
    BackfillLog.write("reading \(BackfillLog.name(type.id)) again: \(reason)")
  }

  /// Reads workouts again from the start, once they're caught up from their anchor, if they were
  /// read with an older encoding (`HealthBackfillState.workoutEncoding`), so every workout goes
  /// up again with what's new: their activities' locations and their plans (851-4030), their
  /// metadata's quantities whole (851-4150). Workouts
  /// are few (hundreds, a few thousand at most), and the server and the Mac take each again as a
  /// change. After the catch-up, since a read from the start finds no deletions. Workouts that
  /// had no anchor before it (`wasRead` false) were all just read with this encoding.
  private func readAgainIfOlder(
    _ type: HealthBackfillType, wasRead: Bool, _ state: inout HealthBackfillState
  ) async throws {
    guard type.entity == HealthEncoder.workoutEntity,
      state.workoutEncoding < HealthEncoder.workoutEncoding
    else { return }
    if wasRead { forgetHowFarRead(type, because: "read with an older encoding", &state) }
    // Before the read: one interrupted carries on from its own anchor next time.
    state.workoutEncoding = HealthEncoder.workoutEncoding
    try storage.saveState(state)
    updateCounts(state)
    guard wasRead else { return }
    // Counted again, as for a new backfill, unless the run's count is still going.
    startCounting()
    try await sync(type, &state)
  }

  /// A quantity type read from the start (its first read, or read again) reads every series with
  /// their values (851-4149), so its series needn't be read again.
  private func noteSeriesEncoding(
    of type: HealthBackfillType, _ state: inout HealthBackfillState
  ) {
    guard type.isQuantity, state.anchors[type.id] == nil,
      state.quantitySeriesEncodings[type.id] != HealthEncoder.quantitySeriesEncoding
    else { return }
    state.quantitySeriesEncodings[type.id] = HealthEncoder.quantitySeriesEncoding
    state.seriesAgainAnchors[type.id] = nil
  }

  /// Reads a quantity type's series again (samples with `count` over 1), if its samples were read
  /// with an older encoding (`HealthBackfillState.quantitySeriesEncodings`), so the series
  /// uploaded before their values were go up with them (851-4149). Only the series, through an
  /// anchored query of their count, and only their values' records: their samples haven't
  /// changed. In runs of everything, once the type has caught up from its anchor, a page at a
  /// time, resuming where it stopped. Each page goes up as held-back records sent again do, at the
  /// type's anchor, so a batch that fails holds its series back to try again by ID.
  private func readSeriesAgain(
    _ type: HealthBackfillType, _ state: inout HealthBackfillState
  ) async throws {
    guard type.isQuantity,
      state.quantitySeriesEncodings[type.id, default: 0] < HealthEncoder.quantitySeriesEncoding
    else { return }
    if let anchor = state.anchors[type.id] {
      if state.seriesAgainAnchors[type.id] == nil {
        BackfillLog.write("reading \(BackfillLog.name(type.id))'s series again")
      }
      var isLast = false
      while !isLast {
        try Task.checkCancellation()
        var reading = type
        reading.skipsUnreadableSeries =
          state.seriesFailures[type.id, default: 0] >= Self.seriesAttempts
        var page = try await reader.series(
          reading, state.seriesAgainAnchors[type.id], Self.pageSize)
        state.seriesFailures[type.id] = nil
        let read = page.anchor
        isLast = !page.hasMore
        // Those held back go up whole when they're tried again; their series alone would let
        // them go (`release`) though their samples haven't.
        let held = state.heldBack[type.id]?.records ?? [:]
        page.mutations.removeAll { held[$0.id] != nil }
        holdSeries(page.failed, of: type.id, .unreadable, &state)
        page.failed = []
        if !page.mutations.isEmpty {
          page.anchor = anchor
          page.hasMore = !state.finished.contains(type.id)
          _ = try await uploadPage(
            page, of: type, from: nil, retried: page.mutations.map(\.id), &state)
        }
        state.seriesAgainAnchors[type.id] = read
        try storage.saveState(state)
      }
    }
    state.seriesAgainAnchors[type.id] = nil
    state.quantitySeriesEncodings[type.id] = HealthEncoder.quantitySeriesEncoding
    try storage.saveState(state)
  }

  /// Undoes `readDosesAgain` since `before`, if the medications didn't go up after it.
  private func keepDoseProgress(
    from before: HealthBackfillState, _ state: inout HealthBackfillState
  ) {
    for type in types where type.entity == HealthEncoder.medicationDoseEntity {
      state.anchors[type.id] = before.anchors[type.id]
      if before.finished.contains(type.id) { state.finished.insert(type.id) }
      state.uploadedByType[type.id] = before.uploadedByType[type.id]
    }
    state.uploadedRecords = before.uploadedRecords
  }

  /// Notes a page of doses in each medication's doses (`medicationDosesFile`), before the page
  /// goes up, so a medication no longer shared can have its doses deleted. A page that doesn't go
  /// up is read again, so the file may name doses the server doesn't have, which are harmless to
  /// delete. Deleted doses are taken out.
  private func recordDoses(_ mutations: [HealthMutation]) throws {
    var doses = try loadMedicationDoses()
    var medicationOf: [String: String] = [:]
    for (medication, ids) in doses {
      for id in ids { medicationOf[id] = medication }
    }
    var changed = false
    // In order: a page's deletions come after its additions, as the server applies them.
    for mutation in mutations {
      let medication: String?
      switch mutation.op {
      case .upsert:
        guard case .string(let id)? = mutation.row?["medication"] else { continue }
        medication = id
      case .delete:
        medication = nil
      }
      let previous = medicationOf[mutation.id]
      guard previous != medication else { continue }
      if let previous {
        doses[previous]?.remove(mutation.id)
        if doses[previous]?.isEmpty == true { doses[previous] = nil }
      }
      if let medication { doses[medication, default: []].insert(mutation.id) }
      medicationOf[mutation.id] = medication
      changed = true
    }
    if changed { try saveMedicationDoses(doses) }
  }

  /// The doses uploaded for each medication. One that can't be read is reported and started
  /// over: medications no longer shared then keep their doses on the server.
  private func loadMedicationDoses() throws -> [String: Set<String>] {
    if let medicationDoses { return medicationDoses }
    var doses: [String: Set<String>] = [:]
    if let data = try storage.loadFile(Self.medicationDosesFile) {
      do {
        doses = try JSONDecoder().decode([String: Set<String>].self, from: data)
      } catch {
        reportIssue(error, "Reading the doses uploaded for each medication; starting over")
      }
    }
    medicationDoses = doses
    return doses
  }

  private func saveMedicationDoses(_ doses: [String: Set<String>]) throws {
    if doses.isEmpty {
      try storage.removeFile(Self.medicationDosesFile)
    } else {
      try storage.saveFile(Self.medicationDosesFile, try JSONEncoder().encode(doses))
    }
    medicationDoses = doses
  }

  /// Uploads records read whole each run, if they changed since they last went up (`hash`).
  /// One that's no longer readable (access was turned off, or it was deleted) is deleted, with
  /// what `alsoDeleting` gives for those IDs, in the same upload.
  private func uploadWhole(
    _ records: [HealthMutation], as entity: String,
    hash: WritableKeyPath<HealthBackfillState, String?>,
    ids: WritableKeyPath<HealthBackfillState, Set<String>>, _ state: inout HealthBackfillState,
    alsoDeleting: (_ removed: [String]) -> [HealthMutation] = { _ in [] }
  ) async throws {
    let current = try Self.hash(records)
    guard current != state[keyPath: hash] else { return }
    let read = Set(records.map(\.id))
    let removedIDs = state[keyPath: ids].subtracting(read).sorted()
    let removed =
      removedIDs.map { HealthMutation.delete(entity, id: $0) } + alsoDeleting(removedIDs)
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
        BackfillLog.write("a \(error.entity) record is over the server's 1 MB")
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
  /// too large for the server is left out, so it can't stop the backfill, and named in
  /// `tooLarge` to be held back. A line can't be split: each is a whole record, and an upsert
  /// sets every field it has.
  private func write(_ page: HealthPage, of type: HealthBackfillType) throws -> (
    pending: HealthBackfillState.PendingPage, files: [Data],
    blobs: [(sha256: String, data: Data)], tooLarge: [String]
  ) {
    var blobs: [(sha256: String, data: Data)] = []
    var skippedBlobs: Set<String> = []
    for blob in page.blobs {
      let sha256 = HealthBlob.sha256(blob)
      guard blob.count <= HealthBlob.maxBytes else {
        BackfillLog.write(
          "a blob of \(BackfillLog.name(type.id)) is too large: \(blob.count) bytes")
        skippedBlobs.insert(sha256)
        continue
      }
      if !blobs.contains(where: { $0.sha256 == sha256 }) { blobs.append((sha256, blob)) }
    }
    var writer = HealthBatchWriter(maxRecords: Self.batchRecords)
    var files: [Data] = []
    var tooLarge: [String] = []
    var records = 0
    for mutation in page.mutations {
      // A record whose blob was skipped goes too, so none refers to a blob that never arrives.
      if !skippedBlobs.isEmpty,
        mutation.row?.values.contains(where: { value in
          if case .string(let string) = value { skippedBlobs.contains(string) } else { false }
        }) == true
      {
        tooLarge.append(mutation.id)
        continue
      }
      do {
        if let file = try writer.append(mutation) { files.append(file) }
        // A series' values are part of its sample's record (851-4149).
        if mutation.entity != HealthEncoder.quantitySeriesEntity { records += 1 }
      } catch is HealthBatchWriter.LineTooLong {
        BackfillLog.write("a record of \(BackfillLog.name(type.id)) is over the server's 1 MB")
        tooLarge.append(mutation.id)
      }
    }
    if let file = try writer.finish() { files.append(file) }
    let pending = HealthBackfillState.PendingPage(
      type: type.id, anchor: page.anchor, isLast: !page.hasMore,
      batches: files.map { _ in uuid().uuidString.lowercased() }, blobs: blobs.map(\.sha256),
      records: records)
    return (pending, files, blobs, tooLarge)
  }

  /// Uploads a page's blobs, then its batches, so no row arrives before its blob. Then commits
  /// its anchor. Returns whether it did, rather than dropping the page (its files went missing).
  @discardableResult
  private func upload(
    _ pending: HealthBackfillState.PendingPage, _ state: inout HealthBackfillState
  ) async throws -> Bool {
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
    if missingBlob {
      try dropPage()
      return false
    }
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
    if missingBatch {
      try dropPage()
      return false
    }
    BackfillLog.write(
      "uploaded \(BackfillLog.name(pending.type)): \(pending.records) records, \(pending.batches.count) batches, \(pending.blobs.count) blobs in \(BackfillLog.since(uploading))"
    )
    state.anchors[pending.type] = pending.anchor
    if pending.isLast { state.finished.insert(pending.type) }
    state.pending = nil
    state.uploadedRecords += pending.records
    state.uploadedByType[pending.type, default: 0] += pending.records
    if !pending.batches.isEmpty {
      state.lastUploadAt = now()
      // Checked later, once the server has applied them. A page saved before pages were checked
      // has no `from`, and isn't sent again if a batch failed.
      state.uploaded.append(
        .init(
          type: pending.type, batches: pending.batches, from: pending.from,
          records: pending.records, retried: pending.retried))
      uploadedSinceCheck += pending.batches.count
      var unchecked = state.uploaded.reduce(0) { $0 + $1.batches.count }
      while unchecked > Self.maxUncheckedBatches, let oldest = state.uploaded.first {
        unchecked -= oldest.batches.count
        state.uploaded.removeFirst()
        BackfillLog.write("not checking \(oldest.batches.count) batches: too many waiting")
      }
    }
    if let retried = pending.retried {
      release(retried, of: pending.type, because: "went up", &state)
    }
    try storage.saveState(state)
    for file in pending.files { try storage.removeFile(file) }
    updateCounts(state)
    return true
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
      lastUploadAt: state.lastUploadAt,
      heldBack: state.heldBack.mapValues(\.count).filter { $0.value > 0 })
  }

  private func updateCounts(_ state: HealthBackfillState) {
    let counts = Self.progress(types, state)
    update {
      $0.finishedTypes = counts.finishedTypes
      $0.uploadedRecords = counts.uploadedRecords
      $0.types = counts.types
      $0.lastUploadAt = counts.lastUploadAt
      $0.totalRecords = totalRecords(counts)
      $0.heldBack = counts.heldBack
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
