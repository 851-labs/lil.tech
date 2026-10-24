import CoreGraphics
import Foundation
import ImageIO
import SnapshotTesting
import Synchronization

#if os(macOS)
  import AppKit

  typealias PlatformImage = NSImage
#else
  import UIKit

  typealias PlatformImage = UIImage
#endif

// What the Mac's snapshot tests (`assertMacSnapshot`) and the iPhone's (`assertPhoneSnapshot`, in
// HealthPhoneSnapshotTests, which builds this file too, 851-2953) share: the images
// `scripts/snapshot` gets, their diffs, and matching within a tolerance per color channel.

/// Whether this process is CI's check on the Mac minis: `LIL_SNAPSHOT_CI=1` (851-3070). There, a
/// state with no reference is recorded, and fails, as SnapshotTesting does, so the run uploads it
/// for `scripts/fetch-snapshots`. Elsewhere (a laptop), a new state is only rendered
/// (`isNewOffCI`), unless `scripts/snapshot --record` records it (851-3242). Images are compared
/// within `snapshotChannelTolerance` everywhere.
let snapshotsOnCI = ProcessInfo.processInfo.environment["LIL_SNAPSHOT_CI"] == "1"

/// Whether SnapshotTesting records references (`scripts/snapshot --record`).
private let snapshotsRecord = ["all", "failed"].contains(
  ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_RECORD"])

/// Off CI and not recording, whether a state has no reference yet (851-3070), so is only rendered,
/// for `scripts/snapshot` to show as `new`, and doesn't fail: `scripts/snapshot --record` records
/// it (851-3242), or else CI does, and fails, until `scripts/fetch-snapshots` brings it in.
func isNewOffCI(file: StaticString, testName: String, name: String) -> Bool {
  guard !snapshotsOnCI, !snapshotsRecord else { return false }
  return !FileManager.default.fileExists(
    atPath: referenceURL(file: file, testName: testName, name: name).path)
}

/// Draws a new state's image (`isNewOffCI`) without comparing it, so a view that crashes or
/// reports an issue still does, and writes it to `output` as `new` when `scripts/snapshot` asked.
@MainActor
func renderNew<Value, Format>(
  _ value: Value, as strategy: Snapshotting<Value, Format>, to output: SnapshotOutput?
) {
  if let output {
    output.renderNew(value, as: strategy)
  } else {
    strategy.snapshot(value).run { _ in }
  }
}

/// Where `scripts/snapshot` wants every image this process takes, `LIL_SNAPSHOT_OUTPUT` (851-2962):
/// `<output>/<test file>/<test>.<name>.png`, encoded as SnapshotTesting encodes references. A
/// changed image also gets `<test>.<name>.diff.png`, its changed pixels in red over a faded copy
/// of it. Each snapshot adds a line to `<output>/report.tsv`: its result, the image, the reference
/// and the diff. The result is `matches`, `differs`, `recorded` (a new reference, or record mode),
/// `rerecorded` (it differed, and record mode replaced the reference), `failed` (anything else
/// SnapshotTesting reported, such as a timeout) or `new` (no reference yet, off CI: `isNewOffCI`).
/// `swift test` sets none of this and writes nothing.
@MainActor
struct SnapshotOutput {
  let image: URL
  let reference: URL
  let diff: URL
  let reportFile: URL
  /// The reference's modification date before the snapshot, to tell whether it was recorded.
  let previousReference: Date?
  /// Whether SnapshotTesting called the diff tool: the image didn't match its reference.
  private let differed = Flag()

  init?(file: StaticString, testName: String, name: String) {
    guard let output = ProcessInfo.processInfo.environment["LIL_SNAPSHOT_OUTPUT"] else {
      return nil
    }
    reference = referenceURL(file: file, testName: testName, name: name)
    let folder = reference.deletingLastPathComponent().lastPathComponent
    image = URL(filePath: output).appending(components: folder, reference.lastPathComponent)
    diff = image.deletingPathExtension().appendingPathExtension("diff.png")
    reportFile = URL(filePath: output).appending(component: "report.tsv")
    previousReference = modificationDate(of: reference)
    try? FileManager.default.createDirectory(
      at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: image)
    try? FileManager.default.removeItem(at: diff)
  }

  /// `strategy`, also writing each image it takes, encoded as SnapshotTesting encodes references.
  func writing<Value, Format>(_ strategy: Snapshotting<Value, Format>) -> Snapshotting<
    Value, Format
  > {
    let image = image
    return Snapshotting(pathExtension: strategy.pathExtension, diffing: strategy.diffing) {
      value in
      strategy.snapshot(value).map { snapshot in
        try? strategy.diffing.toData(snapshot).write(to: image)
        return snapshot
      }
    }
  }

  /// Called by SnapshotTesting when an image doesn't match its reference: writes the diff image,
  /// and says where the three are. It compares the image `writing(_:)` wrote, which has the same
  /// bytes as the failed image SnapshotTesting writes to its artifacts folder.
  var diffTool: SnapshotTestingConfiguration.DiffTool {
    let (image, diff, differed) = (image, diff, differed)
    return SnapshotTestingConfiguration.DiffTool { reference, _ in
      differed.set()
      let summary = writeDiff(
        reference: URL(filePath: reference), image: image, to: diff,
        tolerance: snapshotChannelTolerance)
      return """
        \(summary)
        reference: \(reference)
        image:     \(image.path)
        diff:      \(diff.path)
        """
    }
  }

  func report(failure: String?) {
    let recorded = modificationDate(of: reference) != previousReference
    let result =
      switch (failure != nil, differed.isSet, recorded) {
      case (false, _, _): "matches"
      case (true, true, true): "rerecorded"
      case (true, true, false): "differs"
      case (true, false, true): "recorded"
      case (true, false, false): "failed"
      }
    report(result: result)
  }

  /// Writes `value`'s image, taken with `strategy`, without comparing it, and reports it as `new`.
  fileprivate func renderNew<Value, Format>(
    _ value: Value, as strategy: Snapshotting<Value, Format>
  ) {
    writing(strategy).snapshot(value).run { _ in }
    report(result: "new")
  }

  private func report(result: String) {
    let fileManager = FileManager.default
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

/// Where SnapshotTesting keeps a PNG reference: `__Snapshots__/<test file>/<test>.<name>.png` next
/// to the test file, with its names made safe as SnapshotTesting does (`sanitizePathComponent`,
/// which isn't public).
func referenceURL(file: StaticString, testName: String, name: String) -> URL {
  func sanitized(_ component: String) -> String {
    component
      .replacingOccurrences(of: "\\W+", with: "-", options: .regularExpression)
      .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
  }
  let testFile = URL(filePath: "\(file)")
  return testFile.deletingLastPathComponent()
    .appending(
      components: "__Snapshots__", testFile.deletingPathExtension().lastPathComponent,
      "\(sanitized(testName)).\(sanitized(name)).png")
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

/// Writes `image`'s pixels that differ from `reference`'s by more than `tolerance` in a channel
/// in red, over a faded copy of `image`, and describes how much
/// changed and by how much. Through raw buffers: the tests build without optimization.
private func writeDiff(reference: URL, image: URL, to output: URL, tolerance: Int) -> String {
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
              if difference <= tolerance {
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
    let png = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)
  {
    CGImageDestinationAddImage(png, cgImage, nil)
    CGImageDestinationFinalize(png)
  }
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

private func pixels(of image: PlatformImage) -> Pixels? {
  #if os(macOS)
    image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(pixels(of:))
  #else
    image.cgImage.flatMap(pixels(of:))
  #endif
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

/// How far a pixel's channels may be from its reference's and still match, on CI and laptops, for
/// the Mac's images and the iPhone's alike: one rule (851-3242).
/// - The Mac's: both minis (M6) render every image byte for byte the same. Of the 834 images, an
///   M1 Pro laptop on the same macOS 27.0.1 drew 816 exactly as the minis do, 16 at most 1 apart,
///   and two (Sleep apnea notifications' lungs) 2 apart (851-3070), so references a laptop records
///   pass on CI. macOS 27.0 and 27.0.1 drew gradients, symbols and the toolbar's search field 1
///   apart (851-2985). CI compared within 1 until 851-3242, which kept laptops from recording.
/// - The iPhone's: the glass Settings button's rim comes out up to 2 apart in about one image in
///   ten, with nothing else changed (the window server's rounding), and a laptop's simulator drew
///   the rest of 160 images at most 2 apart from a mini's.
/// No one can see 2 levels. Anything that moves or recolors what's drawn is further apart.
let snapshotChannelTolerance = 2

extension Diffing where Value == PlatformImage {
  /// SnapshotTesting's exact comparison (`exact`), except that an image of the reference's size
  /// whose every pixel is within `tolerance` of the reference's, in each channel (alpha
  /// included), matches. One pixel further apart fails, with SnapshotTesting's message and
  /// attachments. The image is compared as it would be recorded, through its PNG, as
  /// SnapshotTesting compares it.
  static func image(
    channelTolerance tolerance: Int,
    exact: Diffing = .image(precision: 1, perceptualPrecision: 1)
  ) -> Diffing {
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
