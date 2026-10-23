#if os(macOS)
  import AppKit
  import Charts
  import SnapshotTesting
  import SwiftUI
  import Testing

  // Snapshots never take the wallpaper's tint (851-3172), which `fixTimeZoneAndLocale()` turns
  // off. With "Allow wallpaper tinting in windows" on, a view Swift Charts draws (a sparkline's
  // hollow latest dot) resolved `.background.secondary` 16 levels lighter in dark mode than the
  // same view outside a chart, so dark images depended on the Mac's setting. Only a Mac with the
  // setting on can fail it. Linked by `MessagesSnapshotTests` too.
  extension MacSnapshotTests {
    @Test func chartsDrawTheBackgroundWithoutTheWallpapersTint() throws {
      // Two 20 pt squares side by side at the top left, on red: the second is a chart's only
      // point, at its center.
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.red),
        appearance: .darkAqua, title: "Tinting")
      defer { window.close() }
      var image: CGImage?
      Snapshotting.layerImage.snapshot(window.contentView!).run {
        image = $0.cgImage(forProposedRect: nil, context: nil, hints: nil)
      }
      let pixels = NSBitmapImageRep(cgImage: try #require(image))
      // Each square's center, in pixels.
      func channels(atPoint x: CGFloat) throws -> [Int] {
        let color = try #require(
          pixels.colorAt(x: Int(x * snapshotScale), y: Int(10 * snapshotScale)))
        return [color.redComponent, color.greenComponent, color.blueComponent].map {
          Int(($0 * 255).rounded())
        }
      }
      let plain = try channels(atPoint: 10)
      let charted = try channels(atPoint: 30)
      // Both gray, so neither is the red around the squares.
      #expect(Set(plain).count == 1 && Set(charted).count == 1, "\(plain), \(charted)")
      #expect(
        zip(plain, charted).allSatisfy { abs($0 - $1) <= snapshotChannelTolerance },
        "\(plain), \(charted)")
    }
  }
#endif
