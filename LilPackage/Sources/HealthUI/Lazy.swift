public import SwiftUI

/// A view built only when it's shown, e.g. a navigation destination that loads or works out
/// something, so a list of links doesn't do it for every row.
public struct Lazy<Content: View>: View {
  let build: () -> Content

  public init(_ build: @escaping () -> Content) {
    self.build = build
  }

  public var body: some View { build() }
}
