import SwiftUI

/// An empty app that hosts the iPhone's snapshot tests (`HealthPhoneSnapshotTests`, 851-2953):
/// they draw in its key window, through the window server, so Liquid Glass renders.
@main
struct PhoneSnapshotHostApp: App {
  var body: some Scene {
    WindowGroup {
      Color.clear
    }
  }
}
