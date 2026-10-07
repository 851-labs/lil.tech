import AppUpdates
import ComposableArchitecture
import MessagesApp
import SwiftUI

@main
struct LilMessagesApp: App {
  static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  @State private var updater = AppUpdater()

  init() {
    prepareDependencies {
      $0.openURL = .workspace
    }
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: Self.store)
    }
    .commands {
      CheckForUpdatesCommands(updater: updater)
    }
  }
}
