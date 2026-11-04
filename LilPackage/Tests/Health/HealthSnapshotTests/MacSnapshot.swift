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
  /// catalog's (851-2949), within `snapshotChannelTolerance`.
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
    // Off CI, a new state is only shown, unless recording (851-3242).
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
  /// it when done. `redrawsToolbarImages: false` leaves the toolbar's items as they were laid out
  /// (`layOutToolbarItemsAgain`), stale or not, for a test that reads no pixels.
  @MainActor
  func snapshotWindow(
    of view: some View, appearance: NSAppearance.Name, title: String,
    redrawsToolbarImages: Bool = true
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
    if redrawsToolbarImages { layOutToolbarItemsAgain(in: window) }
    return window
  }

  /// Has SwiftUI lay out and draw every toolbar item again, from scratch, so what the image shows
  /// never depends on an update it skipped (851-3230, 851-4046).
  ///
  /// SwiftUI draws a toolbar item first as its hosting view joins the window, before the toolbar
  /// sizes it: a symbol at 6.5 × 11.5 pt (13 × 23 px), placed around the unsized view's corner
  /// (Card Detail's › at -2, -6). It draws it again as the window first lays out, at its toolbar
  /// size and place (8.5 × 14.5 pt, 17 × 29 px, at 15, 10.5). On the minis, now and then and only
  /// after the catalogs before it, that second update left part of an item's layer as the first
  /// had it: the bitmap (Sleep › Week's ‹, stretched and soft, 851-3230), or the position (HRV,
  /// week's ›, 17 pt left and 16.5 pt up, 851-4046). The same pixels each time. Nothing fixes it
  /// by itself, not waiting or laying the window out again, since SwiftUI sets only what changed
  /// from what it last set, which it thinks is the final layout. Neither does going to the other
  /// appearance and back (851-3230's fix): that draws a stale bitmap again, but leaves a stale
  /// position where it is.
  ///
  /// So each item's hosting view is laid out at zero size, where SwiftUI places and draws it as
  /// it did first, then at its own frame again, where every layer gets its final geometry and
  /// bitmap, byte for byte as when nothing was skipped. Every item, every time, rather than the
  /// stale ones found: the result doesn't depend on finding them. Those found are printed, and an
  /// issue is recorded if any are left.
  @MainActor
  func layOutToolbarItemsAgain(in window: NSWindow) {
    let stale = staleToolbarImages(in: window)
    for view in toolbarItemHostingViews(in: window) {
      let frame = view.frame
      view.frame = .zero
      view.layout()
      view.frame = frame
      view.layout()
    }
    if !stale.isEmpty {
      print(
        "Drew stale toolbar images again in \(window.title): \(stale.map(\.description).joined(separator: ", "))"
      )
    }
    let left = staleToolbarImages(in: window)
    if !left.isEmpty {
      Issue.record(
        """
        \(window.title)'s toolbar images stayed stale after laying the toolbar's items out again: \
        \(left.map(\.description).joined(separator: ", ")). A bitmap image in a toolbar (not a \
        symbol), or one drawn outside its item, would need `staleToolbarImages` to leave it out.
        """)
    }
  }

  /// SwiftUI's hosting view for each item in the window's toolbar.
  @MainActor
  func toolbarItemHostingViews(in window: NSWindow) -> [NSView] {
    guard
      let titleBar = window.contentView?.superview?.subviews.first(where: {
        "\(type(of: $0))" == "NSTitlebarContainerView"
      })
    else { return [] }
    var views: [NSView] = []
    func visit(_ view: NSView) {
      if "\(type(of: view))".hasPrefix("ToolbarItemHostingView") {
        views.append(view)
      } else {
        view.subviews.forEach(visit)
      }
    }
    visit(titleBar)
    return views
  }

  /// The title bar's image layers left as SwiftUI first drew them, before the toolbar sized their
  /// items, described for an issue: a bitmap that isn't the layer's size at `snapshotScale`, a
  /// pixel or more apart (toolbar images are symbols, drawn to fit), or a layer that isn't inside
  /// its hosting view (a symbol placed around the unsized view's corner).
  @MainActor
  func staleToolbarImages(in window: NSWindow) -> [(layer: CALayer, description: String)] {
    titleBarImageLayers(in: window).compactMap { layer in
      guard let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
      else { return nil }
      let image = contents as! CGImage
      let expected = (
        width: layer.bounds.width * snapshotScale, height: layer.bounds.height * snapshotScale
      )
      let isRedrawn =
        abs(CGFloat(image.width) - expected.width) < 1
        && abs(CGFloat(image.height) - expected.height) < 1
      let isPlaced =
        toolbarItemLayer(of: layer).map { $0.bounds.contains(layer.convert(layer.bounds, to: $0)) }
        ?? true
      guard !isRedrawn || !isPlaced else { return nil }
      let origin = layer.convert(CGPoint.zero, to: window.contentView!.superview!.layer!)
      return (
        layer,
        "\(image.width) × \(image.height) px in \(layer.bounds.width) × \(layer.bounds.height) pt at \(origin.x), \(origin.y)"
          + (isPlaced ? "" : ", outside its item")
      )
    }
  }

  /// The layer of the toolbar item's hosting view (`toolbarItemHostingViews`) that `layer` is
  /// drawn in, if it's in one: not the window's buttons, whose images are larger than their views.
  @MainActor
  private func toolbarItemLayer(of layer: CALayer) -> CALayer? {
    var owner = layer.superlayer
    while let current = owner, !(current.delegate is NSView) { owner = current.superlayer }
    var view = owner?.delegate as? NSView
    while let current = view, !"\(type(of: current))".hasPrefix("ToolbarItemHostingView") {
      view = current.superview
    }
    return view?.layer
  }

  /// SwiftUI's image layers in the window's title bar (its toolbar's and its buttons'), and none
  /// of the content's, even under the title bar.
  @MainActor
  func titleBarImageLayers(in window: NSWindow) -> [CALayer] {
    guard
      let titleBar = window.contentView?.superview?.subviews.first(where: {
        "\(type(of: $0))" == "NSTitlebarContainerView"
      })?.layer
    else { return [] }
    var layers: [CALayer] = []
    func visit(_ layer: CALayer) {
      if "\(type(of: layer))" == "ImageLayer" { layers.append(layer) }
      layer.sublayers?.forEach(visit)
    }
    visit(titleBar)
    return layers
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
