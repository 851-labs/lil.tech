import Dependencies
import HealthKitAccess
import HealthUpload
import LilAuth

/// Keeps the server up to date with Health while the app runs or is woken in the background.
public enum HealthChanges {
  /// Starts observing every type. Call it at every launch, from the app's initializer: background
  /// launches don't connect a scene, so a view's task would be too late. Changes are uploaded
  /// only while signed in.
  public static func observe() async {
    @Dependency(\.healthAuthorization) var healthAuthorization
    @Dependency(\.healthObserver) var healthObserver
    @Dependency(\.healthBackfill) var healthBackfill
    @Dependency(\.authSessions) var authSessions
    guard healthAuthorization.isAvailable() else { return }
    await healthObserver.start(HealthBackfillType.current) { type in
      guard (try? await authSessions.accessToken()) != nil else { return }
      // Failures are kept in the progress, and the type is tried again on the next change.
      try? await healthBackfill.syncChanges(of: [type])
    }
  }
}
