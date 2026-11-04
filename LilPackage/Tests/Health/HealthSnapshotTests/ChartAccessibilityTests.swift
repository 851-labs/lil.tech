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
    /// nothing: each page's chart with data (its label, points and Audio Graph) and without.
    @Test(arguments: [
      (cardDetailCatalog, "Steps, week", "Steps, Aug 11 – 17, 2024", 3, true),
      (cardDetailCatalog, "Steps, no data", "No data for Aug 11 – 17, 2024", 0, false),
      (metricDetailCatalog, "Steps, week", "Steps, Aug 11 – 17, 2024", 3, true),
      (metricDetailCatalog, "Steps, no data", "No data for Aug 11 – 17, 2024", 0, false),
      (sleepCatalog, "Week", "Sleep, Aug 7 – 13, 2024", 114, false),
      (sleepCatalog, "Month without sleep", "No data for Nov 14 – Dec 13, 2023", 0, false),
      (symptomsCatalog, "Headache, week", "Headache, Aug 4 – 10, 2024", 4, true),
      (symptomsCatalog, "Headache, not present", "Not present in Aug 4 – 10, 2024", 0, false),
      (bloodPressureCatalog, "Blood pressure, week", "Blood Pressure, Aug 11 – 17, 2024", 1, false),
      (bloodPressureCatalog, "No blood pressure", "No data for Aug 11 – 17, 2024", 0, false),
    ])
    func chartAccessibilityReads(
      _ catalog: StateCatalog, state name: String, label: String, points: Int,
      hasChartDescriptor: Bool
    ) throws {
      let state = try #require(catalog.states.first { $0.name == name })
      let tree = state.accessibilityTree()
      let charts = tree.filter { $0.isChart || $0.saysNoData }
      #expect(charts.map(\.spoken) == [label], sourceLocation: state.sourceLocation)
      #expect(charts.map(\.children.count) == [points], sourceLocation: state.sourceLocation)
      // Swift Charts' description, which VoiceOver's Audio Graph plays, stays on the chart (Sleep's
      // and Blood Pressure's charts never had one).
      #expect(
        charts.map(\.hasChartDescriptor) == [hasChartDescriptor],
        sourceLocation: state.sourceLocation)
    }
  }
#endif
