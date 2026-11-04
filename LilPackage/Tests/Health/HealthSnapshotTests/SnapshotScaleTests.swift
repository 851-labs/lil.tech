#if os(macOS)
  import AppKit
  import SnapshotTesting
  import SwiftUI
  import Testing

  // `layerImage` draws SwiftUI's layers again at 2x before rendering (851-2986, 851-3010): a layer
  // whose contents were last drawn at 1x, as a flaky snapshot's blurred text was, comes out as it
  // should. And `snapshotWindow` lays the toolbar's items out again, so an image SwiftUI left as it
  // first drew it, before the toolbar sized its item, comes out as it should (851-3230, 851-4046).
  // In `MacSnapshotTests`, which is serialized, so it never runs beside a snapshot.
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

    /// A toolbar image left as SwiftUI first drew it, before the toolbar sized its item, is found,
    /// and laying the items out again has the window come out as it should: a bitmap drawn for
    /// another size, as Sleep › Week's ‹ had on the minis (851-3230), or the first position, as
    /// Card Detail › HRV, week's › had (851-4046).
    @Test(arguments: [StaleToolbarImage.bitmap, .position])
    func staleToolbarImagesAreLaidOutAgain(_ stale: StaleToolbarImage) throws {
      let window = snapshotWindow(
        of: NavigationStack {
          Text("Synthetic page").frame(width: 400, height: 120)
            .toolbar {
              ToolbarItem(placement: .primaryAction) {
                Button("Previous Week", systemImage: "chevron.left") {}
              }
            }
        },
        appearance: .aqua, title: "Toolbar")
      defer { window.close() }
      let frameView = try #require(window.contentView?.superview)
      #expect(staleToolbarImages(in: window).isEmpty)
      let expected = try #require(png(Snapshotting.layerImage.snapshot(frameView)))

      // The trailing image in the title bar: the window's buttons are images too.
      let layer = try #require(
        titleBarImageLayers(in: window).max {
          $0.convert(CGPoint.zero, to: frameView.layer!).x
            < $1.convert(CGPoint.zero, to: frameView.layer!).x
        })
      switch stale {
      case .bitmap:
        // The symbol's first, smaller bitmap in its toolbar-sized layer.
        let size = (
          width: Int(layer.bounds.width * 2) - 4, height: Int(layer.bounds.height * 2) - 6
        )
        layer.contents = CGContext(
          data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()
      case .position:
        // Its final bitmap and size at its first position, around the unsized item's corner:
        // 17 pt left and 16.5 pt up of where it belongs, as HRV, week's › was.
        layer.position = CGPoint(x: layer.position.x - 17, y: layer.position.y - 16.5)
      }
      #expect(staleToolbarImages(in: window).count == 1)
      #expect(try #require(png(Snapshotting.layerImage.snapshot(frameView))) != expected)

      layOutToolbarItemsAgain(in: window)
      #expect(staleToolbarImages(in: window).isEmpty)
      #expect(try #require(png(Snapshotting.layerImage.snapshot(frameView))) == expected)
    }

    enum StaleToolbarImage: CaseIterable, Sendable {
      case bitmap, position
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
