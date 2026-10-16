import ComposableArchitecture
import Foundation
import HealthUpload
import LilAuth

#if os(iOS)
  import BackgroundTasks
  import UIKit
#endif

/// The backfill's background work on the iPhone. Health can't be read while the phone is locked,
/// which is when iOS usually runs a `BGProcessingTask`, so the first upload mostly runs through a
/// continued processing task the user starts: it carries on after they leave the app, for as long
/// as the phone stays unlocked.
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
  /// UI, until it's done or the phone locks. Call it right after a user action starts the
  /// backfill (finishing onboarding, Continue): iOS only runs these for work the user started.
  /// Does nothing once everything is uploaded.
  public static func continueInBackground() async {
    #if os(iOS)
      @Dependency(\.healthBackfill) var healthBackfill
      var updates = await healthBackfill.progressUpdates().makeAsyncIterator()
      guard let progress = await updates.next(), !progress.isFinished else { return }
      let request = BGContinuedProcessingTaskRequest(
        identifier: uploadTaskIdentifier, title: uploadTitle,
        subtitle: UploadProgress(progress).subtitle)
      // If iOS can't run it now, the upload still goes on while the app is open.
      request.strategy = .fail
      try? BGTaskScheduler.shared.submit(request)
    #endif
  }

  static let uploadTitle = "Uploading your Health history"

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
      if progress.isFinished || progress.totalTypes == 0 {
        total = records
      } else {
        // Assumes the types left are as large as the ones done, so it's rough early on.
        let doneFraction = max(Double(progress.finishedTypes), 1) / Double(progress.totalTypes)
        total = max(records + 1, Int64((Double(records) / doneFraction).rounded()))
      }
      subtitle =
        "\(progress.finishedTypes) of \(progress.totalTypes) types · \(records.formatted()) records"
    }
  }

  /// Asks iOS for background time while signed in, with consent, with an unfinished backfill, and
  /// withdraws the request otherwise, or while the account's storage is full, which refuses every
  /// upload.
  public static func scheduleIfNeeded() async {
    #if os(iOS)
      @Dependency(\.healthBackfill) var healthBackfill
      @Dependency(\.authSessions) var authSessions
      var updates = await healthBackfill.progressUpdates().makeAsyncIterator()
      let progress = await updates.next()
      @Shared(.healthConsentPolicyVersion) var consented
      let signedIn = (try? await authSessions.accessToken()) != nil
      guard signedIn, consented == HealthConsentClient.policyVersion, let progress,
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
    /// Runs the backfill until it's done or iOS takes the time back, asks for more if needed,
    /// then completes the task.
    private static func run(_ task: BGTask) async {
      @Dependency(\.healthBackfill) var healthBackfill
      @Dependency(\.authSessions) var authSessions
      let backfill = healthBackfill
      let sessions = authSessions
      let completed = LockIsolated(false)
      let bgTask = UncheckedSendable(task)
      // Exactly once, whichever of expiring and finishing comes first.
      let complete = { @Sendable (success: Bool) in
        guard
          !completed.withValue({
            defer { $0 = true }
            return $0
          })
        else { return }
        bgTask.value.setTaskCompleted(success: success)
      }
      let work = Task {
        // Health can't be read while the phone is locked, which is when these tasks usually run.
        @Shared(.healthConsentPolicyVersion) var consented
        guard await MainActor.run(body: { UIApplication.shared.isProtectedDataAvailable }),
          consented == HealthConsentClient.policyVersion,
          (try? await sessions.accessToken()) != nil, !Task.isCancelled
        else { return false }
        do {
          try await backfill.run()
          return true
        } catch is HealthBatchUploader.ConsentRequired {
          // Withdrawn on another iPhone, or the policy changed: nothing uploads until it's given.
          $consented.withLock { $0 = nil }
          return false
        } catch {
          return false
        }
      }
      task.expirationHandler = {
        // Time's up, even before the run started: stop everything and complete now.
        work.cancel()
        Task { await backfill.pause() }
        complete(false)
      }
      let finished = await work.value
      // Before completing, since iOS may suspend the app as soon as the task completes.
      await scheduleIfNeeded()
      complete(finished)
    }

    /// Runs the backfill for a continued processing task, reporting its progress, until it's
    /// done, the phone locks (Health can't be read) or iOS expires the task.
    @available(iOS 26, *)
    private static func runContinued(_ task: BGContinuedProcessingTask) async {
      @Dependency(\.healthBackfill) var healthBackfill
      let backfill = healthBackfill
      let completed = LockIsolated(false)
      let bgTask = UncheckedSendable(task)
      // Exactly once, whichever of expiring and finishing comes first.
      let complete = { @Sendable (success: Bool) in
        guard
          !completed.withValue({
            defer { $0 = true }
            return $0
          })
        else { return }
        bgTask.value.setTaskCompleted(success: success)
      }
      let reporting = Task {
        for await progress in await backfill.progressUpdates() {
          let upload = UploadProgress(progress)
          bgTask.value.progress.totalUnitCount = upload.total
          bgTask.value.progress.completedUnitCount = upload.completed
          bgTask.value.updateTitle(uploadTitle, subtitle: upload.subtitle)
        }
      }
      // Joins the run the app started, if it's still going.
      let work = Task { (try? await backfill.run()) != nil }
      task.expirationHandler = {
        work.cancel()
        Task { await backfill.pause() }
        complete(false)
      }
      let finished = await work.value
      reporting.cancel()
      await scheduleIfNeeded()
      complete(finished)
    }
  #endif
}
