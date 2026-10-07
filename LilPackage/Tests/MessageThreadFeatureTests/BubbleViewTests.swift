import AppKit
import Testing

@testable import MessageThreadFeature

struct BubbleViewTests {
  @Test
  func singleLineBubblesBecomeCapsules() {
    let corner = BubbleView.corner(forHeight: 30)
    #expect(corner.radius == 15)
    #expect(corner.curve == .circular)
  }

  @Test
  func tallBubblesKeepTheContinuousCorner() {
    let corner = BubbleView.corner(forHeight: 80)
    #expect(corner.radius == 16)
    #expect(corner.curve == .continuous)
  }

  @Test
  func radiusNeverExceedsHalfTheHeight() {
    for height in stride(from: CGFloat(0), through: 64, by: 0.5) {
      #expect(BubbleView.corner(forHeight: height).radius <= height / 2)
    }
  }
}
