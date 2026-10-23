public import SwiftUI

/// A small spinner in a slot of its own size while `isUpdating`, empty otherwise, for a row that
/// has no free corner: a month calendar's header, whose top right has its arrows (851-3090).
/// Always laid out, so what's beside it never moves.
public struct UpdatingSlot: View {
  let isUpdating: Bool

  public init(_ isUpdating: Bool) {
    self.isUpdating = isUpdating
  }

  public var body: some View {
    ZStack {
      if isUpdating {
        ProgressView()
          .controlSize(.small)
      }
    }
    .frame(width: 16, height: 16)
  }
}

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
