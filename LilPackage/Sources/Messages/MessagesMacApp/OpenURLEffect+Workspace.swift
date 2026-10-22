import AppKit
public import Dependencies

extension OpenURLEffect {
  /// Opens URLs with `NSWorkspace`.
  ///
  /// The default live `openURL` goes through SwiftUI's `EnvironmentValues().openURL`, which does
  /// nothing on macOS when called from outside a view hierarchy, such as from a reducer effect.
  public static var workspace: Self {
    Self { url in
      await MainActor.run { NSWorkspace.shared.open(url) }
    }
  }
}
