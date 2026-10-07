import AppKit

/// Bubble colors matched to Messages.app.
///
/// Sent iMessage bubbles use a gradient across the visible thread, light at the top and deeper at
/// the bottom, so a bubble's color depends on where it sits in the viewport.
enum BubbleColors {
  static let received = NSColor(name: "receivedBubble") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1)
      : NSColor(srgbRed: 237 / 255, green: 237 / 255, blue: 238 / 255, alpha: 1)
  }

  static let textMessage = NSColor(srgbRed: 53 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1)

  static let failed = NSColor.systemRed

  static let iMessageTop = RGB(red: 104, green: 207, blue: 252)
  static let iMessageBottom = RGB(red: 44, green: 172, blue: 252)

  /// The iMessage blue at `fraction` of the way down the visible thread (0 is the top).
  static func iMessage(atFraction fraction: CGFloat) -> NSColor {
    let fraction = min(max(fraction, 0), 1)
    func mix(_ top: CGFloat, _ bottom: CGFloat) -> CGFloat {
      (top + (bottom - top) * fraction) / 255
    }
    return NSColor(
      srgbRed: mix(iMessageTop.red, iMessageBottom.red),
      green: mix(iMessageTop.green, iMessageBottom.green),
      blue: mix(iMessageTop.blue, iMessageBottom.blue),
      alpha: 1
    )
  }

  struct RGB {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
  }
}
