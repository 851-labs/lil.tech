#if os(iOS)
  import Dependencies
  import LilUI
  import SwiftUI
  import Testing

  // The iPhone's side of the Mac's `DelayedProgressAccessibilityTests` (851-4047): loaded content
  // under `delayedProgress` reads as it does without it, and is hidden while the spinner finishes
  // its minimum time, read from the elements UIKit gives VoiceOver.

  extension PhoneSnapshotTests {
    @Test func delayedProgressKeepsContentsAccessibility() throws {
      let plain = try withAccessibility(of: DelayedProgressContent(), accessibilityLabels(under:))
      let loaded = try withAccessibility(
        of: DelayedProgressContent().delayedProgress(isLoading: false), accessibilityLabels(under:))
      #expect(plain.contains("Read"), "The content was read: \(plain)")
      #expect(loaded == plain)
    }

    @Test func delayedProgressHidesContentWhileSpinnerStays() throws {
      let loader = Loader()
      let labels = try withDependencies {
        // Shows at once, then stays a minute: longer than the test.
        $0.delayedProgressTiming = DelayedProgressTiming(delay: .zero, minimumVisible: .seconds(60))
        $0.continuousClock = ContinuousClock()
      } operation: {
        try withAccessibility(of: LoaderView(loader: loader), after: { loader.isLoading = false }) {
          accessibilityLabels(under: $0)
        }
      }
      #expect(!labels.contains("Loaded"), "\(labels)")
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
