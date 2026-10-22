#if os(macOS)
  import AppKit
  import SnapshotTesting
  import SwiftUI
  import Testing

  // `layerImage` draws SwiftUI's layers again at 2x before rendering (851-2986, 851-3010): a layer
  // whose contents were last drawn at 1x, as a flaky snapshot's blurred text was, comes out as it
  // should. In `MacSnapshotTests`, which is serialized, so it never runs beside a snapshot.
  extension MacSnapshotTests {
    @Test func layersDrawnAt1xAreDrawnAgainAt2x() throws {
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 240, height: 80), styleMask: [.borderless],
        backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      // Primary and secondary text: SwiftUI draws the two kinds of layer `layerImage` redraws.
      let view = NSHostingView(
        rootView: VStack {
          Text("Spotting").font(.title.bold())
          Text("Synthetic iPhone").foregroundStyle(.secondary)
        }
        .frame(width: 240, height: 80)
        .environment(\.displayScale, 2))
      window.contentView = view
      view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      let expected = try #require(png(Snapshotting.layerImage.snapshot(view)))

      // As the flaky snapshots had it: SwiftUI's layers drawn at 1x.
      func drawAt1x(_ layer: CALayer) {
        if "\(type(of: layer))" == "CGDrawingLayer" {
          layer.contentsScale = 1
          layer.setNeedsDisplay()
          layer.displayIfNeeded()
        }
        layer.sublayers?.forEach(drawAt1x)
      }
      drawAt1x(view.layer!)
      #expect(try #require(png(Snapshotting.layerImage.snapshot(view))) == expected)
    }

    private func png(_ image: Async<NSImage>) -> Data? {
      var data: Data?
      image.run { image in
        data = NSBitmapImageRep(
          cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        ).representation(using: .png, properties: [:])
      }
      return data
    }
  }
#endif
