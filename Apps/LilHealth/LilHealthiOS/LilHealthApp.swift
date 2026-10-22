import ComposableArchitecture
import HealthPhoneApp
import LilAuth
import SwiftUI

@main
struct LilHealthApp: App {

  static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  init() {
    prepareDependencies {
      $0.authDevice = .current(app: "health-ios")
      $0.authenticateAPI()
      $0.keepSettingsPerServer()
    }
    HealthBackgroundWork.register()
    // Before HealthKit delivers the change that may have woken the app.
    Task { await HealthChanges.observe() }
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: Self.store)
    }
  }
}
