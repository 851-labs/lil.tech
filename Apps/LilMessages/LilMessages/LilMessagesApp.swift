import ComposableArchitecture
import MessagesApp
import SwiftUI

@main
struct LilMessagesApp: App {
  static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: Self.store)
    }
  }
}
