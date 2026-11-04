#if os(iOS)
  import SwiftUI
  import Testing

  // The iPhone's side of the Mac's `ChartAccessibilityTests` (851-4042): a card's chart, in
  // `chartAccessibility`, is a container named for what it charts and when, holding its points,
  // and an empty one is one element, "No data for …". Read from the accessibility elements UIKit
  // gives VoiceOver, with the page in the host app's window.

  extension PhoneSnapshotTests {
    @Test func chartAccessibility() throws {
      #expect(try chartLabels("Steps, week") == ["Steps, Aug 11 – 17, 2024": 3])
      #expect(try chartLabels("Steps, no data") == ["No data for Aug 11 – 17, 2024": 0])
    }

    /// What VoiceOver reads of a Card Detail state's chart: the chart's label, or an empty
    /// period's, with its children (the points).
    private func chartLabels(_ name: String) throws -> [String: Int] {
      let state = try #require(cardDetailCatalog.states.first { $0.name == name })
      // As `draw` shows it, in the suite's locale: these states have none of their own.
      return try withAccessibility(
        of: state.view().environment(\.locale, Locale(identifier: "en_US"))
      ) { root in
        var labels: [String: Int] = [:]
        @MainActor func visit(_ object: NSObject) {
          let children = accessibilityChildren(of: object)
          let label = (object.accessibilityLabel ?? "").replacingOccurrences(
            of: "\u{2009}", with: " ")
          let isChart =
            !children.isEmpty
            && children.allSatisfy { ($0.accessibilityLabel ?? "").contains(" to ") }
          if isChart || label.hasPrefix("No data for ") || label.hasPrefix("Not present in ") {
            labels[label, default: 0] += children.count
          }
          children.forEach(visit)
        }
        visit(root)
        return labels
      }
    }
  }
#endif
