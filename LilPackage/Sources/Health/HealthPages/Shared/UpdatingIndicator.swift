public import SwiftUI

extension View {
  /// A small spinner over the view's top trailing corner while `isUpdating`: a page showing one
  /// period while the next loads puts it over its header (851-3084). Over the view, in a slot of
  /// its own size, so it takes no space and moves nothing.
  public func updatingIndicator(_ isUpdating: Bool) -> some View {
    overlay(alignment: .topTrailing) {
      if isUpdating {
        ProgressView()
          .controlSize(.small)
          .frame(width: 16, height: 16)
      }
    }
  }
}
