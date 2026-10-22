#if os(macOS)
  import AppKit
  import CoreGraphics
  import Foundation
  import SnapshotTesting
  import SwiftUI
  import Testing

  /// Renders `view` as a Mac window shows it, in a window with a title bar (so its toolbar
  /// renders) of the given appearance, and compares it with its reference image,
  /// `__Snapshots__/<test file>/<screen>.<name>-<light|dark>.png` (851-2931), the screen being a
  /// catalog's (851-2949). Only renders it on CI (`snapshotsRenderOnly`, 851-3071).
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
    window.title = name
    window.appearance = NSAppearance(named: appearance)
    window.setContentSize(controller.view.fittingSize)
    // Let SwiftUI lay out and draw, and charts settle.
    controller.view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let suffix = appearance == .darkAqua ? "dark" : "light"
    let output = SnapshotOutput(file: file, testName: screen, name: "\(name)-\(suffix)")
    if snapshotsRenderOnly {
      if let output {
        output.render(window.contentView!.superview!, as: .layerImage)
      } else {
        Snapshotting.layerImage.snapshot(window.contentView!.superview!).run { _ in }
      }
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
    if let failure {
      Issue.record(
        Comment(rawValue: failure),
        sourceLocation: SourceLocation(
          fileID: "\(fileID)", filePath: "\(file)", line: Int(line), column: Int(column)))
    }
    window.close()
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
#endif
