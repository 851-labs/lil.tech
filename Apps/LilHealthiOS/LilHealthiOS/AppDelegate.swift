import HealthPhoneApp
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    let completion = UncheckedCompletion(completionHandler)
    if !HealthBackgroundWork.handleEvents(
      forBackgroundURLSession: identifier, completion: { completion.call() })
    {
      completionHandler()
    }
  }
}

/// UIKit calls the completion handler on the main thread; the session hands it back there.
private struct UncheckedCompletion: @unchecked Sendable {
  let handler: () -> Void
  init(_ handler: @escaping () -> Void) { self.handler = handler }
  func call() { handler() }
}
