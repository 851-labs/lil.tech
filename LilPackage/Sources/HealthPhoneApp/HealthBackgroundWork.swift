import Dependencies
import Foundation
import HealthUpload
import LilAuth

#if os(iOS)
  import BackgroundTasks
#endif

/// The backfill's background work on the iPhone: a `BGProcessingTask` that continues it when iOS
/// allows, and the background `URLSession` its uploads go through.
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

  /// Passes on `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. Returns
  /// `false` for another app session.
  public static func handleEvents(
    forBackgroundURLSession identifier: String, completion: @escaping @Sendable () -> Void
  ) -> Bool {
    guard identifier == BackgroundUploads.sessionIdentifier else { return false }
    BackgroundUploads.shared.handleEvents(completion: completion)
    return true
  }

  /// Asks iOS for background time while the backfill isn't finished.
  public static func scheduleIfNeeded() async {
    #if os(iOS)
      @Dependency(\.healthBackfill) var healthBackfill
      var updates = await healthBackfill.progressUpdates().makeAsyncIterator()
      guard let progress = await updates.next(), !progress.isFinished else { return }
      let request = BGProcessingTaskRequest(identifier: taskIdentifier)
      request.requiresNetworkConnectivity = true
      // Fails in the simulator, which doesn't run background tasks.
      try? BGTaskScheduler.shared.submit(request)
    #endif
  }

  #if os(iOS)
    /// Runs the backfill until it's done or iOS takes the time back, then asks for more if needed.
    private static func run(_ task: BGTask) async {
      @Dependency(\.healthBackfill) var healthBackfill
      @Dependency(\.authSessions) var authSessions
      let backfill = healthBackfill
      task.expirationHandler = { Task { await backfill.pause() } }
      guard (try? await authSessions.accessToken()) != nil else {
        return task.setTaskCompleted(success: true)
      }
      let finished = (try? await healthBackfill.run()) != nil
      task.setTaskCompleted(success: finished)
      await scheduleIfNeeded()
    }
  #endif
}
