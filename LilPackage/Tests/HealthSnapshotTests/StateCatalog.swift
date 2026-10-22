import Foundation
import SwiftUI
import Synchronization
import Testing

// State catalogs (851-2949): a screen's UI states, in place of SwiftUI previews. Each state
// builds its view from fixed synthetic data and the catalogs' fixed date (`previewNow`,
// 851-2950), and one test per catalog snapshots every state in light and dark. The types are free
// of AppKit, so the iPhone's and lil messages' tests can use them too.

/// A screen and its named states. States take the catalog's size unless they give their own.
struct StateCatalog: Sendable {
  /// The screen's name, e.g. "Metric Detail". Its slug starts its references' names.
  let screen: String
  let states: [CatalogState]

  init(_ screen: String, width: CGFloat, minHeight: CGFloat, states: [CatalogState]) {
    self.screen = screen
    let states = states.map { state in
      var state = state
      state.screen = screen
      state.width = state.width ?? width
      state.minHeight = state.minHeight ?? minHeight
      return state
    }
    let slugs = states.map(\.slug)
    // When tests are listed, before any runs, so it can't be an issue.
    for slug in slugs where slugs.count(where: { $0 == slug }) > 1 {
      fatalError("\(screen) has two states named \(slug): their references would be the same.")
    }
    // Every state, not only the selected ones, so a filtered run checks the whole manifest.
    let manifest = CatalogManifest(screen: screen, states: states)
    self.states = states.map { state in
      var state = state
      state.manifest = manifest
      return state
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
  /// Its catalog's manifest, for Pixelbook.
  fileprivate(set) var manifest: CatalogManifest?
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

/// What Pixelbook publishes of a catalog's screen (851-2955): its states, where each is written,
/// and its references, in light and dark. Committed beside the references, as
/// `__Snapshots__/<catalog file>/<screen>.json`, since a catalog can't be read without running it
/// (a state can be shared, or built for one platform only). `scripts/pixelbook publish` reads it
/// from a commit, with no Mac. A catalog's test writes it when it's missing or differs, and fails
/// unless it's recording (`scripts/snapshot --record`), as SnapshotTesting does with references.
/// Paths are from the repository's root. Lines aren't kept: Pixelbook finds each state's
/// `CatalogState("…")` in its file when it publishes, so editing a catalog doesn't make the
/// manifest stale.
struct CatalogManifest: Encodable, Sendable {
  struct State: Encodable, Sendable {
    /// `<screen>.<state>`, as slugs: Pixelbook's ID for the state, stable while its name is.
    let id: String
    let name: String
    /// The file the state is written in.
    let source: String
    /// Its references.
    let light: String
    let dark: String
  }

  /// Pixelbook's app, e.g. `health-mac`: the test target's (`pixelbookApp`).
  var app = ""
  let screen: String
  /// The catalog as graphs name it, `<Module>/<File>.swift` (in `Catalogs/<Module>/`).
  let catalog: String
  let states: [State]
  /// The manifest's own file. Not written.
  let url: URL

  private enum CodingKeys: CodingKey {
    case app, screen, catalog, states
  }

  /// Its first state's file is the catalog's.
  fileprivate init(screen: String, states: [CatalogState]) {
    let file = states.first.map { "\($0.filePath)" } ?? ""
    let catalogFile = URL(filePath: file)
    self.screen = screen
    catalog = [
      catalogFile.deletingLastPathComponent().lastPathComponent, catalogFile.lastPathComponent,
    ].joined(separator: "/")
    self.states = states.map { state in
      let reference = { (appearance: String) in
        repositoryPath(
          referenceURL(
            file: state.filePath, testName: state.screenSlug, name: "\(state.slug)-\(appearance)"
          ).path)
      }
      return State(
        id: "\(state.screenSlug).\(state.slug)", name: state.name,
        source: repositoryPath("\(state.filePath)"), light: reference("light"),
        dark: reference("dark"))
    }
    url = catalogFile.deletingLastPathComponent()
      .appending(
        components: "__Snapshots__", catalogFile.deletingPathExtension().lastPathComponent,
        "\(states.first?.screenSlug ?? "catalog").json")
  }

  /// The manifest's JSON, as it's committed.
  var json: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    // Encoding plain strings can't fail.
    return try! encoder.encode(self) + Data("\n".utf8)
  }
}

/// A path from the repository's root, `LilPackage/…`, wherever it's checked out.
private func repositoryPath(_ path: String) -> String {
  guard let range = path.range(of: "/LilPackage/", options: .backwards) else { return path }
  return String(path[path.index(after: range.lowerBound)...])
}

/// The manifests this process has checked: one per screen, whichever of its states runs first.
private let checkedManifests = Mutex<Set<String>>([])

extension CatalogState {
  /// Checks its catalog's manifest for Pixelbook (`CatalogManifest`), once per screen and process:
  /// writes it if it's missing or differs, and records an issue unless SnapshotTesting is
  /// recording (`SNAPSHOT_TESTING_RECORD` is `all` or `failed`, as `scripts/snapshot --record`
  /// sets it).
  func checkManifest(app: String) {
    guard var manifest else { return }
    manifest.app = app
    let url = manifest.url
    guard checkedManifests.withLock({ $0.insert(url.path).inserted }) else { return }
    let json = manifest.json
    guard (try? Data(contentsOf: url)) != json else { return }
    let location = SourceLocation(
      fileID: "\(fileID)", filePath: "\(filePath)", line: Int(line), column: Int(column))
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try json.write(to: url)
    } catch {
      Issue.record("Couldn't write \(url.path): \(error)", sourceLocation: location)
      return
    }
    let record = ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_RECORD"]
    guard record != "all", record != "failed" else { return }
    Issue.record(
      """
      \(screen)'s Pixelbook manifest was missing or out of date, so it was written: commit \
      \(repositoryPath(url.path)).
      """, sourceLocation: location)
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
      checkManifest(app: pixelbookApp)
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        assertMacSnapshot(
          of: view().frame(width: width).frame(minHeight: minHeight, alignment: .top),
          appearance: appearance, named: slug, screen: screenSlug, fileID: fileID, file: filePath,
          line: line, column: column)
      }
    }
  }
#endif
