import SwiftUI

extension View {
  /// A Mac preview's size: `width` wide and at least `height` tall, its content at the top.
  ///
  /// Not a fixed height: Pixelbook's snapshots (SnapshotPreviews) grow a preview until its first
  /// scroll view shows all its content. Content held to a fixed height stayed that height and was
  /// centered in the taller snapshot, leaving a blank band above it (851-2706). This way it grows
  /// with the snapshot, which then shows everything, as the iPhone's do.
  func previewFrame(width: CGFloat, height: CGFloat) -> some View {
    frame(width: width).frame(minHeight: height, alignment: .top)
  }
}
