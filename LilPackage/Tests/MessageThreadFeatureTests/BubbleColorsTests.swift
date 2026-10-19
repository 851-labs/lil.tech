import AppKit
import Testing

@testable import MessageThreadFeature

struct BubbleColorsTests {
  @Test
  func iMessageIsOneBlue() {
    #expect(rgb(BubbleColors.iMessage) == [44, 172, 252])
  }

  @Test
  func receivedGrayMatchesMessagesInLightMode() throws {
    let appearance = try #require(NSAppearance(named: .aqua))
    var color: [Int] = []
    appearance.performAsCurrentDrawingAppearance {
      color = rgb(BubbleColors.received)
    }
    #expect(color == [237, 237, 238])
  }

  private func rgb(_ color: NSColor) -> [Int] {
    let srgb = color.usingColorSpace(.sRGB)!
    return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map {
      Int(($0 * 255).rounded())
    }
  }
}
