#if os(macOS)
  import AppKit
  import CoreGraphics
  import Foundation
  import ImageIO
  import SnapshotTesting
  import SwiftUI
  import Synchronization
  import Testing

  /// Renders `view` as Xcode's canvas shows a Mac preview, in a window with a title bar (so its
  /// toolbar renders) of the given appearance, and compares it with its reference image,
  /// `__Snapshots__/<test file>/<screen>.<name>-<light|dark>.png` (851-2931), `mac` unless a
  /// catalog names the screen (851-2949).
  ///
  /// The window is never on screen and the app never activates, so this needs no Xcode, no
  /// Screen Recording access and no display of a particular scale, and runs beside other agents.
  /// Liquid Glass (toolbar controls, a switch's tint, the window buttons) doesn't draw offscreen.
  @MainActor
  func assertMacSnapshot(
    of view: some View, appearance: NSAppearance.Name, named name: String, screen: String = "mac",
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
    let output = SnapshotOutput(file: file, testName: screen, name: "\(name)-\(suffix)")
    // The window's frame view: its title bar and toolbar, and the content. `assertSnapshot` is
    // these two calls (for Swift Testing, which these tests use); `scripts/snapshot` needs the
    // result in between.
    let failure = withSnapshotTesting(diffTool: output?.diffTool) {
      verifySnapshot(
        of: window.contentView!.superview!, as: output?.strategy ?? .layerImage,
        named: "\(name)-\(suffix)", fileID: fileID, file: file, testName: screen, line: line,
        column: column)
    }
    output?.report(failure: failure)
    if let failure {
      Issue.record(
        Comment(rawValue: failure),
        sourceLocation: SourceLocation(
          fileID: "\(fileID)", filePath: "\(file)", line: Int(line), column: Int(column)))
    }
    window.close()
  }

  /// Where `scripts/snapshot` wants every image this process takes, `LIL_SNAPSHOT_OUTPUT` (851-2962):
  /// `<output>/<test file>/<test>.<name>.png`, encoded as SnapshotTesting encodes references. A
  /// changed image also gets `<test>.<name>.diff.png`, its changed pixels in red over a faded copy
  /// of it. Each snapshot adds a line to `<output>/report.tsv`: its result, the image, the reference
  /// and the diff. The result is `matches`, `differs`, `recorded` (a new reference, or record mode),
  /// `rerecorded` (it differed, and record mode replaced the reference) or `failed` (anything else
  /// SnapshotTesting reported, such as a timeout). `swift test` sets none of this and writes nothing.
  @MainActor
  private struct SnapshotOutput {
    let image: URL
    let reference: URL
    let diff: URL
    let reportFile: URL
    /// The reference's modification date before the snapshot, to tell whether it was recorded.
    let previousReference: Date?
    /// Whether SnapshotTesting called the diff tool: the image didn't match its reference.
    let differed = Flag()

    init?(file: StaticString, testName: String, name: String) {
      guard let output = ProcessInfo.processInfo.environment["LIL_SNAPSHOT_OUTPUT"] else {
        return nil
      }
      // Where SnapshotTesting keeps the reference: `__Snapshots__/<test file>/<test>.<name>.png`
      // next to the test file, with its names made safe as SnapshotTesting does
      // (`sanitizePathComponent`, which isn't public).
      func sanitized(_ component: String) -> String {
        component
          .replacingOccurrences(of: "\\W+", with: "-", options: .regularExpression)
          .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
      }
      let testFile = URL(filePath: "\(file)")
      let folder = testFile.deletingPathExtension().lastPathComponent
      let fileName = "\(sanitized(testName)).\(sanitized(name)).png"
      image = URL(filePath: output).appending(components: folder, fileName)
      reference = testFile.deletingLastPathComponent()
        .appending(components: "__Snapshots__", folder, fileName)
      diff = image.deletingPathExtension().appendingPathExtension("diff.png")
      reportFile = URL(filePath: output).appending(component: "report.tsv")
      previousReference = modificationDate(of: reference)
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
    /// and says where the three are. It compares the image `strategy` wrote, which has the same
    /// bytes as the failed image SnapshotTesting writes to its artifacts folder.
    var diffTool: SnapshotTestingConfiguration.DiffTool {
      let (image, diff, differed) = (image, diff, differed)
      return SnapshotTestingConfiguration.DiffTool { reference, _ in
        differed.set()
        let summary = writeDiff(reference: URL(filePath: reference), image: image, to: diff)
        return """
          \(summary)
          reference: \(reference)
          image:     \(image.path)
          diff:      \(diff.path)
          """
      }
    }

    func report(failure: String?) {
      let fileManager = FileManager.default
      let recorded = modificationDate(of: reference) != previousReference
      let result =
        switch (failure != nil, differed.isSet, recorded) {
        case (false, _, _): "matches"
        case (true, true, true): "rerecorded"
        case (true, true, false): "differs"
        case (true, false, true): "recorded"
        case (true, false, false): "failed"
        }
      let diffPath = fileManager.fileExists(atPath: diff.path) ? diff.path : ""
      let line = [result, image.path, reference.path, diffPath].joined(separator: "\t") + "\n"
      if !fileManager.fileExists(atPath: reportFile.path) {
        fileManager.createFile(atPath: reportFile.path, contents: nil)
      }
      guard let handle = try? FileHandle(forWritingTo: reportFile) else { return }
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    }
  }

  /// From the file system each time (a `URL` caches its resource values).
  private func modificationDate(of url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  /// A flag the diff tool, which must be `Sendable`, can set.
  private final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
  }

  /// Writes `image`'s pixels that differ from `reference`'s by more than the tolerance
  /// (`snapshotChannelTolerance`) in red, over a faded copy of `image`, and describes how much
  /// changed and by how much. Through raw buffers: the tests build without optimization.
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
    // Pixels further apart than the tolerance (or in only one image), and those within it,
    // which match and aren't drawn.
    var changed = 0
    var tolerated = 0
    var largest: UInt32 = 0
    var box = (minX: width, minY: height, maxX: -1, maxY: -1)
    old.words.withUnsafeBufferPointer { oldWords in
      new.words.withUnsafeBufferPointer { newWords in
        diff.withUnsafeMutableBufferPointer { diff in
          for y in 0..<height {
            for x in 0..<width {
              let a: UInt32? = x < old.width && y < old.height ? oldWords[y * old.width + x] : nil
              let b: UInt32? = x < new.width && y < new.height ? newWords[y * new.width + x] : nil
              var isChanged = a != b
              if isChanged, let a, let b {
                let difference = channelDifference(a, b)
                largest = max(largest, difference)
                if difference <= snapshotChannelTolerance {
                  tolerated += 1
                  isChanged = false
                }
              }
              if isChanged {
                changed += 1
                box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
                diff[y * width + x] = red
              } else if let b {
                // The image over white, in gray, a quarter as dark. Its pixels are
                // premultiplied, so over white a channel shows as itself plus 255 minus alpha.
                let gray =
                  ((b & 0xFF) * 299 + (b >> 8 & 0xFF) * 587 + (b >> 16 & 0xFF) * 114) / 1000
                let faded = 255 - ((b >> 24) - min(gray, b >> 24)) / 4
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
    let tolerance = snapshotChannelTolerance
    var summary =
      "\(changed) of \(width * height) pixels differ by more than \(tolerance) in a color channel"
    if largest > 0 {
      summary += ", by up to \(largest)"
    }
    if changed > 0 {
      summary +=
        ", within x \(box.minX)–\(box.maxX), y \(box.minY)–\(box.maxY) (pixels, from the top left)"
    }
    if tolerated > 0 {
      summary += "; \(tolerated) more differ by \(tolerance) at most, which matches"
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
    return pixels(of: image)
  }

  private func pixels(of image: NSImage) -> Pixels? {
    image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(pixels(of:))
  }

  private func pixels(of image: CGImage) -> Pixels? {
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
    /// `.image` draws with `cacheDisplay(in:to:)`, which got Swift Charts' colors wrong. Compared
    /// with `.image(channelTolerance: snapshotChannelTolerance)`.
    @MainActor
    static var layerImage: Snapshotting {
      SimplySnapshotting(
        pathExtension: "png", diffing: .image(channelTolerance: snapshotChannelTolerance)
      ).pullback { view in
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

  /// How far a pixel's channels may be from its reference's and still match (851-2985). The same
  /// screen rendered on macOS 27.0 (the Mac minis) and 27.0.1 (a laptop) comes out 1 apart in
  /// gradients, symbols and the toolbar's search field, which no one can see. Anything that moves
  /// or recolors what's drawn is further apart.
  let snapshotChannelTolerance = 1

  extension Diffing where Value == NSImage {
    /// SnapshotTesting's exact comparison, except that an image of the reference's size whose
    /// every pixel is within `tolerance` of the reference's, in each channel (alpha included),
    /// matches. One pixel further apart fails, with SnapshotTesting's message and attachments.
    /// The image is compared as it would be recorded, through its PNG, as SnapshotTesting
    /// compares it.
    static func image(channelTolerance tolerance: Int) -> Diffing {
      let exact = Diffing.image(precision: 1, perceptualPrecision: 1)
      return .diff(toData: exact.toData, fromData: exact.fromData) { reference, image in
        guard let failure = exact.diffV2(reference, image) else { return nil }
        guard let old = pixels(of: reference),
          let new = pixels(of: exact.fromData(exact.toData(image))),
          let difference = largestChannelDifference(old, new)
        else { return failure }
        if difference <= tolerance { return nil }
        return (
          "\(failure.0) Its pixels differ by up to \(difference) in a color channel, more than "
            + "the \(tolerance) that matches.",
          failure.1
        )
      }
    }
  }

  /// The largest difference between two images' pixels in any channel, or nil when their sizes
  /// differ. Through raw buffers: the tests build without optimization.
  private func largestChannelDifference(_ a: Pixels, _ b: Pixels) -> Int? {
    guard (a.width, a.height) == (b.width, b.height) else { return nil }
    var largest: UInt32 = 0
    a.words.withUnsafeBufferPointer { a in
      b.words.withUnsafeBufferPointer { b in
        var index = 0
        while index < a.count {
          defer { index += 1 }
          let (x, y) = (a[index], b[index])
          if x != y { largest = max(largest, channelDifference(x, y)) }
        }
      }
    }
    return Int(largest)
  }

  /// The largest difference between two RGBA words' channels.
  private func channelDifference(_ a: UInt32, _ b: UInt32) -> UInt32 {
    var largest: UInt32 = 0
    for shift: UInt32 in [0, 8, 16, 24] {
      let (x, y) = (a >> shift & 0xFF, b >> shift & 0xFF)
      largest = max(largest, x > y ? x - y : y - x)
    }
    return largest
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
