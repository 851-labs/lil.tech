import AppKit
public import SwiftUI

// lil health for Mac's page colors, behind and under the cards on Summary, the categories, a
// metric's detail, Sleep, workouts and Cycle Tracking.

extension Color {
  /// A page's background: the window's, as Mac apps' content is, rather than iPhone Health's
  /// gray or black (851-2755). Each page paints it, so previews and snapshots, which have no
  /// window behind them, show it too.
  public static let pageBackground = Color(nsColor: .windowBackgroundColor)

  /// A card on `pageBackground`: the system's secondary fill, as a grouped form's sections are
  /// in System Settings, so it stands out in either appearance and follows the system's settings.
  public static let cardBackground = Color(nsColor: .secondarySystemFill)
}
