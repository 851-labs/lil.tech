#if os(macOS)
  import AppKit
  import CoreGraphics
  import Foundation
  import ImageIO
  import SnapshotTesting
  import SwiftUI

  /// Renders `view` as Xcode's canvas shows a Mac preview, in a window with a title bar (so its
  /// toolbar renders) of the given appearance, and compares it with its reference image,
  /// `__Snapshots__/<suite>/mac.<name>-<light|dark>.png` (851-2931).
  ///
  /// The window is never on screen and the app never activates, so this needs no Xcode, no
  /// Screen Recording access and no display of a particular scale, and runs beside other agents.
  /// Liquid Glass (toolbar controls, a switch's tint, the window buttons) doesn't draw offscreen.
  @MainActor
  func assertMacSnapshot(
    of view: some View, appearance: NSAppearance.Name, named name: String,
    fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function,
    line: UInt = #line, column: UInt = #column
  ) {
    prepareSnapshotEnvironment()
    // The app's too, as Pixelbook sets it: Swift Charts' axis labels take the app's appearance,
    // so a dark snapshot taken after a light one could get light mode's labels.
    NSApplication.shared.appearance = NSAppearance(named: appearance)
    let controller = NSHostingController(
      rootView: view.environment(\.locale, Locale(identifier: "en_US")))
    controller.sizingOptions = [.preferredContentSize]
    let window = SnapshotWindow(contentViewController: controller)
    window.isReleasedWhenClosed = false
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.title = name
    window.appearance = NSAppearance(named: appearance)
    window.setContentSize(controller.view.fittingSize)
    // Let SwiftUI lay out and draw, and charts settle.
    controller.view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let suffix = appearance == .darkAqua ? "dark" : "light"
    let output = SnapshotOutput(file: file, testName: "mac", name: "\(name)-\(suffix)")
    // The window's frame view: its title bar and toolbar, and the content.
    withSnapshotTesting(diffTool: output?.diffTool) {
      assertSnapshot(
        of: window.contentView!.superview!, as: output?.strategy ?? .layerImage,
        named: "\(name)-\(suffix)", fileID: fileID, file: file, testName: "mac", line: line,
        column: column)
    }
    output?.report()
    window.close()
  }

  /// Where `scripts/snapshot` wants every image this process takes, `LIL_SNAPSHOT_OUTPUT` (851-2962):
  /// `<output>/<test file>/<test>.<name>.png`, the same path SnapshotTesting writes a failed image
  /// to when `SNAPSHOT_ARTIFACTS` is `<output>` too, with the same bytes. A changed image also gets
  /// `<test>.<name>.diff.png`, its changed pixels in red over a faded copy of it. Each snapshot adds
  /// a line to `<output>/report.tsv`: its result (`matches`, `differs`, `recorded`, or
  /// `rerecorded` when it differed and record mode replaced the reference), the image, the
  /// reference and the diff. `swift test` sets none of this and writes nothing.
  @MainActor
  private struct SnapshotOutput {
    let image: URL
    let reference: URL
    let diff: URL
    let reportFile: URL
    /// The reference before the snapshot, to tell whether it was recorded.
    let previousReference: Data?

    init?(file: StaticString, testName: String, name: String) {
      guard let output = ProcessInfo.processInfo.environment["LIL_SNAPSHOT_OUTPUT"] else {
        return nil
      }
      // As SnapshotTesting names references (names here are already safe as paths).
      let testFile = URL(filePath: "\(file)")
      let folder = testFile.deletingPathExtension().lastPathComponent
      let fileName = "\(testName).\(name)"
      image = URL(filePath: output).appending(components: folder, "\(fileName).png")
      reference = testFile.deletingLastPathComponent()
        .appending(components: "__Snapshots__", folder, "\(fileName).png")
      diff = image.deletingPathExtension().appendingPathExtension("diff.png")
      reportFile = URL(filePath: output).appending(component: "report.tsv")
      previousReference = try? Data(contentsOf: reference)
      try? FileManager.default.createDirectory(
        at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: image)
      try? FileManager.default.removeItem(at: diff)
    }

    /// `.layerImage`, also writing each image it takes, encoded as SnapshotTesting encodes
    /// references.
    var strategy: Snapshotting<NSView, NSImage> {
      let layerImage = Snapshotting<NSView, NSImage>.layerImage
      let image = image
      return Snapshotting(pathExtension: layerImage.pathExtension, diffing: layerImage.diffing) {
        view in
        layerImage.snapshot(view).map { snapshot in
          try? layerImage.diffing.toData(snapshot).write(to: image)
          return snapshot
        }
      }
    }

    /// Called by SnapshotTesting when an image doesn't match its reference: writes the diff image,
    /// and says where the three are.
    var diffTool: SnapshotTestingConfiguration.DiffTool {
      let diff = diff
      return SnapshotTestingConfiguration.DiffTool { reference, image in
        let summary = writeDiff(
          reference: URL(filePath: reference), image: URL(filePath: image), to: diff)
        return """
          \(summary)
          reference: \(reference)
          image:     \(image)
          diff:      \(diff.path)
          """
      }
    }

    func report() {
      let fileManager = FileManager.default
      let differs = fileManager.fileExists(atPath: diff.path)
      let recorded = (try? Data(contentsOf: reference)) != previousReference
      let result =
        switch (differs, recorded) {
        case (true, true): "rerecorded"
        case (true, false): "differs"
        case (false, true): "recorded"
        case (false, false): "matches"
        }
      let line =
        [result, image.path, reference.path, differs ? diff.path : ""]
        .joined(separator: "\t") + "\n"
      if !fileManager.fileExists(atPath: reportFile.path) {
        fileManager.createFile(atPath: reportFile.path, contents: nil)
      }
      guard let handle = try? FileHandle(forWritingTo: reportFile) else { return }
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    }
  }

  /// Writes `image`'s pixels that differ from `reference`'s in red, over a faded copy of `image`,
  /// and describes how much changed. Through raw buffers: the tests build without optimization.
  private func writeDiff(reference: URL, image: URL, to output: URL) -> String {
    guard let old = pixels(of: reference), let new = pixels(of: image) else {
      return "Couldn't read the images to compare them."
    }
    let width = max(old.width, new.width)
    let height = max(old.height, new.height)
    // RGBA bytes in memory order, as little-endian words: opaque white, and red.
    let white: UInt32 = 0xFFFF_FFFF
    let red: UInt32 = 0xFF00_00FF
    var diff = [UInt32](repeating: white, count: width * height)
    var changed = 0
    var box = (minX: width, minY: height, maxX: -1, maxY: -1)
    old.words.withUnsafeBufferPointer { oldWords in
      new.words.withUnsafeBufferPointer { newWords in
        diff.withUnsafeMutableBufferPointer { diff in
          for y in 0..<height {
            for x in 0..<width {
              let a: UInt32? = x < old.width && y < old.height ? oldWords[y * old.width + x] : nil
              let b: UInt32? = x < new.width && y < new.height ? newWords[y * new.width + x] : nil
              if a != b {
                changed += 1
                box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
                diff[y * width + x] = red
              } else if let b {
                // A quarter of the image's luminance over white.
                let gray =
                  ((b & 0xFF) * 299 + (b >> 8 & 0xFF) * 587 + (b >> 16 & 0xFF) * 114) / 1000
                let faded = 255 - (255 - gray) * (b >> 24) / 255 / 4
                diff[y * width + x] = 0xFF00_0000 | faded << 16 | faded << 8 | faded
              }
            }
          }
        }
      }
    }
    let data = diff.withUnsafeBufferPointer { Data(buffer: $0) }
    if let provider = CGDataProvider(data: data as CFData),
      let cgImage = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    {
      try? png.write(to: output)
    }
    var summary = "\(changed) of \(width * height) pixels differ"
    if changed > 0 {
      summary +=
        ", within x \(box.minX)–\(box.maxX), y \(box.minY)–\(box.maxY) (pixels, from the top left)"
    }
    if (old.width, old.height) != (new.width, new.height) {
      summary +=
        "; the size changed from \(old.width)×\(old.height) to \(new.width)×\(new.height)"
    }
    return summary + "."
  }

  /// An image's pixels as premultiplied RGBA in sRGB, top row first, a word each.
  private struct Pixels {
    let width: Int
    let height: Int
    let words: [UInt32]
  }

  private func pixels(of url: URL) -> Pixels? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    var words = [UInt32](repeating: 0, count: image.width * image.height)
    let drawn = words.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    return drawn ? Pixels(width: image.width, height: image.height, words: words) : nil
  }

  /// What every snapshot shares, set once in the target's test process (SwiftPM runs each test
  /// target in its own): a time zone and locale, so times, dates and numbers read the same on
  /// every Mac (references are recorded in the team's, `fixTimeZoneAndLocale()`), and an app to own
  /// windows, which a test process doesn't have, as an accessory, so it never takes focus.
  @MainActor
  func prepareSnapshotEnvironment() {
    _ = snapshotEnvironment
  }

  @MainActor
  private let snapshotEnvironment: Void = {
    fixTimeZoneAndLocale()
    NSApplication.shared.setActivationPolicy(.accessory)
  }()

  extension Snapshotting where Value == NSView, Format == NSImage {
    /// The view's layer tree drawn with `CALayer.render(in:)` at 2x, in sRGB. SnapshotTesting's
    /// `.image` draws with `cacheDisplay(in:to:)`, which got Swift Charts' colors wrong.
    @MainActor
    static var layerImage: Snapshotting {
      SimplySnapshotting.image(precision: 1, perceptualPrecision: 1).pullback { view in
        let scale: CGFloat = 2
        let size = view.bounds.size
        let context = CGContext(
          data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
          view.layer!.render(in: context)
        }
        return NSImage(cgImage: context.makeImage()!, size: size)
      }
    }
  }

  /// A window that draws as the key window, as a preview's canvas does, at 2x on any display, so
  /// a 1x one (the Mac minis') renders the same images as a laptop's.
  private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var backingScaleFactor: CGFloat { 2 }
  }
#endif
