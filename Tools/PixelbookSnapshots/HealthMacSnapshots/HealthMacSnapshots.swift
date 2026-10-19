import AppKit
import SnapshottingTests

/// Every preview linked into this test: lil health for Mac's, and the modules it uses.
final class HealthMacSnapshots: SnapshotTest {
  override class func setUp() {
    super.setUp()
    // Light or dark, as `scripts/pixelbook` asks: windows take the app's appearance.
    let dark = ProcessInfo.processInfo.environment["PIXELBOOK_APPEARANCE"] == "dark"
    // XCTest sets up classes on the main thread.
    MainActor.assumeIsolated {
      NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
  }
}
