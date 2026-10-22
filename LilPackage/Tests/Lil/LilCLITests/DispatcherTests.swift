import Foundation
import Testing

@testable import LilCLI

/// Resolution with real files: a fake `Test.app` (bundle ID `tech.lil.test`) and `PATH`
/// directories holding fake `lil-test` tools.
struct DispatcherTests {
  let root: URL
  let app: URL
  let firstPath: URL
  let secondPath: URL

  init() throws {
    root = try makeTemporaryDirectory()
    app = root.appending(path: "Applications/Test.app", directoryHint: .isDirectory)
    firstPath = root.appending(path: "first", directoryHint: .isDirectory)
    secondPath = root.appending(path: "second", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: app.appending(path: "Contents/MacOS"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondPath, withIntermediateDirectories: true)
  }

  func dispatcher(
    installed: [String: URL]? = nil,
    describe: @escaping @Sendable (URL) -> String? = { _ in nil }
  ) -> Dispatcher {
    let installed = installed ?? ["tech.lil.test": app]
    return Dispatcher(
      applicationURL: { installed[$0] },
      searchPath: [firstPath, secondPath],
      describe: describe,
      version: 42,
      knownApps: ["health", "test"]
    )
  }

  var bundledTool: URL { app.appending(path: "Contents/MacOS/lil-test") }

  @Test
  func prefersTheToolInsideTheInstalledApp() throws {
    try writeScript("exit 0", to: bundledTool)
    try writeScript("exit 0", to: firstPath.appending(path: "lil-test"))

    #expect(dispatcher().locate(app: "test") == .tool(bundledTool))
  }

  @Test
  func fallsBackToPathInOrder() throws {
    try writeScript("exit 0", to: secondPath.appending(path: "lil-test"))
    #expect(dispatcher().locate(app: "test") == .tool(secondPath.appending(path: "lil-test")))

    try writeScript("exit 0", to: firstPath.appending(path: "lil-test"))
    #expect(dispatcher().locate(app: "test") == .tool(firstPath.appending(path: "lil-test")))

    // Without the app installed.
    #expect(
      dispatcher(installed: [:]).locate(app: "test")
        == .tool(firstPath.appending(path: "lil-test"))
    )
  }

  @Test
  func skipsWhatItCantRun() throws {
    try writeScript("exit 0", to: bundledTool, executable: false)
    try FileManager.default.createDirectory(
      at: firstPath.appending(path: "lil-test"),
      withIntermediateDirectories: true
    )
    try writeScript("exit 0", to: secondPath.appending(path: "lil-test"))

    #expect(dispatcher().locate(app: "test") == .tool(secondPath.appending(path: "lil-test")))
  }

  @Test
  func reportsAnAppWithoutATool() {
    #expect(dispatcher().locate(app: "test") == .appWithoutTool(app))
    #expect(dispatcher(installed: [:]).locate(app: "test") == .notFound)
  }

  @Test
  func passesArgumentsThroughUnchanged() throws {
    try writeScript("exit 0", to: bundledTool)
    let arguments = ["summary", "--json", "", "two words", "-h", "--version", "help", "ünïcode"]

    #expect(
      dispatcher().action(for: ["test"] + arguments) == .exec(bundledTool, arguments: arguments)
    )
    #expect(dispatcher().action(for: ["test"]) == .exec(bundledTool, arguments: []))
    #expect(
      dispatcher().action(for: ["help", "test"]) == .exec(bundledTool, arguments: ["--help"]))
  }

  @Test
  func saysWhenAnAppHasNoToolYet() {
    // Until lil health bundles lil-health (851-2843).
    let health = root.appending(path: "Applications/lil health.app")
    let action = dispatcher(installed: ["tech.lil.health": health]).action(for: ["health", "x"])

    guard case .printError(let message, let status) = action else {
      Issue.record("\(action)")
      return
    }
    #expect(status == 127)
    #expect(message.contains("lil health has no command line tool yet"))
    #expect(message.contains(health.path))
  }

  @Test
  func saysWhenAnAppIsntInstalled() {
    #expect(
      dispatcher(installed: [:]).action(for: ["health"])
        == .printError("lil: lil health isn't installed.\n", status: 127)
    )
    #expect(
      dispatcher(installed: [:]).action(for: ["nope"])
        == .printError(
          "lil: 'nope' isn't an installed lil app with a command line tool. See 'lil help'.\n",
          status: 127
        )
    )
  }

  @Test
  func listsAppsWithToolsAndTheirDescriptions() throws {
    try writeScript("exit 0", to: bundledTool)
    try writeScript("exit 0", to: secondPath.appending(path: "lil-another-app"))
    // Not apps' tools.
    try writeScript("exit 0", to: secondPath.appending(path: "lil-Bad.sh"))
    try writeScript("exit 0", to: secondPath.appending(path: "lil-quiet"), executable: false)
    // `lil`'s own commands.
    try writeScript("exit 0", to: secondPath.appending(path: "lil-help"))
    try writeScript("exit 0", to: secondPath.appending(path: "lil-mcp"))
    // Only known apps' tools are asked to describe themselves.
    let dispatcher = dispatcher(describe: { tool in
      tool.lastPathComponent == "lil-test" ? "Tests things" : "Shouldn't be asked"
    })

    #expect(dispatcher.appsWithTools().map(\.app) == ["another-app", "test"])
    guard case .print(let listing, 0) = dispatcher.action(for: []) else {
      Issue.record("\(dispatcher.action(for: []))")
      return
    }
    #expect(listing.hasPrefix("usage: lil <app>"))
    #expect(listing.contains("\n       lil mcp "))
    #expect(listing.hasSuffix("Installed apps:\n  another-app\n  test          Tests things\n"))
  }

  @Test
  func listsNoApps() {
    guard case .print(let listing, 0) = dispatcher(installed: [:]).action(for: ["help"]) else {
      Issue.record("not a listing")
      return
    }
    #expect(listing.hasSuffix("No installed lil app has a command line tool yet.\n"))
  }

  /// `lil mcp` is `lil`'s own, even with a `lil-mcp` on `PATH`.
  @Test
  func servesMCP() throws {
    try writeScript("exit 0", to: firstPath.appending(path: "lil-mcp"))
    #expect(dispatcher().action(for: ["mcp"]) == .serveMCP)
    guard case .printError(let message, 64) = dispatcher().action(for: ["mcp", "health"]) else {
      Issue.record("\(dispatcher().action(for: ["mcp", "health"]))")
      return
    }
    #expect(message.hasPrefix("lil: mcp takes no arguments\n"))
  }

  @Test
  func printsItsVersion() {
    #expect(dispatcher().action(for: ["--version"]) == .print("lil 42\n", status: 0))
  }

  @Test
  func describesAToolWithTheFirstLineOfItsDescribe() throws {
    let tool = try writeScript(
      "[ \"$1\" = --describe ] && printf '  Tests things  \\nMore\\n'",
      to: firstPath.appending(path: "lil-test")
    )
    let failing = try writeScript("exit 1", to: firstPath.appending(path: "lil-failing"))
    let hanging = try writeScript("sleep 10", to: firstPath.appending(path: "lil-hanging"))

    #expect(LilCLI.description(of: tool) == "Tests things")
    #expect(LilCLI.description(of: failing) == nil)
    let start = ContinuousClock.now
    #expect(LilCLI.output(of: hanging, arguments: [], timeout: .milliseconds(200)) == nil)
    #expect(ContinuousClock.now - start < .seconds(5))
  }

  @Test
  func skipsEmptyPathEntries() {
    #expect(
      Dispatcher.searchPath("/usr/bin::/bin:").map(\.path) == ["/usr/bin", "/bin"]
    )
  }
}
