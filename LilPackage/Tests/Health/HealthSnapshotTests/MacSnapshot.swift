#if os(macOS)
  import AppKit
  import CoreGraphics
  import CryptoKit
  import Foundation
  import SnapshotTesting
  import SwiftUI
  import Testing

  /// Renders `view` as a Mac window shows it, in a window with a title bar (so its toolbar
  /// renders) of the given appearance, and compares it with its reference image,
  /// `__Snapshots__/<test file>/<screen>.<name>-<light|dark>.png` (851-2931), the screen being a
  /// catalog's (851-2949), within `macChannelTolerance`. References are rendered on CI (851-3070).
  ///
  /// The window is never on screen and the app never activates, so this needs no Xcode, no
  /// Screen Recording access and no display of a particular scale, and runs beside other agents.
  /// Liquid Glass (toolbar controls, a switch's tint, the window buttons) doesn't draw offscreen.
  @MainActor
  func assertMacSnapshot(
    of view: some View, appearance: NSAppearance.Name, named name: String, screen: String,
    fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function,
    line: UInt = #line, column: UInt = #column
  ) {
    let window = snapshotWindow(of: view, appearance: appearance, title: name)
    let suffix = appearance == .darkAqua ? "dark" : "light"
    let output = SnapshotOutput(file: file, testName: screen, name: "\(name)-\(suffix)")
    // References come from CI (851-3070): off it, a new state is only shown.
    if isNewOffCI(file: file, testName: screen, name: "\(name)-\(suffix)") {
      renderNew(window.contentView!.superview!, as: .layerImage, to: output)
      window.close()
      return
    }
    // The window's frame view: its title bar and toolbar, and the content. `assertSnapshot` is
    // these two calls (for Swift Testing, which these tests use); `scripts/snapshot` needs the
    // result in between.
    let failure = withSnapshotTesting(diffTool: output?.diffTool) {
      verifySnapshot(
        of: window.contentView!.superview!, as: output?.writing(.layerImage) ?? .layerImage,
        named: "\(name)-\(suffix)", fileID: fileID, file: file, testName: screen, line: line,
        column: column)
    }
    output?.report(failure: failure)
    if screen == "sleep" || failure != nil {
      probeDumpTitleBar(
        window.contentView!.superview!, key: "\(screen).\(name)-\(suffix)", failed: failure != nil)
    }
    if let failure {
      Issue.record(
        Comment(rawValue: failure),
        sourceLocation: SourceLocation(
          fileID: "\(fileID)", filePath: "\(file)", line: Int(line), column: Int(column)))
    }
    window.close()
  }

  /// A window showing `view` as a snapshot draws it, laid out and settled: in a window with a
  /// title bar (so its toolbar renders) of the given appearance, at its fitting size, at 2x. Close
  /// it when done.
  @MainActor
  func snapshotWindow(
    of view: some View, appearance: NSAppearance.Name, title: String
  ) -> NSWindow {
    prepareSnapshotEnvironment()
    // The app's too, as Pixelbook sets it: Swift Charts' axis labels take the app's appearance,
    // so a dark snapshot taken after a light one could get light mode's labels.
    NSApplication.shared.appearance = NSAppearance(named: appearance)
    // Laid out at 2x from the start (851-2986). `NSWindow(contentViewController:)` has SwiftUI
    // lay the view out before it's in the window, at its default display scale of 1x, then again
    // at the window's 2x. Now and then a snapshot kept part of the 1x layout: Blood Pressure's
    // legend dot half a point up, where 1x rounds it (851-2987). With the scale fixed, each pass
    // rounds the same. (Putting the view into a window that's already 2x instead had AppKit lay
    // the window's toolbar out at the screen's scale: 1x on the minis, which drew it apart.)
    let controller = NSHostingController(
      rootView: view.environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.displayScale, snapshotScale))
    controller.sizingOptions = [.preferredContentSize]
    let window = SnapshotWindow(contentViewController: controller)
    window.isReleasedWhenClosed = false
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.title = title
    window.appearance = NSAppearance(named: appearance)
    window.setContentSize(controller.view.fittingSize)
    // Let SwiftUI lay out and draw, and charts settle.
    controller.view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    return window
  }

  /// What every snapshot shares, set once in the target's test process (SwiftPM runs each test
  /// target in its own): a time zone and locale, so times, dates and numbers read the same on
  /// every Mac (references are recorded in the team's, `fixTimeZoneAndLocale()`), and an app to own
  /// windows, which a test process doesn't have, as an accessory, so it never takes focus. And no
  /// wallpaper tinting (851-3172), which `fixTimeZoneAndLocale()` turns off with the locale.
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
    /// with `.image(channelTolerance: macChannelTolerance)`.
    @MainActor
    static var layerImage: Snapshotting {
      SimplySnapshotting(
        pathExtension: "png", diffing: .image(channelTolerance: macChannelTolerance)
      ).pullback { view in
        redrawAtSnapshotScale(view.layer!)
        let scale = snapshotScale
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

  /// The scale snapshots are laid out, drawn and rendered at, on any display.
  let snapshotScale: CGFloat = 2

  /// Draws again, at `snapshotScale`, every layer in `layer`'s tree that draws its own contents
  /// (SwiftUI's `CGDrawingLayer`s, text and shapes, and any with a `CABackingStore`), so the image
  /// never shows contents drawn at another scale (851-2986, 851-3010). `render(in:)` draws each
  /// layer's contents as they are, and now and then a SwiftUI layer was left with contents drawn
  /// at 1x, before the view was in its 2x window: blurred text, with a dark halo in dark mode.
  /// About one image in 500 on a laptop; on the minis, whose displays are 1x, one title a run,
  /// which depended on how many snapshots came before. Correct images come out byte for byte the
  /// same. Layers whose contents were set rather than drawn (images) are left alone: drawing them
  /// again would clear them.
  @MainActor
  private func redrawAtSnapshotScale(_ layer: CALayer) {
    if "\(type(of: layer))" == "CGDrawingLayer"
      || layer.contents.map({
        CFCopyTypeIDDescription(CFGetTypeID($0 as CFTypeRef)) as String? == "CABackingStore"
      }) == true
    {
      layer.contentsScale = snapshotScale
      layer.setNeedsDisplay()
      layer.displayIfNeeded()
    }
    for sublayer in layer.sublayers ?? [] {
      redrawAtSnapshotScale(sublayer)
    }
  }

  /// A window that draws as the key window, as a preview's canvas does, at 2x on any display, so
  /// a 1x one (the Mac minis') renders the same images as a laptop's.
  private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var backingScaleFactor: CGFloat { snapshotScale }
  }

  /// Appends the title bar's whole layer tree to `LIL_PROBE_DUMP`'s file (851-3230 probe).
  @MainActor
  func probeDumpTitleBar(_ frameView: NSView, key: String, failed: Bool) {
    guard let path = ProcessInfo.processInfo.environment["LIL_PROBE_DUMP"] else { return }
    let root = frameView.layer!
    var lines = ["=== \(key) failed: \(failed) screen: \(frameView.window?.screen?.backingScaleFactor ?? -1) at \(Date().timeIntervalSince1970)"]
    func walk(_ layer: CALayer, _ depth: Int, _ inTitleBar: Bool) {
      let frame = layer.convert(layer.bounds, to: root)
      let titleBar = inTitleBar || frame.minY >= root.bounds.height - 52 && frame.height <= 52
      if titleBar {
        var contents = "nil"
        if let c = layer.contents {
          let type = CFCopyTypeIDDescription(CFGetTypeID(c as CFTypeRef)) as String? ?? "?"
          if type == "CGImage" {
            let image = c as! CGImage
            var hash = ""
            if let data = image.dataProvider?.data as Data? {
              hash = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
            }
            contents = "CGImage \(image.width)x\(image.height) #\(hash)"
          } else {
            contents = type
          }
        }
        lines.append(
          "\(String(repeating: " ", count: depth))\(type(of: layer)) d=\(layer.delegate.map { String("\(type(of: $0))".prefix(40)) } ?? "-") f=\(frame) b=\(layer.bounds.size) c=\(contents) s=\(layer.contentsScale) g=\(layer.contentsGravity.rawValue) o=\(layer.opacity) h=\(layer.isHidden) t=\(CATransform3DIsIdentity(layer.transform) ? "id" : "\(layer.transform)") filters=\(layer.filters ?? []) cf=\(String(describing: layer.compositingFilter)) mask=\(layer.mask != nil) anims=\(layer.animationKeys() ?? [])"
        )
      }
      for sub in layer.sublayers ?? [] { walk(sub, depth + 1, titleBar) }
    }
    walk(root, 0, false)
    let text = lines.joined(separator: "\n") + "\n"
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(Data(text.utf8))
      try? handle.close()
    } else {
      FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    }
  }
#endif
