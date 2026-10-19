import Foundation
import SwiftUI

extension View {
  /// A Mac preview's size: `width` × `height`, its content at the top.
  ///
  /// In Pixelbook's snapshots, `height` is only a minimum. SnapshotPreviews grows a preview until
  /// its first scroll view shows all its content, and content held to a fixed height stayed that
  /// height and was centered in the taller snapshot, leaving a blank band above it (851-2706).
  /// Xcode's canvas keeps the fixed height: there, a scroll view free to size to its content can
  /// take longer than the canvas waits.
  func previewFrame(width: CGFloat, height: CGFloat) -> some View {
    frame(width: width)
      .frame(minHeight: height, maxHeight: inPixelbook ? nil : height, alignment: .top)
  }
}

/// Whether Pixelbook's snapshot tests are rendering this, which `scripts/pixelbook` says.
private let inPixelbook = ProcessInfo.processInfo.environment["PIXELBOOK"] == "1"
