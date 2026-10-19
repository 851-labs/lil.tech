import AppKit
import SnapshottingTests

/// Every preview linked into this test: lil messages', and the modules it uses.
final class MessagesMacSnapshots: SnapshotTest {
  override class func setUp() {
    super.setUp()
    // Light or dark, as `scripts/pixelbook` asks: windows take the app's appearance.
    let dark = ProcessInfo.processInfo.environment["PIXELBOOK_APPEARANCE"] == "dark"
    // XCTest sets up classes on the main thread.
    MainActor.assumeIsolated {
      NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
  }

  /// Only some previews, if `scripts/pixelbook` was given `PIXELBOOK_PREVIEWS`.
  override class func snapshotPreviews() -> [String]? {
    pixelbookPreviews()
  }
}

/// `PIXELBOOK_PREVIEWS`: comma-separated regular expressions matched against each preview's
/// `Module/File.swift:Name`, e.g. `AppViewPreviews.swift`. All of them if it's empty. (The same in
/// both snapshot targets.)
private func pixelbookPreviews() -> [String]? {
  let patterns = (ProcessInfo.processInfo.environment["PIXELBOOK_PREVIEWS"] ?? "")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
  return patterns.isEmpty ? nil : patterns
}
