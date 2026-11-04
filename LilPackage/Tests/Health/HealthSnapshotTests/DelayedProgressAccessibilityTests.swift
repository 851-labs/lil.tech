#if os(macOS)
  import AppKit
  import Dependencies
  import LilUI
  import SwiftUI
  import Testing

  // What VoiceOver finds under `delayedProgress` (851-4047). It once put
  // `.accessibilityHidden(false)` on its content once loaded, and on the Mac an ancestor's `false`
  // shows what its descendants hid: every `ContentUnavailableView`'s symbol ("Warning" on a
  // failed page), images hidden as decorative, and a nested spinner's hidden placeholder, read as
  // an unnamed element. Now it hides its content only by its opacity, while the spinner finishes
  // its minimum time, which SwiftUI's accessibility already follows.

  extension MacSnapshotTests {
    /// Loaded, the content reads as it does without `delayedProgress`, what it hid included.
    @Test func delayedProgressKeepsContentsAccessibility() {
      let plain = accessibilityTree(of: DelayedProgressContent(), title: "plain")
      let loaded = accessibilityTree(
        of: DelayedProgressContent().delayedProgress(isLoading: false), title: "loaded")
      #expect(plain.contains { $0.value == "Read" }, "The content was read: \(plain)")
      #expect(loaded.map(\.description) == plain.map(\.description))
    }

    /// Loaded while the spinner is in its minimum time, the content is hidden, from VoiceOver too,
    /// until the spinner goes (851-3086).
    @Test func delayedProgressHidesContentWhileSpinnerStays() {
      let loader = Loader()
      let tree = withDependencies {
        // Shows at once, then stays a minute: longer than the test.
        $0.delayedProgressTiming = DelayedProgressTiming(delay: .zero, minimumVisible: .seconds(60))
        $0.continuousClock = ContinuousClock()
      } operation: {
        accessibilityTree(of: LoaderView(loader: loader), title: "holding") {
          loader.isLoading = false
        }
      }
      #expect(tree.map(\.role) == ["AXGroup", "AXBusyIndicator"], "\(tree)")
    }

    /// Pages whose views hide elements from VoiceOver inside `delayedProgress`: each state reads
    /// what it shows (`reads`), and not what it hid (`hidden`).
    @Test(
      arguments: [
        // Empty pages' and failed pages' `ContentUnavailableView` symbols.
        (
          notificationsCatalog, "No high heart rate notifications", #"AXImage "Love""#,
          "No High Heart Rate Notifications"
        ),
        (medicationsCatalog, "No medications", #"AXImage "Two Pills""#, "No Medications"),
        (
          medicationsCatalog, "Medications failed", #"AXImage "Warning""#,
          "Couldn't Load Medications"
        ),
        (electrocardiogramsCatalog, "No ECGs", #"AXImage "Ecg Waveform Path""#, "No ECGs"),
        (sleepCatalog, "Never recorded", #"AXImage "Bedtime""#, "No Sleep Data"),
        (metricDetailCatalog, "Failed", #"AXImage "Warning""#, "Couldn't Load Steps"),
        (settingsCatalog, "Signed out", #"AXImage "Account""#, "Not Signed In"),
        // Loading pages, whose placeholders hide what they lay out, and a loaded page with a
        // spinner of its own inside (a workout's map).
        (notificationsCatalog, "Notifications loading", #"AXUnknown """#, nil),
        (electrocardiogramsCatalog, "ECGs loading", #"AXUnknown """#, nil),
        (sleepCatalog, "Loading", #"AXUnknown """#, "TIME IN BED"),
        (cardDetailCatalog, "Steps, loading", #"AXUnknown """#, "Total steps."),
        (workoutsCatalog, "Run with route", #"AXUnknown """#, "Workout Time"),
      ] as [(StateCatalog, String, String, String?)])
    func delayedProgressKeepsHiddenViewsHidden(
      _ catalog: StateCatalog, state name: String, hidden: String, reads: String?
    ) throws {
      let state = try #require(catalog.states.first { $0.name == name })
      let tree = state.accessibilityTree()
      if let reads {
        #expect(
          tree.contains { $0.value == reads }, "\"\(reads)\" isn't read: \(tree)",
          sourceLocation: state.sourceLocation)
      } else {
        #expect(
          tree.contains { $0.role == NSAccessibility.Role.busyIndicator.rawValue },
          "No spinner is read: \(tree)", sourceLocation: state.sourceLocation)
      }
      #expect(
        !tree.contains { $0.description == hidden }, "\(hidden) is read: \(tree)",
        sourceLocation: state.sourceLocation)
    }
  }

  /// Content that hides some of itself from VoiceOver, as pages do: a decorative image, a
  /// placeholder's text, a `ContentUnavailableView` (which hides its symbol) and a spinner of its
  /// own (whose hidden twin keeps its space).
  private struct DelayedProgressContent: View {
    var body: some View {
      VStack {
        Text("Read")
        Text("Hidden").accessibilityHidden(true)
        Image(systemName: "star").accessibilityHidden(true)
        ContentUnavailableView("Nothing Here", systemImage: "tray")
        Color.clear.frame(height: 20).delayedProgress(isLoading: false)
      }
      .frame(width: 300)
    }
  }

  @MainActor
  @Observable
  private final class Loader {
    var isLoading = true
  }

  private struct LoaderView: View {
    let loader: Loader

    var body: some View {
      Text("Loaded")
        .frame(width: 300, height: 100)
        .delayedProgress(isLoading: loader.isLoading)
    }
  }
#endif
