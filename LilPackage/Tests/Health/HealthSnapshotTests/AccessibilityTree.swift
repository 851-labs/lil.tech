#if os(macOS)
  import Accessibility
  import AppKit
  import SwiftUI

  /// An element of the accessibility tree, as VoiceOver gets it from AppKit.
  final class AccessibilityNode: CustomStringConvertible {
    let role: String
    let label: String
    /// A text's words, which are its value. Only a text's: some of SwiftUI's elements raise an
    /// exception when asked for theirs.
    let value: String
    /// In screen coordinates.
    let frame: CGRect
    let children: [AccessibilityNode]
    /// Whether it describes a chart for Audio Graphs (`AXChart`), as Swift Charts' charts do.
    let hasChartDescriptor: Bool

    init(_ element: Any) {
      // SwiftUI's elements are of a private class that `as? NSAccessibilityProtocol` doesn't
      // find, so the protocol's methods are called by name.
      let object = element as AnyObject
      role = object.accessibilityRole?()?.rawValue ?? ""
      label = object.accessibilityLabel?() ?? ""
      value =
        role == NSAccessibility.Role.staticText.rawValue
        ? object.value(forKey: "accessibilityValue") as? String ?? "" : ""
      frame = object.accessibilityFrame?() ?? .zero
      hasChartDescriptor = (element as? any AXChart)?.accessibilityChartDescriptor != nil
      children = ((object.accessibilityChildren?()).flatMap { $0 } ?? []).map(
        AccessibilityNode.init)
    }

    /// The element and every element under it, depth first.
    var all: [AccessibilityNode] { [self] + children.flatMap(\.all) }

    /// What an empty chart says (`PeriodFormat.noData`, `ChartFormat.notPresent`).
    var saysNoData: Bool { label.hasPrefix("No data for ") || label.hasPrefix("Not present in ") }

    /// A chart with points: a group whose children are all Swift Charts' points, which name
    /// their span with "to" ("Aug 11, 2024 at 12 AM to Aug 12, 2024 at 12 AM").
    var isChart: Bool {
      role == NSAccessibility.Role.group.rawValue && !children.isEmpty
        && children.allSatisfy {
          $0.role == NSAccessibility.Role.unknown.rawValue && $0.label.contains(" to ")
        }
    }

    /// Its label with plain spaces, for comparing: a period's dates have thin ones around their
    /// dash ("Aug 11 – 17").
    var spoken: String { label.replacingOccurrences(of: "\u{2009}", with: " ") }

    var description: String {
      value.isEmpty ? "\(role) \"\(label)\"" : "\(role) \"\(label)\" \"\(value)\""
    }
  }

  extension CatalogState {
    /// Every element of its accessibility tree, laid out as its snapshot is.
    @MainActor
    func accessibilityTree() -> [AccessibilityNode] {
      withLocale {
        HealthSnapshotTests.accessibilityTree(
          of: view().frame(width: width).frame(minHeight: minHeight, alignment: .top), title: slug)
      }
    }
  }

  /// Every element of a view's accessibility tree, in a window as a snapshot's, read after
  /// `change` (if any) has had the window lay out again.
  @MainActor
  func accessibilityTree(
    of view: some View, title: String, after change: (() -> Void)? = nil
  ) -> [AccessibilityNode] {
    // SwiftUI builds its elements only for an assistive app, which says so by setting
    // `AXEnhancedUserInterface` on the app, as VoiceOver does: set before the window lays out.
    // By selector, as an assistive app's request reaches it: the method is deprecated.
    func setEnhancedUserInterface(_ isOn: Bool) {
      _ = NSApplication.shared.perform(
        NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: isOn as NSNumber,
        with: "AXEnhancedUserInterface")
    }
    setEnhancedUserInterface(true)
    defer { setEnhancedUserInterface(false) }
    let window = snapshotWindow(
      of: view, appearance: .aqua, title: title, redrawsToolbarImages: false)
    defer { window.close() }
    guard let content = window.contentView else { return [] }
    if let change {
      change()
      content.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    // The first time, SwiftUI makes them a moment after it's asked for them.
    let deadline = Date().addingTimeInterval(2)
    var tree = AccessibilityNode(content).all
    while tree.count <= 1, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      tree = AccessibilityNode(content).all
    }
    return tree
  }
#endif
