#if os(macOS)
  import AppKit
  import HealthPages
  import SwiftUI
  import Testing

  // A page's loading state takes its loaded layout's space (851-3084): what's below its content
  // doesn't move while the content loads, or while another period's replaces it. Each catalog
  // names groups of its states that must agree (`StateCatalog.sameLayout`), e.g. loading, loaded
  // and loading the next period, and the page marks the views below its content with
  // `layoutAnchor` (Show All Data). This renders each state of a group as its snapshot does, and
  // checks every marked view is at the same frame in each. Layout only, no pixels: it can't be
  // flaky the way a comparison of images can, and passes on any Mac.

  /// The catalogs whose layouts are checked. Add a catalog here when it names `sameLayout` groups.
  private let layoutCheckedCatalogs = [sleepCatalog, metricDetailCatalog]

  extension MacSnapshotTests {
    @Test(arguments: layoutCheckedCatalogs.flatMap { $0.sameLayout })
    func loadingKeepsLayout(_ group: SameLayout) throws {
      let layouts = group.states.map { ($0, $0.anchorFrames()) }
      let (first, expected) = try #require(layouts.first)
      #expect(
        !expected.isEmpty,
        """
        \(first.name) marks no view with `layoutAnchor`, so there's nothing to compare: mark the \
        rows below its content.
        """, sourceLocation: first.sourceLocation)
      for (state, frames) in layouts.dropFirst() {
        #expect(
          frames.keys.sorted() == expected.keys.sorted(),
          "\(state.name) marks \(frames.keys.sorted()), and \(first.name) \(expected.keys.sorted()).",
          sourceLocation: state.sourceLocation)
        for (name, frame) in frames.sorted(by: { $0.key < $1.key }) {
          guard let other = expected[name] else { continue }
          #expect(
            frame == other,
            """
            \(name) moved: at \(frame) in \(state.name), \(other) in \(first.name) \
            (\(frame.minY - other.minY) pt down). A page's loading state takes its loaded \
            layout's space.
            """,
            sourceLocation: state.sourceLocation)
        }
      }
    }
  }

  extension CatalogState {
    /// Where the views it marks with `layoutAnchor` are, by name, laid out as its snapshot is.
    @MainActor
    func anchorFrames() -> [String: CGRect] {
      let frames = AnchorFrames()
      let window = snapshotWindow(
        of: view().frame(width: width).frame(minHeight: minHeight, alignment: .top)
          .environment(
            \.layoutAnchorRecorder,
            LayoutAnchorRecorder { name, frame in frames.byName[name] = frame }),
        appearance: .aqua, title: slug)
      window.close()
      return frames.byName
    }

    var sourceLocation: SourceLocation {
      SourceLocation(
        fileID: "\(fileID)", filePath: "\(filePath)", line: Int(line), column: Int(column))
    }
  }

  @MainActor
  private final class AnchorFrames {
    var byName: [String: CGRect] = [:]
  }
#endif
