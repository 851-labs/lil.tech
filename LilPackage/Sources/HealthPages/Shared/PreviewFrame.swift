public import SwiftUI

extension View {
  /// A Mac preview's size: `width` × `height`, its content at the top.
  public func previewFrame(width: CGFloat, height: CGFloat) -> some View {
    frame(width: width, height: height, alignment: .top)
  }
}
