import AppKit
import Testing

@testable import MessageThreadFeature

struct BubbleColorsTests {
  @Test
  func iMessageGradientRunsFromLightToDeepBlue() {
    let top = BubbleColors.iMessage(atFraction: 0)
    let bottom = BubbleColors.iMessage(atFraction: 1)
    #expect(rgb(top) == [104, 207, 252])
    #expect(rgb(bottom) == [44, 172, 252])
  }

  @Test
  func iMessageGradientClampsOutsideTheViewport() {
    #expect(
      rgb(BubbleColors.iMessage(atFraction: -0.5)) == rgb(BubbleColors.iMessage(atFraction: 0)))
    #expect(
      rgb(BubbleColors.iMessage(atFraction: 1.5)) == rgb(BubbleColors.iMessage(atFraction: 1)))
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
