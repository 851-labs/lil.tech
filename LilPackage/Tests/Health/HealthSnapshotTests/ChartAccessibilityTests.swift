#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  // What VoiceOver finds in a period's chart (`chartAccessibility`, 851-4042): a chart with points
  // is a group named for what it charts and when, holding the points, and an empty one is one
  // element, "No data for …" (or a symptom's "Not present in …"). The empty element was once a
  // clear overlay hidden while the chart had points, which an ancestor's
  // `.accessibilityHidden(false)` (`delayedProgress`'s) showed again, so a chart with points also
  // said "No data". This renders each state of the catalogs whose charts use it, as its snapshot
  // does, and reads the accessibility tree AppKit gives VoiceOver.

  /// The catalogs whose pages chart a period with `chartAccessibility`.
  private let chartCatalogs = [
    cardDetailCatalog, cardEditorCatalog, metricDetailCatalog, sleepCatalog, symptomsCatalog,
    bloodPressureCatalog,
  ]

  extension MacSnapshotTests {
    @Test(arguments: chartCatalogs.flatMap { $0.states })
    func chartAccessibility(_ state: CatalogState) {
      let tree = state.accessibilityTree()
      #expect(
        tree.count > 1, "SwiftUI gave the window no elements to read.",
        sourceLocation: state.sourceLocation)
      for empty in tree.filter(\.saysNoData) {
        #expect(
          empty.children.isEmpty,
          "\"\(empty.label)\" holds \(empty.children.map(\.description)): an empty chart has nothing to read.",
          sourceLocation: state.sourceLocation)
        // The chart it stands for, or an element over it: what the old overlay sat over.
        let sharing = tree.filter { $0 !== empty && $0.frame == empty.frame }
        #expect(
          sharing.isEmpty,
          "\"\(empty.label)\" shares its frame with \(sharing.map(\.description)), so VoiceOver reads both.",
          sourceLocation: state.sourceLocation)
      }
    }

    /// Some of the states above as VoiceOver reads them, so the checks can't pass by reading
    /// nothing.
    @Test func chartAccessibilityReadsCharts() throws {
      func labels(_ catalog: StateCatalog, _ name: String) throws -> [String: Int] {
        let tree = try #require(catalog.states.first { $0.name == name }).accessibilityTree()
        // What's read, by label, with the elements' children: a chart's points.
        return Dictionary(
          tree.filter { $0.isChart || $0.saysNoData }.map { ($0.spoken, $0.children.count) },
          uniquingKeysWith: +)
      }
      // A card's page with three days of steps, and the same week with none.
      #expect(try labels(cardDetailCatalog, "Steps, week") == ["Steps, Aug 11 – 17, 2024": 3])
      #expect(
        try labels(cardDetailCatalog, "Steps, no data") == ["No data for Aug 11 – 17, 2024": 0])
      // Metric Detail's chart, its own.
      #expect(try labels(metricDetailCatalog, "Steps, week") == ["Steps, Aug 11 – 17, 2024": 3])
      #expect(
        try labels(metricDetailCatalog, "Steps, no data") == ["No data for Aug 11 – 17, 2024": 0])
    }
  }

  /// An element of the accessibility tree, as VoiceOver gets it from AppKit.
  final class AccessibilityNode: CustomStringConvertible {
    let role: String
    let label: String
    /// In screen coordinates.
    let frame: CGRect
    let children: [AccessibilityNode]

    init(_ element: Any) {
      // SwiftUI's elements are of a private class that `as? NSAccessibilityProtocol` doesn't
      // find, so the protocol's methods are called by name.
      let object = element as AnyObject
      role = object.accessibilityRole?()?.rawValue ?? ""
      label = object.accessibilityLabel?() ?? ""
      frame = object.accessibilityFrame?() ?? .zero
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

    var description: String { "\(role) \"\(label)\"" }
  }

  extension CatalogState {
    /// Every element of its accessibility tree, laid out as its snapshot is.
    @MainActor
    func accessibilityTree() -> [AccessibilityNode] {
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
      return withLocale {
        let window = snapshotWindow(
          of: view().frame(width: width).frame(minHeight: minHeight, alignment: .top),
          appearance: .aqua, title: slug, redrawsToolbarImages: false)
        defer { window.close() }
        guard let content = window.contentView else { return [] }
        // The first time, SwiftUI makes them a moment after it's asked for them.
        let deadline = Date().addingTimeInterval(2)
        var tree = AccessibilityNode(content).all
        while tree.count <= 1, Date() < deadline {
          RunLoop.main.run(until: Date().addingTimeInterval(0.02))
          tree = AccessibilityNode(content).all
        }
        return tree
      }
    }
  }
#endif
