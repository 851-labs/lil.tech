public import Foundation

#if canImport(AppKit)
  import AppKit
#endif

/// Finds each app's command line tool, `lil-<app>`, and decides what `lil` does with its
/// arguments.
///
/// A tool is looked for inside the installed app first, so it survives the app moving and Sparkle
/// updating it, then on `PATH` (dev builds, future Homebrew installs).
public struct Dispatcher: Sendable {
  /// The installed app with this bundle ID, if any (`NSWorkspace`, live).
  public var applicationURL: @Sendable (_ bundleIdentifier: String) -> URL?
  /// The directories of `PATH`, in order.
  public var searchPath: [URL]
  /// A tool's one-line description, from `lil-<app> --describe`.
  public var describe: @Sendable (_ tool: URL) -> String?
  /// This copy's version (`lil --version`).
  public var version: Int
  /// The apps whose tools `lil help` looks for inside them, besides any `lil-<app>` on `PATH`.
  public var knownApps: [String]

  public init(
    applicationURL: @escaping @Sendable (_ bundleIdentifier: String) -> URL?,
    searchPath: [URL],
    describe: @escaping @Sendable (_ tool: URL) -> String? = LilCLI.description(of:),
    version: Int = LilCLI.version,
    knownApps: [String] = Dispatcher.apps
  ) {
    self.applicationURL = applicationURL
    self.searchPath = searchPath
    self.describe = describe
    self.version = version
    self.knownApps = knownApps
  }

  /// Every lil app for Mac, by the name `lil` knows it by (`tech.lil.<app>`, `lil-<app>`).
  public static let apps = ["health", "messages"]

  /// What looking for an app's tool found.
  public enum Location: Equatable, Sendable {
    /// The tool to run.
    case tool(URL)
    /// The app is installed (here), but neither it nor `PATH` has a tool for it.
    case appWithoutTool(URL)
    /// Neither the app nor a tool for it.
    case notFound
  }

  public func locate(app: String) -> Location {
    let name = "lil-\(app)"
    let appURL = applicationURL("tech.lil.\(app)")
    if let appURL {
      let tool = appURL.appending(components: "Contents", "MacOS", name)
      if isExecutableFile(tool) {
        return .tool(tool)
      }
    }
    for directory in searchPath {
      let tool = directory.appending(component: name)
      if isExecutableFile(tool) {
        return .tool(tool)
      }
    }
    return appURL.map(Location.appWithoutTool) ?? .notFound
  }

  /// The apps with a tool, by name, sorted: the known apps, and any `lil-<app>` on `PATH`.
  public func appsWithTools() -> [(app: String, tool: URL)] {
    var names = Set(knownApps)
    for directory in searchPath {
      let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      for file in files where file.hasPrefix("lil-") {
        let app = file.dropFirst("lil-".count)
        if isAppName(app) {
          names.insert(String(app))
        }
      }
    }
    return names.sorted().compactMap { app in
      guard case .tool(let tool) = locate(app: app) else { return nil }
      return (app, tool)
    }
  }

  /// What `lil` does with these arguments (without the program's name).
  public func action(for arguments: [String]) -> Action {
    switch Command(arguments: arguments) {
    case .listApps:
      return .print(listing(), status: 0)
    case .version:
      return .print("lil \(version)\n", status: 0)
    case .help(let app):
      return run(app: app, arguments: ["--help"])
    case .run(let app, let arguments):
      return run(app: app, arguments: arguments)
    case .usageError(let message):
      return .printError("lil: \(message)\n\n\(Self.usage)", status: Action.usageStatus)
    }
  }

  private func run(app: String, arguments: [String]) -> Action {
    switch locate(app: app) {
    case .tool(let tool):
      return .exec(tool, arguments: arguments)
    case .appWithoutTool(let appURL):
      return .printError(
        """
        lil: lil \(app) has no command line tool yet. It's installed at \(appURL.path), but this \
        version doesn't include lil-\(app). Update lil \(app) to use 'lil \(app)'.

        """,
        status: Action.notFoundStatus
      )
    case .notFound:
      let message =
        knownApps.contains(app)
        ? "lil \(app) isn't installed."
        : "'\(app)' isn't an installed lil app with a command line tool. See 'lil help'."
      return .printError("lil: \(message)\n", status: Action.notFoundStatus)
    }
  }

  static let usage = """
    usage: lil <app> [<arguments>…]   Runs the app's command line tool, lil-<app>.
           lil help <app>              Shows the app's help.
           lil --version

    """

  private func listing() -> String {
    let apps = appsWithTools()
    guard !apps.isEmpty else {
      return Self.usage + "\nNo installed lil app has a command line tool yet.\n"
    }
    let width = apps.map(\.app.count).max() ?? 0
    let lines = apps.map { app, tool in
      guard let description = describe(tool), !description.isEmpty else { return "  \(app)\n" }
      return "  \(app.padding(toLength: width, withPad: " ", startingAt: 0))   \(description)\n"
    }
    return Self.usage + "\nInstalled apps:\n" + lines.joined()
  }
}

/// What `lil` does, decided by `Dispatcher.action(for:)` and done by `LilCLI.main()`.
public enum Action: Equatable, Sendable {
  /// Prints to standard output and exits.
  case print(String, status: Int32)
  /// Prints to standard error and exits.
  case printError(String, status: Int32)
  /// Replaces `lil` with the tool, so its input, output, signals and exit status are the tool's.
  case exec(URL, arguments: [String])

  /// `EX_USAGE`.
  static let usageStatus: Int32 = 64
  /// What shells exit with for a command they can't find.
  static let notFoundStatus: Int32 = 127
  /// What shells exit with for a command they found but couldn't run.
  static let cannotExecuteStatus: Int32 = 126
}

extension Dispatcher {
  /// The installed apps (from Launch Services) and the process's `PATH`.
  public static func live(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    Self(
      applicationURL: { bundleIdentifier in
        #if canImport(AppKit)
          NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        #else
          nil
        #endif
      },
      searchPath: searchPath(environment["PATH"] ?? "")
    )
  }

  /// `PATH`'s directories. Empty entries, which POSIX reads as the current directory, are
  /// skipped: `lil` shouldn't run whatever `lil-<app>` the directory it's run in holds.
  static func searchPath(_ path: String) -> [URL] {
    path.split(separator: ":", omittingEmptySubsequences: true).map {
      URL(filePath: String($0), directoryHint: .isDirectory)
    }
  }
}

/// Whether `url` is a file (or a link to one) this process may execute. Directories are
/// "executable" too, to `access(2)`.
func isExecutableFile(_ url: URL) -> Bool {
  var isDirectory: ObjCBool = false
  return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    && !isDirectory.boolValue
    && FileManager.default.isExecutableFile(atPath: url.path)
}
