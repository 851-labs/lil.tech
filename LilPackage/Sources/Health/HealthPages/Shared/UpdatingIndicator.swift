public import SwiftUI

extension View {
  /// A small spinner over the view's top trailing corner while `isUpdating`: a page showing one
  /// period while the next loads puts it over its header (851-3084). Over the view, in a slot of
  /// its own size, so it moves nothing; the view keeps the slot's width clear on its trailing
  /// side, loading or not, so a long line (a hovered value) never runs under it.
  public func updatingIndicator(_ isUpdating: Bool) -> some View {
    padding(.trailing, 20)
      .overlay(alignment: .topTrailing) {
        if isUpdating {
          ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
        }
      }
  }
}
