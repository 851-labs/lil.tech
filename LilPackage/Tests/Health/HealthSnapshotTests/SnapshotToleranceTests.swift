#if os(macOS)
  import AppKit
  import SnapshotTesting
  import Testing

  // `.image(channelTolerance:)`, which snapshots are compared with (851-2985), on made-up images:
  // within the tolerance they match, and a real change still fails. In `MacSnapshotTests`, which
  // is serialized, so they never run beside a snapshot.
  extension MacSnapshotTests {
    var diffing: Diffing<NSImage> { .image(channelTolerance: snapshotChannelTolerance) }

    /// A 16×16 image: a light gradient, with a dark 4×4 square at `square`.
    func image(
      width: Int = 16, square: (x: Int, y: Int) = (6, 6),
      color: (Int, Int) -> (UInt8, UInt8, UInt8) = { x, y in (UInt8(100 + x), UInt8(150 + y), 200) }
    ) -> NSImage {
      let height = 16
      var bytes = [UInt8]()
      for y in 0..<height {
        for x in 0..<width {
          let inSquare =
            (square.x..<square.x + 4).contains(x) && (square.y..<square.y + 4).contains(y)
          let (r, g, b) = inSquare ? (20, 30, 40) : color(x, y)
          bytes += [r, g, b, 255]
        }
      }
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
      return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    /// As a reference is read back from its PNG.
    func recorded(_ image: NSImage) -> NSImage {
      diffing.fromData(diffing.toData(image))
    }

    @Test func toleranceSameImage() {
      #expect(diffing.diffV2(recorded(image()), image()) == nil)
    }

    @Test func toleranceEveryPixelOneApart() {
      // Up in one channel and down in another, everywhere, as macOS 27.0's gradients were.
      let image = image { x, y in (UInt8(101 + x), UInt8(149 + y), 201) }
      #expect(diffing.diffV2(recorded(self.image()), image) == nil)
    }

    @Test func toleranceSomePixelsTwoApart() {
      // As a laptop's GPU draws a few of the minis' pixels (851-3070, 851-3242).
      let image = image { x, y in
        (x < 4 && y == 0 ? UInt8(102 + x) : UInt8(100 + x), UInt8(150 + y), x < 4 ? 198 : 200)
      }
      #expect(diffing.diffV2(recorded(self.image()), image) == nil)
    }

    @Test func toleranceOnePixelThreeApart() throws {
      let image = image { x, y in (x == 0 && y == 0 ? 103 : UInt8(100 + x), UInt8(150 + y), 200) }
      let failure = try #require(diffing.diffV2(recorded(self.image()), image))
      #expect(failure.0.contains("differ by up to 3"))
    }

    @Test func toleranceSquareMovedOnePixel() throws {
      let failure = try #require(diffing.diffV2(recorded(image()), image(square: (7, 6))))
      #expect(failure.0.contains("differ by up to"))
    }

    @Test func toleranceRecolored() {
      let image = image { x, y in (UInt8(100 + x), UInt8(150 + y), 190) }
      #expect(diffing.diffV2(recorded(self.image()), image) != nil)
    }

    @Test func toleranceOtherSize() {
      #expect(diffing.diffV2(recorded(image()), image(width: 17)) != nil)
    }
  }
#endif
