#if os(macOS)
  import AppKit
  import ObjectiveC
  import ComposableArchitecture
  import Foundation
  import HealthAgentAccess
  import HealthCatalog
  import HealthDatabase
  @testable import HealthMacApp
  @testable import HealthPages
  import SnapshotTesting
  import SwiftUI
  import Testing

  // Preview states of lil health for Mac, rendered by swift-snapshot-testing (851-2931). Each
  // builds the same view as the `#Preview` it names. Synthetic data only.

  @MainActor
  @Suite(.snapshots(record: .missing))
  struct MacSnapshotTests {
    /// The previews' synthetic database, prepared once per process, as a preview context does.
    static let database: Void = preparePreviewDatabase()

    // MetricDetailViewPreviews.swift, "Environmental sound levels, week": a chart from fixed dates.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func soundLevelsChart(appearance: NSAppearance.Name) {
      _ = Self.database
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_400_000))
      let days = (0..<7).map { calendar.date(byAdding: .day, value: $0 - 6, to: today)! }
      let ranges: [(Double, Double)] = [
        (42, 71), (45, 86), (40, 68), (38, 74), (44, 91), (41, 66), (39, 70),
      ]
      let points = zip(days, ranges).map { day, range in
        ChartPoint(start: day, value: (range.0 + range.1) / 2, minimum: range.0, maximum: range.1)
      }
      let chart = MetricChart(
        interval: DateInterval(
          start: days[0], end: calendar.date(byAdding: .day, value: 1, to: today)!),
        points: points, summary: .range(minimum: 38, maximum: 91))
      let view = NavigationStack {
        MetricDetailContent(
          type: HealthCatalog.type(id: "HKQuantityTypeIdentifierEnvironmentalAudioExposure")!,
          range: .constant(.week), offset: .constant(0), state: .loaded(chart))
      }
      .previewFrame(width: 760, height: 720)
      snapshot(view, appearance: appearance, named: "sound-levels-week")
    }

    // HealthNotificationsViewPreviews.swift, "High heart rate notifications": a `List`.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func notificationsList(appearance: NSAppearance.Name) {
      let base = Date(timeIntervalSince1970: 1_760_400_000)
      func notification(daysAgo: Double, hour: Double = 14, threshold: Int) -> HealthNotification {
        let start = base.addingTimeInterval(-daysAgo * 86_400 + hour * 3600)
        return HealthNotification(
          HealthSample(
            id: "notification-\(daysAgo)", type: HealthNotificationKind.highHeartRate.rawValue,
            startDate: start.unixMilliseconds,
            endDate: start.addingTimeInterval(600).unixMilliseconds, categoryValue: 0,
            sourceName: "Apple Watch", sourceBundleID: "com.apple.health.preview",
            device: #"{"name":"Apple Watch","manufacturer":"Apple Inc."}"#,
            metadata: #"{"HKHeartRateEventThreshold":"\#(threshold) count/min"}"#))
      }
      let view = NavigationStack {
        HealthNotificationsContent(
          kind: .highHeartRate,
          state: .loaded([
            notification(daysAgo: 0, threshold: 120),
            notification(daysAgo: 9, hour: 22, threshold: 120),
            notification(daysAgo: 23, hour: 9, threshold: 130),
            notification(daysAgo: 61, hour: 16, threshold: 120),
          ]))
      }
      .previewFrame(width: 620, height: 520)
      snapshot(view, appearance: appearance, named: "high-heart-rate-notifications")
    }

    // SettingsViewPreviews.swift, "Agents: on, with a log": Settings › Agents, a grouped `Form`.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func agentsPane(appearance: NSAppearance.Name) {
      let entries = [
        AgentAccessEntry(
          id: 5, date: Date(timeIntervalSince1970: 1_760_973_000), command: "open Steps",
          process: "Shortcuts, Siri or Spotlight"),
        AgentAccessEntry(
          id: 4, date: Date(timeIntervalSince1970: 1_760_972_520),
          command: "metric Steps --range W", process: "claude"),
        AgentAccessEntry(
          id: 3, date: Date(timeIntervalSince1970: 1_760_972_460), command: "summary",
          process: "claude"),
        AgentAccessEntry(
          id: 2, date: Date(timeIntervalSince1970: 1_760_965_200),
          command: "samples HeartRate --from 2025-10-13 --to 2025-10-20", process: "Codex"),
        AgentAccessEntry(
          id: 1, date: Date(timeIntervalSince1970: 1_760_961_600), command: "sleep --json",
          process: "zsh"),
      ]
      var state = AppFeature.State(isSignedIn: true)
      state.agentAccess = AgentAccessFeature.State(
        commandLineTool: URL(filePath: "/usr/local/bin/lil"), entries: entries, failure: nil,
        isEnabled: true, isLoading: false, logFailure: nil)
      let view = AgentAccessSettingsView(store: Store(initialState: state) { EmptyReducer() })
        .previewFrame(width: SettingsView.width, height: SettingsView.height)
      snapshot(view, appearance: appearance, named: "agents-on-with-a-log")
    }
  }

  /// Renders `view` in an offscreen window of the given appearance, as a preview's canvas would,
  /// and compares it with its reference image. Prints how long it took.
  ///
  /// The window has a title bar, so toolbars render, and the snapshot is of the whole window
  /// (its frame view), as Xcode's canvas shows a Mac preview.
  @MainActor
  func snapshot(
    _ view: some View, appearance: NSAppearance.Name, named name: String,
    fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function,
    line: UInt = #line, column: UInt = #column
  ) {
    let clock = ContinuousClock()
    let start = clock.now
    prepareApp()
    // The app's too, as Pixelbook sets it: Swift Charts' axis labels resolve their color with the
    // app's appearance, so a dark snapshot after a light one could get light mode's labels.
    NSApplication.shared.appearance = NSAppearance(named: appearance)
    let controller = NSHostingController(
      rootView: view.environment(\.controlActiveState, .key))
    controller.sizingOptions = [.preferredContentSize]
    let window = KeyWindow(contentViewController: controller)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.title = name
    window.appearance = NSAppearance(named: appearance)
    window.setContentSize(controller.view.fittingSize)
    window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
    // Let SwiftUI lay out and draw once, and `onAppear` and charts settle.
    controller.view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let frameView = window.contentView!.superview!
    let suffix = appearance == .darkAqua ? "dark" : "light"
    let strategy: Snapshotting<NSView, NSImage> =
      ProcessInfo.processInfo.environment["SNAPSHOT_STRATEGY"] == "cacheDisplay"
      ? .image : .layerImage
    assertSnapshot(
      of: frameView, as: strategy, named: "\(name)-\(suffix)", fileID: fileID, file: file,
      testName: "mac", line: line, column: column)
    window.contentViewController = nil
    print("snapshot \(name)-\(suffix): \(clock.now - start) at \(frameView.bounds.size)")
  }

  /// An app to draw in: a test process has none, so windows would draw as an inactive app's
  /// (gray switches and window buttons). It says it's active, without activating, so it never takes
  /// focus from the apps on the Mac's screen.
  @MainActor
  private func prepareApp() {
    _ = appIsActive
  }

  @MainActor
  private let appIsActive: Void = {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let original = class_getInstanceMethod(
      NSApplication.self, #selector(getter: NSApplication.isActive))!
    let block: @convention(block) (NSApplication) -> Bool = { _ in true }
    method_setImplementation(original, imp_implementationWithBlock(block))
  }()

  extension Snapshotting where Value == NSView, Format == NSImage {
    /// The view's layer tree drawn with `CALayer.render(in:)` at 2x, in sRGB. Unlike `.image`
    /// (`cacheDisplay(in:to:)`), it keeps Swift Charts' colors as the screen shows them.
    @MainActor
    static var layerImage: Snapshotting {
      SimplySnapshotting.image(precision: 1, perceptualPrecision: 1).pullback { view in
        let layer = view.layer!
        let scale: CGFloat = 2
        let size = view.bounds.size
        let context = CGContext(
          data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        (view.window?.effectiveAppearance ?? view.effectiveAppearance)
          .performAsCurrentDrawingAppearance {
            layer.render(in: context)
          }
        return NSImage(cgImage: context.makeImage()!, size: size)
      }
    }
  }

  /// A window that draws as the key window, as a preview's canvas does: controls in a window that
  /// isn't key draw inactive (a switch that's on shows gray, not the accent color).
  private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
  }
#endif
