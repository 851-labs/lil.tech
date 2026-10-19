import SwiftUI

/// An empty app that hosts the iPhone's snapshot tests: SnapshotPreviews renders iOS previews in
/// a window, which needs a running app (`scripts/pixelbook`).
@main
struct PixelbookHostApp: App {
  var body: some Scene {
    WindowGroup {
      Color.clear
    }
  }
}
