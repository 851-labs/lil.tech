import Foundation
import SnapshottingTests

/// Every preview linked into this test: lil health for iPhone's, and the modules it uses. Light or
/// dark comes from the simulator's appearance, which `scripts/pixelbook` sets.
final class HealthPhoneSnapshots: SnapshotTest {
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
