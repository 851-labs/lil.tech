public import ComposableArchitecture
import Foundation
import HealthUpload
import LilAuth

#if os(iOS)
  import BackgroundTasks
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

  /// Registers the background tasks' handlers. Call it from the app's initializer: iOS requires
  /// it before launch finishes.
  public static func register() {
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
      // Nothing to do, or nothing that could go up: no task to show.
      guard !progress.isFinished, !progress.isStorageFull else { return }
      let request = BGContinuedProcessingTaskRequest(
        identifier: uploadTaskIdentifier, title: uploadTitle,
        subtitle: UploadProgress(progress).subtitle)
      // If iOS can't run it now, the upload still goes on while the app is open.
      request.strategy = .fail
      try? BGTaskScheduler.shared.submit(request)
    #endif
  }

  static let uploadTitle = "Uploading your Health history"
  static let pausedSubtitle = "Paused until you unlock your iPhone"

  /// How a run of the backfill for a background task ended.
  enum RunOutcome: Equatable, Sendable {
    case finished
    /// The phone is locked, so Health can't be read.
    case locked
    /// Failed, cancelled, or not possible (signed out, no consent).
    case stopped
  }

  /// The continued upload's work: runs the backfill and, each time it stops because the phone
  /// locked, waits for `unlocked` and runs it again, telling `paused` meanwhile. Returns whether
  /// it finished; it stops on any other outcome, or once cancelled (the task expired).
  static func runUntilDone(
    run: @Sendable () async -> RunOutcome,
    unlocked: @Sendable () async -> Void,
    paused: @Sendable (Bool) async -> Void
  ) async -> Bool {
    while !Task.isCancelled {
      switch await run() {
      case .finished: return true
      case .stopped: return false
      case .locked:
        await paused(true)
        await unlocked()
        await paused(false)
      }
    }
    return false
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
      subtitle =
        progress.totalRecords.map {
          "\(records.formatted()) of \($0.formatted()) records"
        }
        ?? "\(progress.finishedTypes) of \(progress.totalTypes) types · \(records.formatted()) records"
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
      guard consented == HealthConsentClient.policyVersion,
        (try? await sessions.accessToken()) != nil, !Task.isCancelled
      else { return .stopped }
      guard await isUnlocked() else { return .locked }
      do {
        try await backfill.run()
        return .finished
      } catch is HealthBatchUploader.ConsentRequired {
        $consented.withLock { $0 = nil }
        return .stopped
      } catch is HealthReader.Locked {
        return .locked
      } catch {
        return .stopped
      }
    }

    private static func isUnlocked() async -> Bool {
      await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
    }

    /// Returns once the phone is unlocked, or the task is cancelled. Checks every few seconds,
    /// which can't miss an unlock the way a notification posted just before observing could.
    /// Already unlocked (Health said locked just as the phone was unlocked), it waits a moment
    /// first, so the run isn't retried in a tight loop.
    private static func waitUntilUnlocked() async {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        if await isUnlocked() { return }
      }
    }

    /// Runs `task`'s work (`runBackfill`), completing the task exactly once: when the work ends,
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
      let backfill = healthBackfill
      let bgTask = UncheckedSendable(task)
      let isPaused = LockIsolated(false)
      @Sendable func show(_ progress: HealthBackfill.Progress) {
        let upload = UploadProgress(progress)
        bgTask.value.progress.totalUnitCount = upload.total
        bgTask.value.progress.completedUnitCount = upload.completed
        bgTask.value.updateTitle(
          uploadTitle, subtitle: isPaused.value ? pausedSubtitle : upload.subtitle)
      }
      await perform(
        task,
        work: {
          await runUntilDone(
            run: runBackfill, unlocked: waitUntilUnlocked,
            paused: { paused in
              isPaused.setValue(paused)
              show(await backfill.currentProgress())
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
