public import SwiftUI

// A page's loading state takes its loaded layout's space (851-3084): what's below the content
// (Show All Data, Data Sources) stays where it is while the content loads, and while another
// period's replaces it. The snapshot tests check it (`LayoutShiftTests`): they render a catalog's
// loading and loaded states, and compare where each puts the views marked with `layoutAnchor`.

/// Where a page's marked views are laid out, for the tests that check they don't move. Nothing
/// sets it in the app, so marking a view costs nothing there.
public struct LayoutAnchorRecorder: Sendable {
  public let record: @MainActor @Sendable (_ name: String, _ frame: CGRect) -> Void

  public init(_ record: @escaping @MainActor @Sendable (_ name: String, _ frame: CGRect) -> Void) {
    self.record = record
  }
}

extension EnvironmentValues {
  @Entry public var layoutAnchorRecorder: LayoutAnchorRecorder?
}

extension View {
  /// Marks a view that mustn't move while the page loads, e.g. its Show All Data row, by name.
  /// Reports its frame in the window to `layoutAnchorRecorder`, when a test sets one.
  public func layoutAnchor(_ name: String) -> some View {
    modifier(LayoutAnchor(name: name))
  }
}

private struct LayoutAnchor: ViewModifier {
  let name: String
  @Environment(\.layoutAnchorRecorder) private var recorder

  func body(content: Content) -> some View {
    if let recorder {
      content.onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: { frame in
        recorder.record(name, frame)
      }
    } else {
      content
    }
  }
}
