public import ComposableArchitecture
import Foundation
import HealthUpload
import LilAuth
import OSLog

#if os(iOS)
  import BackgroundTasks
  import Network
  import UIKit
#endif

/// The backfill's background work on the iPhone. Health can't be read while the phone is locked,
/// which is when iOS usually runs a `BGProcessingTask`, so the first upload mostly runs through a
/// continued processing task the user starts: it carries on after they leave the app, pausing
/// while the phone is locked.
public enum HealthBackgroundWork {
  /// In Info.plist's `BGTaskSchedulerPermittedIdentifiers`.
  public static let taskIdentifier = "tech.lil.health.sync"
  /// The continued processing task (iOS 26) that keeps an upload going after the user leaves the
  /// app, also in `BGTaskSchedulerPermittedIdentifiers`.
  public static let uploadTaskIdentifier = "tech.lil.health.upload"

  /// Registers the background tasks' handlers, and in development builds turns on the
  /// backfill's diagnostics log (`BackfillLog`). Call it from the app's initializer: iOS
  /// requires it before launch finishes.
  public static func register() {
    #if DEBUG
      // What the upload does and how long each step takes, for diagnosing stalls on a device.
      BackfillLog.isEnabled.setValue(true)
      BackfillLog.write("launched")
    #endif
    #if os(iOS)
      BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
        let task = UncheckedSendable(task)
        Task { await run(task.value) }
      }
      BGTaskScheduler.shared.register(forTaskWithIdentifier: uploadTaskIdentifier, using: nil) {
        task in
        guard let continued = task as? BGContinuedProcessingTask else {
          task.setTaskCompleted(success: false)
          return
        }
        let task = UncheckedSendable(continued)
        Task { await runContinued(task.value) }
      }
    #endif
  }

  /// Keeps the backfill going after the user leaves the app, with its progress in the system's
  /// UI, until it's done or iOS expires the task. Call it right after a user action starts the
  /// backfill (finishing onboarding, Continue): iOS only runs these for work the user started.
  /// Does nothing once everything is uploaded.
  public static func continueInBackground() async {
    #if os(iOS)
      @Dependency(\.healthBackfill) var healthBackfill
      let progress = await healthBackfill.currentProgress()
      // Nothing to do, or nothing that could go up: no task to show. One still running (e.g.
      // paused while the phone was locked) carries on by itself.
      guard !progress.isFinished, !progress.isStorageFull,
        continuedUpload.withValue({ $0.claimRequest(now: .now) })
      else { return }
      let request = BGContinuedProcessingTaskRequest(
        identifier: uploadTaskIdentifier, title: uploadTitle,
        subtitle: UploadProgress(progress).subtitle)
      // If iOS can't run it now, the upload still goes on while the app is open.
      request.strategy = .fail
      do {
        try BGTaskScheduler.shared.submit(request)
        BackfillLog.write("continued task requested")
      } catch {
        BackfillLog.write("continued task not accepted: \(error)")
        continuedUpload.withValue { $0.requestedAt = nil }
      }
    #endif
  }

  static let uploadTitle = "Uploading your Health history"
  /// The continued upload tasks asked for and running, so there's only ever one.
  static let continuedUpload = LockIsolated(ContinuedUpload())

  struct ContinuedUpload: Equatable, Sendable {
    var running = 0
    /// When one was last asked for, until it starts.
    var requestedAt: Date?
    /// How long a request is waited for before another can be made: iOS starts one at once or
    /// not at all (`strategy = .fail`), so a request this old didn't take.
    static let requestTimeout: TimeInterval = 30

    /// Whether to ask for a task now, noting that one was. Not while one runs or was just asked
    /// for: opening the app can ask several times before the first one starts.
    mutating func claimRequest(now: Date) -> Bool {
      guard running == 0 else { return false }
      if let requestedAt, now.timeIntervalSince(requestedAt) < Self.requestTimeout { return false }
      requestedAt = now
      return true
    }

    /// A task starting. Returns whether it's the only one.
    mutating func start() -> Bool {
      requestedAt = nil
      running += 1
      return running == 1
    }
  }
  static let pausedSubtitle = "Paused until you unlock your iPhone"

  /// Why the continued upload ended, in the device's log (Console, `subsystem:tech.lil.health`).
  static let log = Logger(subsystem: "tech.lil.health", category: "ContinuedUpload")

  /// How a run of the backfill for a background task ended.
  enum RunOutcome: Equatable, Sendable {
    case finished
    /// The phone is locked, so Health can't be read.
    case locked
    /// There's no connection.
    case offline
    /// Some of it failed (e.g. a type the server refused): worth another run. `madeProgress`
    /// if it uploaded something before failing.
    case failed(String, madeProgress: Bool)
    /// Can't go on: cancelled, signed out, no consent, or the account's storage is full.
    case stopped
  }

  /// What the continued task says instead of its progress.
  enum Notice: Equatable, Sendable {
    case locked
    case offline
    case retrying(String)
    case failed(String)
  }

  /// Waits before running again after failed runs in a row. Short, since iOS may expire a
  /// continued task whose progress stays put.
  static let retryDelays: [Duration] = [.seconds(15), .seconds(30), .seconds(60), .seconds(120)]

  /// The continued upload's work: runs the backfill until it's done.
  /// - **Locked or offline:** waits for `unlocked` or `online`, then runs again.
  /// - **Failed:** runs again after each of `retryDelays`, since one type failing doesn't mean
  ///   the rest of the upload can't go on. A run that uploaded something starts the retries
  ///   over. Only after they're used up is it failed.
  /// - **Stopped:** ends at once.
  ///
  /// `notice` tells the task's UI meanwhile. Returns whether it finished; it stops once
  /// cancelled (the task expired). iOS may expire a task whose progress stays put for long:
  /// opening the app picks the upload up again then.
  static func runUntilDone(
    run: @Sendable () async -> RunOutcome,
    unlocked: @Sendable () async -> Void,
    online: @Sendable () async -> Void,
    wait: @Sendable (Duration) async -> Void,
    notice: @Sendable (Notice?) async -> Void
  ) async -> Bool {
    var failures = 0
    while !Task.isCancelled {
      let outcome = await run()
      log.notice("Run ended: \(String(describing: outcome), privacy: .public)")
      BackfillLog.write("continued task: run ended \(outcome)")
      switch outcome {
      case .finished:
        return true
      case .stopped:
        return false
      case .locked:
        await notice(.locked)
        await unlocked()
      case .offline:
        await notice(.offline)
        await online()
      case .failed(let reason, let madeProgress):
        if madeProgress { failures = 0 }
        guard failures < retryDelays.count else {
          log.error("Gave up after \(failures) retries: \(reason, privacy: .public)")
          BackfillLog.write("continued task: gave up after \(failures) retries: \(reason)")
          await notice(.failed(reason))
          return false
        }
        await notice(.retrying(reason))
        await wait(retryDelays[failures])
        failures += 1
      }
      // Expired meanwhile: the task is complete, so nothing more is shown.
      guard !Task.isCancelled else { return false }
      await notice(nil)
    }
    return false
  }

  /// A failure as the task's UI says it: the error's own description if it has one, not
  /// Foundation's generic "The operation couldn't be completed".
  static func reason(_ error: any Error) -> String {
    (error as? any LocalizedError)?.errorDescription ?? "Some Health data couldn't be uploaded."
  }

  /// What a continued upload reports: records uploaded, against a total estimated from the types
  /// done so far. Records move on with every page, unlike types, which can take a long while
  /// each, so iOS never sees the task as stalled.
  struct UploadProgress: Equatable {
    var completed: Int64
    var total: Int64
    var subtitle: String

    init(_ progress: HealthBackfill.Progress) {
      let records = Int64(progress.uploadedRecords)
      completed = records
      if progress.isFinished {
        total = records
      } else if let counted = progress.totalRecords {
        // Every type left counted: exact, short of the end until it's done.
        total = max(Int64(counted), records + 1)
      } else {
        // Each type left counts as much as an average finished type with data: empty types
        // finish first and would otherwise make the end look near. Rough early on.
        let finished = progress.types.values.filter { $0.isDone && $0.uploadedRecords > 0 }
        let average =
          finished.isEmpty
          ? Double(max(records, 1))
          : Double(finished.map(\.uploadedRecords).reduce(0, +)) / Double(finished.count)
        let left = Double(progress.totalTypes - progress.finishedTypes)
        total = max(records + 1, records + Int64((left * average).rounded()))
      }
      subtitle = UploadCopy.left(
        records: progress.uploadedRecords, totalRecords: progress.totalRecords)
    }
  }

  /// Asks iOS for background time while signed in, with consent, with an unfinished backfill, and
  /// withdraws the request otherwise, or while the account's storage is full, which refuses every
  /// upload.
  public static func scheduleIfNeeded() async {
    #if os(iOS)
      @Dependency(\.healthBackfill) var healthBackfill
      @Dependency(\.authSessions) var authSessions
      let progress = await healthBackfill.currentProgress()
      @Shared(.healthConsentPolicyVersion) var consented
      let signedIn = (try? await authSessions.accessToken()) != nil
      guard signedIn, consented == HealthConsentClient.policyVersion,
        !progress.isFinished, !progress.isStorageFull
      else {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        return
      }
      let request = BGProcessingTaskRequest(identifier: taskIdentifier)
      request.requiresNetworkConnectivity = true
      // Fails in the simulator, which doesn't run background tasks.
      try? BGTaskScheduler.shared.submit(request)
    #endif
  }

  #if os(iOS)
    /// Runs the backfill for a background task, if it can: the phone is unlocked (Health can't
    /// be read otherwise), with consent and signed in. Consent refused by the server (withdrawn
    /// on another iPhone, or a new policy) is cleared here, so nothing uploads until it's given
    /// again.
    private static func runBackfill() async -> RunOutcome {
      @Dependency(\.healthBackfill) var backfill
      @Dependency(\.authSessions) var sessions
      @Shared(.healthConsentPolicyVersion) var consented
      // First, so a locked phone (the usual case for a `BGProcessingTask`) doesn't refresh the
      // token for nothing.
      guard await isUnlocked() else { return .locked }
      guard consented == HealthConsentClient.policyVersion,
        (try? await sessions.accessToken()) != nil, !Task.isCancelled
      else { return .stopped }
      let before = await backfill.currentProgress().uploadedRecords
      do {
        try await backfill.run()
        return .finished
      } catch is HealthBatchUploader.ConsentRequired {
        $consented.withLock { $0 = nil }
        return .stopped
      } catch is HealthReader.Locked {
        return .locked
      } catch is HealthBatchUploader.StorageFull {
        return .stopped
      } catch {
        if Task.isCancelled || error is CancellationError { return .stopped }
        // As the backfill classified it for the app's status.
        let progress = await backfill.currentProgress()
        if progress.isOffline { return .offline }
        return .failed(reason(error), madeProgress: progress.uploadedRecords > before)
      }
    }

    /// Returns once there's a connection, or the task is cancelled.
    private static func waitUntilOnline() async {
      let monitor = NWPathMonitor()
      let waiting = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
      let resume = { @Sendable in
        waiting.withValue {
          $0?.resume()
          $0 = nil
        }
      }
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          waiting.setValue(continuation)
          monitor.pathUpdateHandler = { path in
            if path.status == .satisfied { resume() }
          }
          monitor.start(queue: .global(qos: .utility))
          if Task.isCancelled { resume() }
        }
      } onCancel: {
        resume()
      }
      monitor.cancel()
    }

    private static func isUnlocked() async -> Bool {
      await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
    }

    /// Returns once the phone is unlocked, or the task is cancelled. Observes the unlock before
    /// checking, so it can't miss one. Already unlocked (Health said locked just as the phone was
    /// unlocked), it waits a few seconds, so the run isn't retried in a tight loop.
    private static func waitUntilUnlocked() async {
      let unlocks = await MainActor.run {
        UncheckedSendable(
          NotificationCenter.default.notifications(
            named: UIApplication.protectedDataDidBecomeAvailableNotification))
      }
      guard !(await isUnlocked()) else {
        try? await Task.sleep(for: .seconds(10))
        return
      }
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await _ in unlocks.value { return }
        }
        // In case the notification never comes, and so cancellation always ends the wait.
        group.addTask {
          while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if await isUnlocked() { return }
          }
        }
        await group.next()
        group.cancelAll()
      }
    }

    /// Runs `task`'s work (e.g. `runBackfill`), completing the task exactly once: when the work ends,
    /// or when iOS expires the task (or the user cancels it), which stops the work. The
    /// backfill is only paused then if the app isn't in front, where its own run carries on.
    private static func perform(
      _ task: BGTask, work: @escaping @Sendable () async -> Bool,
      alongside side: (@Sendable () async -> Void)? = nil
    ) async {
      @Dependency(\.healthBackfill) var healthBackfill
      let backfill = healthBackfill
      let completed = LockIsolated(false)
      let bgTask = UncheckedSendable(task)
      let complete = { @Sendable (success: Bool) in
        guard
          !completed.withValue({
            defer { $0 = true }
            return $0
          })
        else { return }
        bgTask.value.setTaskCompleted(success: success)
      }
      let sideTask = side.map { side in Task { await side() } }
      let work = Task { await work() }
      task.expirationHandler = {
        BackfillLog.write("background task expired: \(task.identifier)")
        work.cancel()
        Task { @MainActor in
          if UIApplication.shared.applicationState != .active { await backfill.pause() }
        }
        complete(false)
      }
      let finished = await work.value
      sideTask?.cancel()
      // Before completing, since iOS may suspend the app as soon as the task completes.
      await scheduleIfNeeded()
      complete(finished)
    }

    /// The background processing task: continues the backfill while iOS allows.
    private static func run(_ task: BGTask) async {
      await perform(task) { await runBackfill() == .finished }
    }

    /// The continued processing task: the upload the user started, with its progress in the
    /// system's UI, until it's done or the task expires. It pauses while the phone is locked
    /// rather than failing, and carries on once it's unlocked.
    private static func runContinued(_ task: BGContinuedProcessingTask) async {
      @Dependency(\.healthBackfill) var healthBackfill
      @Dependency(\.continuousClock) var continuousClock
      let (backfill, clock) = (healthBackfill, continuousClock)
      let bgTask = UncheckedSendable(task)
      let notice = LockIsolated<Notice?>(nil)
      let shown = LockIsolated<UploadProgress?>(nil)
      /// Shows `progress`, or the last progress again when the pause changes. In the lock, so
      /// updates from the progress stream and from pausing don't interleave.
      @Sendable func show(_ progress: HealthBackfill.Progress?) {
        shown.withValue { shown in
          if let progress { shown = UploadProgress(progress) }
          guard let upload = shown else { return }
          bgTask.value.progress.totalUnitCount = upload.total
          bgTask.value.progress.completedUnitCount = upload.completed
          let subtitle =
            switch notice.value {
            case .locked: pausedSubtitle
            case .offline: "Paused until you're back online"
            case .retrying(let reason): "Trying again shortly. \(reason)"
            case .failed(let reason): "Couldn't upload. \(reason)"
            case nil: upload.subtitle
            }
          bgTask.value.updateTitle(uploadTitle, subtitle: subtitle)
        }
      }
      let id = String(UUID().uuidString.prefix(8))
      guard continuedUpload.withValue({ $0.start() }) else {
        // iOS ran a second one anyway: the first is doing the work.
        BackfillLog.write("continued task \(id) started alongside another: completed")
        continuedUpload.withValue { $0.running -= 1 }
        task.setTaskCompleted(success: true)
        return
      }
      let started = ContinuousClock.now
      BackfillLog.write("continued task \(id) started")
      defer {
        continuedUpload.withValue { $0.running -= 1 }
        BackfillLog.write("continued task \(id) ended after \(BackfillLog.since(started))")
      }
      await perform(
        task,
        work: {
          await runUntilDone(
            run: runBackfill, unlocked: waitUntilUnlocked, online: waitUntilOnline,
            wait: { try? await clock.sleep(for: $0) },
            notice: { new in
              notice.setValue(new)
              show(nil)
            })
        },
        alongside: {
          for await progress in await backfill.progressUpdates() { show(progress) }
        })
    }
  #endif
}

extension DependencyValues {
  /// Keeps an upload the user started going after they leave the app.
  public var backgroundUpload: BackgroundUpload {
    get { self[BackgroundUpload.self] }
    set { self[BackgroundUpload.self] = newValue }
  }
}

/// Requests the continued processing task for an upload the user started
/// (`HealthBackgroundWork.continueInBackground()`).
public struct BackgroundUpload: Sendable {
  public var start: @Sendable () async -> Void

  public init(start: @escaping @Sendable () async -> Void) {
    self.start = start
  }
}

extension BackgroundUpload: DependencyKey {
  public static var liveValue: Self {
    Self { await HealthBackgroundWork.continueInBackground() }
  }

  public static var testValue: Self {
    Self { reportIssue("Unimplemented: @Dependency(\\.backgroundUpload).start") }
  }
}
