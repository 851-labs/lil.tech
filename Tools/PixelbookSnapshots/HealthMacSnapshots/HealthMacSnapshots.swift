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

  /// Captured from the window, as the screen shows it: drawing the view (`cacheDisplay`, the
  /// default) misses vibrant content, such as the sidebar's icons (851-2711). Our fork of
  /// SnapshotPreviews adds this.
  override class func capturesWindow() -> Bool {
    true
  }

  /// Only some previews, if `scripts/pixelbook` was given `PIXELBOOK_PREVIEWS`.
  override class func snapshotPreviews() -> [String]? {
    pixelbookPreviews()
  }
}

/// `PIXELBOOK_PREVIEWS`: comma-separated regular expressions matched against each preview's
/// `Module/File.swift:Name`, e.g. `AppViewPreviews.swift`. All of them if it's empty. (The same in
/// every snapshot target.)
private func pixelbookPreviews() -> [String]? {
  let patterns = (ProcessInfo.processInfo.environment["PIXELBOOK_PREVIEWS"] ?? "")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
  return patterns.isEmpty ? nil : patterns
}
