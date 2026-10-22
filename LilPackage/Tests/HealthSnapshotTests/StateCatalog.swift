import Foundation
import SwiftUI
import Testing

// State catalogs (851-2949): a screen's UI states, where `#Preview`s were. Each state builds its
// view from fixed synthetic data and the catalogs' fixed date (`previewNow`, 851-2950), and one
// test per catalog snapshots every state in light and dark. The types are free of AppKit, so the
// iPhone's and lil messages' tests can use them too.

/// A screen and its named states. States take the catalog's size unless they give their own.
struct StateCatalog: Sendable {
  /// The screen's name, e.g. "Metric Detail". Its slug starts its references' names.
  let screen: String
  let states: [CatalogState]

  init(_ screen: String, width: CGFloat, minHeight: CGFloat, states: [CatalogState]) {
    self.screen = screen
    self.states = states.map { state in
      var state = state
      state.screen = screen
      state.width = state.width ?? width
      state.minHeight = state.minHeight ?? minHeight
      return state
    }
    let slugs = self.states.map(\.slug)
    // When tests are listed, before any runs, so it can't be an issue.
    for slug in slugs where slugs.count(where: { $0 == slug }) > 1 {
      fatalError("\(screen) has two states named \(slug): their references would be the same.")
    }
  }

  /// The states its test snapshots: all of them, or those whose names match `LIL_SNAPSHOT_STATE`,
  /// a case-insensitive regular expression, e.g.
  /// `LIL_SNAPSHOT_STATE=loading scripts/snapshot metricDetail`.
  var selectedStates: [CatalogState] {
    guard let pattern = ProcessInfo.processInfo.environment["LIL_SNAPSHOT_STATE"] else {
      return states
    }
    guard let regex = try? Regex(pattern).ignoresCase() else {
      fatalError("LIL_SNAPSHOT_STATE isn't a regular expression: \(pattern)")
    }
    return states.filter { $0.name.contains(regex) }
  }
}

/// A state of a screen: its name, the view, and where it's written, for failures and Pixelbook's
/// source links.
struct CatalogState: Sendable, Identifiable, CustomTestStringConvertible {
  /// Stable: its slug names its references, `<screen>.<state>-<light|dark>.png`.
  let name: String
  /// The view's width, and its minimum height: it's top-aligned, and grows to its content.
  /// Its catalog's, unless it gives its own.
  fileprivate(set) var width: CGFloat?
  fileprivate(set) var minHeight: CGFloat?
  /// Its catalog's screen.
  fileprivate(set) var screen = ""
  let view: @MainActor () -> AnyView
  let fileID: StaticString
  let filePath: StaticString
  let line: UInt
  let column: UInt

  init(
    _ name: String, width: CGFloat? = nil, minHeight: CGFloat? = nil,
    fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line,
    column: UInt = #column, @ViewBuilder view: @escaping @MainActor () -> some View
  ) {
    self.name = name
    self.width = width
    self.minHeight = minHeight
    self.view = { @MainActor in AnyView(view()) }
    self.fileID = fileID
    self.filePath = filePath
    self.line = line
    self.column = column
  }

  /// "Steps, 6 months" is `steps-6-months`.
  var slug: String { Self.slug(name) }
  var screenSlug: String { Self.slug(screen) }
  var id: String { slug }
  var testDescription: String { name }

  private static func slug(_ name: String) -> String {
    name.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }
}

#if os(macOS)
  import AppKit

  extension CatalogState {
    /// Snapshots the state in light and dark (`assertMacSnapshot`), at its width and at least its
    /// height, against `__Snapshots__/<catalog file>/<screen>.<state>-<light|dark>.png` next to
    /// its catalog. A failure points at the state.
    @MainActor
    func assertMacSnapshots() {
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        assertMacSnapshot(
          of: view().frame(width: width).frame(minHeight: minHeight, alignment: .top),
          appearance: appearance, named: slug, screen: screenSlug, fileID: fileID, file: filePath,
          line: line, column: column)
      }
    }
  }
#endif
