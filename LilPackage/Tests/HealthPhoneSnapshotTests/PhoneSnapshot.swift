#if os(iOS)
  import Foundation
  import SnapshotTesting
  import SwiftUI
  import Testing
  import UIKit

  /// Renders `view` full screen on an iPhone 18 Pro in the given style, as the app shows it, and
  /// compares it with its reference image, `__Snapshots__/<test file>/<screen>.<name>-<light|dark>.png`
  /// (851-2953).
  ///
  /// Drawn through the window server, in the host app's key window
  /// (`drawHierarchyInKeyWindow`), so Liquid Glass renders, which `layer.render(in:)` leaves out
  /// (swift-snapshot-testing issues #1029 and #1019). That needs the simulator to be an iPhone 18
  /// Pro, whose screen and safe area the image takes: `scripts/snapshot --iphone` makes one. The
  /// status bar is the system's, so it isn't drawn.
  @MainActor
  func assertPhoneSnapshot(
    of view: some View, style: UIUserInterfaceStyle, named name: String,
    screen: String = "iphone", fileID: StaticString = #fileID, file: StaticString = #filePath,
    line: UInt = #line, column: UInt = #column
  ) {
    let location = SourceLocation(
      fileID: "\(fileID)", filePath: "\(file)", line: Int(line), column: Int(column))
    guard let window = hostWindow() else {
      Issue.record(
        "No key window: run the iPhone's snapshot tests in their host app, with scripts/snapshot --iphone.",
        sourceLocation: location)
      return
    }
    guard window.screen.bounds.size == iPhone18ProSize else {
      Issue.record(
        """
        The simulator's screen is \(window.screen.bounds.size), not an iPhone 18 Pro's \
        (\(iPhone18ProSize)): run them with scripts/snapshot --iphone.
        """, sourceLocation: location)
      return
    }
    let suffix = style == .dark ? "dark" : "light"
    let image = draw(view, style: style, in: window)
    let output = SnapshotOutput(
      file: file, testName: screen, name: "\(name)-\(suffix)", tolerance: phoneChannelTolerance)
    let strategy = Snapshotting<UIImage, UIImage>(
      pathExtension: "png",
      diffing: .image(
        channelTolerance: phoneChannelTolerance,
        exact: .image(precision: 1, perceptualPrecision: 1, scale: 3)))
    let failure = withSnapshotTesting(diffTool: output?.diffTool) {
      verifySnapshot(
        of: image, as: output?.writing(strategy) ?? strategy, named: "\(name)-\(suffix)",
        fileID: fileID, file: file, testName: screen, line: line, column: column)
    }
    output?.report(failure: failure)
    if let failure {
      Issue.record(Comment(rawValue: failure), sourceLocation: location)
    }
  }

  /// Shows `view` full screen in the window, in the given style, waits for it to settle, and draws
  /// it through the window server (`drawHierarchy(in:afterScreenUpdates:)`, which is what
  /// SnapshotTesting's `drawHierarchyInKeyWindow` does). Drawn as soon as it was laid out, a glass
  /// button's rim came out slightly different in about one run in three: glass appears over a few
  /// frames.
  @MainActor
  private func draw(_ view: some View, style: UIUserInterfaceStyle, in window: UIWindow) -> UIImage
  {
    let controller = StillHostingController(
      rootView: view.environment(\.locale, Locale(identifier: "en_US")))
    controller.overrideUserInterfaceStyle = style
    let host = window.rootViewController
    window.rootViewController = controller
    defer { window.rootViewController = host }
    controller.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    controller.view.layoutIfNeeded()
    controller.removeAnimations()
    // 8-bit sRGB, as the Mac's: the simulator's default is 16-bit Display P3, whose images are
    // twice the size, and compare against a decoded reference with color differences of up to 11.
    let format = UIGraphicsImageRendererFormat()
    format.scale = 3
    format.preferredRange = .standard
    return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
      _ = controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
  }

  /// A hosting controller whose views don't move: it removes every animation after each layout,
  /// and before it's drawn, so a spinner or an indeterminate progress bar draws its resting state.
  /// Frozen mid-animation (`layer.speed = 0`), a spinner came out at a different step in each run.
  private final class StillHostingController<Content: View>: UIHostingController<Content> {
    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      removeAnimations()
    }

    func removeAnimations(_ layer: CALayer? = nil) {
      let layer = layer ?? view.layer
      layer.removeAllAnimations()
      for sublayer in layer.sublayers ?? [] {
        removeAnimations(sublayer)
      }
    }
  }

  /// The host app's window, once its scene is connected and the window key: the first test can
  /// start before that.
  @MainActor
  private func hostWindow() -> UIWindow? {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)
      if let window {
        return window
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    return nil
  }

  /// How far a pixel's channels may be from its reference's and still match on the iPhone: one
  /// more than the Mac's (`snapshotChannelTolerance`). The glass Settings button's rim comes out up
  /// to 2 apart in about one image in ten, with nothing else changed: the window server's rounding.
  /// Anything that moves or recolors what's drawn is further apart.
  let phoneChannelTolerance = 2

  /// An iPhone 17 Pro's and 18 Pro's screen, in points (at 3x).
  private let iPhone18ProSize = CGSize(width: 402, height: 874)

  extension StateCatalog {
    /// An iPhone screen's catalog: its states fill the screen, so they take no size (a state that
    /// gives one fails).
    init(phone screen: String, states: [CatalogState]) {
      self.init(
        screen, width: iPhone18ProSize.width, minHeight: iPhone18ProSize.height, states: states)
    }
  }

  extension CatalogState {
    /// Snapshots the state full screen in light and dark (`assertPhoneSnapshot`), against
    /// `__Snapshots__/<catalog file>/<screen>.<state>-<light|dark>.png` next to its catalog. A
    /// failure points at the state.
    @MainActor
    func assertPhoneSnapshots() {
      guard width == iPhone18ProSize.width, minHeight == iPhone18ProSize.height else {
        Issue.record(
          "An iPhone state fills the screen, so it takes no width or minimum height of its own.",
          sourceLocation: SourceLocation(
            fileID: "\(fileID)", filePath: "\(filePath)", line: Int(line), column: Int(column)))
        return
      }
      for style in [UIUserInterfaceStyle.light, .dark] {
        assertPhoneSnapshot(
          of: view(), style: style, named: slug, screen: screenSlug, fileID: fileID,
          file: filePath, line: line, column: column)
      }
    }
  }
#endif
