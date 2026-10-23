#if os(macOS)
  import AppKit
  import Charts
  import SnapshotTesting
  import SwiftUI
  import Testing

  // Snapshots never take the wallpaper's tint (851-3172, `turnOffDesktopTinting()`). With "Allow
  // wallpaper tinting in windows" on, a view Swift Charts draws (a sparkline's hollow latest dot)
  // resolved `.background.secondary` 16 levels lighter in dark mode than the same view outside a
  // chart, so dark images depended on the Mac's setting. In `MacSnapshotTests`, whose `init` turns
  // tinting off before any window.
  extension MacSnapshotTests {
    @Test func chartsDrawTheBackgroundWithoutTheWallpapersTint() throws {
      // Two 20 pt squares side by side, the second a chart's only point, at its center.
      let square = Rectangle().fill(.background.secondary).frame(width: 20, height: 20)
      let window = snapshotWindow(
        of: HStack(spacing: 0) {
          square
          Chart {
            PointMark(x: .value("X", 1), y: .value("Y", 1)).symbol { square }
          }
          .chartXScale(domain: 0...2)
          .chartYScale(domain: 0...2)
          .chartXAxis(.hidden)
          .chartYAxis(.hidden)
          .frame(width: 20, height: 20)
        },
        appearance: .darkAqua, title: "Tinting")
      defer { window.close() }
      var image: CGImage?
      Snapshotting.layerImage.snapshot(window.contentView!).run {
        image = $0.cgImage(forProposedRect: nil, context: nil, hints: nil)
      }
      let pixels = NSBitmapImageRep(cgImage: try #require(image))
      // Each square's center, at 2x.
      let plain = try #require(pixels.colorAt(x: 20, y: 20))
      let charted = try #require(pixels.colorAt(x: 60, y: 20))
      #expect(plain == charted)
    }
  }
#endif
