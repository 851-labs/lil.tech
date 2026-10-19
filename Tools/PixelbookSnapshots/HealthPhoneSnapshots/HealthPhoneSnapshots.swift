import Foundation
import SnapshottingTests

/// Every preview linked into this test: lil health for iPhone's, and the modules it uses. Light or
/// dark comes from the simulator's appearance, which `scripts/pixelbook` sets.
final class HealthPhoneSnapshots: SnapshotTest {
  /// Only some previews, if `scripts/pixelbook` was given `PIXELBOOK_PREVIEWS`: comma-separated
  /// regular expressions matched against each preview's `Module/File.swift:Name`, e.g.
  /// `AppView.swift`. All of them if it's empty.
  override class func snapshotPreviews() -> [String]? {
    let patterns = ProcessInfo.processInfo.environment["PIXELBOOK_PREVIEWS"]?.split(separator: ",")
    return patterns?.isEmpty == false ? patterns?.map(String.init) : nil
  }
}
