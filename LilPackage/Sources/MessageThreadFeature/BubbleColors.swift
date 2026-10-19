import AppKit

/// Bubble colors matched to Messages.app.
enum BubbleColors {
  static let received = NSColor(name: "receivedBubble") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1)
      : NSColor(srgbRed: 237 / 255, green: 237 / 255, blue: 238 / 255, alpha: 1)
  }

  static let textMessage = NSColor(srgbRed: 53 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1)

  /// One blue for every sent iMessage, not Messages.app's gradient across the visible thread.
  static let iMessage = NSColor(srgbRed: 44 / 255, green: 172 / 255, blue: 252 / 255, alpha: 1)

  static let failed = NSColor.systemRed
}
