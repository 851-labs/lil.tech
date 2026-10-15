import Dependencies
import Foundation
import HealthUpload
import LilAuth

#if os(iOS)
  import BackgroundTasks
  import UIKit
#endif

/// The backfill's background work on the iPhone: a `BGProcessingTask` that continues it when iOS
/// allows.
public enum HealthBackgroundWork {
  /// In Info.plist's `BGTaskSchedulerPermittedIdentifiers`.
  public static let taskIdentifier = "tech.lil.health.sync"

  /// Registers the background task's handler. Call it from the app's initializer: iOS requires
  /// it before launch finishes.
  public static func register() {
    #if os(iOS)
      BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
        let task = UncheckedSendable(task)
        Task { await run(task.value) }
      }
    #endif
  }

  /// Asks iOS for background time while signed in with an unfinished backfill, and withdraws the
  /// request otherwise.
  public static func scheduleIfNeeded() async {
    #if os(iOS)
      @Dependency(\.healthBackfill) var healthBackfill
      @Dependency(\.authSessions) var authSessions
      var updates = await healthBackfill.progressUpdates().makeAsyncIterator()
      let progress = await updates.next()
      let signedIn = (try? await authSessions.accessToken()) != nil
      guard signedIn, let progress, !progress.isFinished else {
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
        guard await MainActor.run(body: { UIApplication.shared.isProtectedDataAvailable }),
          (try? await sessions.accessToken()) != nil, !Task.isCancelled
        else { return false }
        return (try? await backfill.run()) != nil
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
  #endif
}
