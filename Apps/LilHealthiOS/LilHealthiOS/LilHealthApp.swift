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
    }
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: Self.store)
    }
  }
}
