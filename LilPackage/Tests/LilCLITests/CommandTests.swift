import Testing

@testable import LilCLI

struct CommandTests {
  @Test(arguments: [[], ["help"], ["--help"], ["-h"]])
  func listsAppsWithoutAnApp(arguments: [String]) {
    #expect(Command(arguments: arguments) == .listApps)
  }

  @Test
  func helpForAnApp() {
    #expect(Command(arguments: ["help", "health"]) == .help(app: "health"))
    #expect(Command(arguments: ["--help", "health"]) == .help(app: "health"))
  }

  @Test
  func version() {
    #expect(Command(arguments: ["--version"]) == .version)
  }

  @Test
  func mcp() {
    #expect(Command(arguments: ["mcp"]) == .mcp)
  }

  @Test
  func runsAnAppWithEverythingAfterItsName() {
    #expect(
      Command(arguments: ["health", "summary", "--json", "--help", "a b"])
        == .run(app: "health", arguments: ["summary", "--json", "--help", "a b"])
    )
    #expect(Command(arguments: ["health"]) == .run(app: "health", arguments: []))
    #expect(Command(arguments: ["two-words"]) == .run(app: "two-words", arguments: []))
  }

  @Test(arguments: [
    ["--verbose"], ["-x", "health"], ["Health"], ["../health"], ["health.sh"], ["-"], ["a-"],
    ["help", "health", "more"], ["help", "/bin"], ["--version", "health"], ["b\u{20DD}"],
    ["y\u{0331}"], ["héalth"], ["mcp", "health"], ["help", "mcp"], ["help", "help"],
  ])
  func rejectsWhatIsntAnAppOrOption(arguments: [String]) {
    guard case .usageError = Command(arguments: arguments) else {
      Issue.record("\(arguments) parsed as \(Command(arguments: arguments))")
      return
    }
  }

  @Test
  func parsesVersionOutput() {
    #expect(LilCLI.version(fromOutput: "lil 1234\n") == 1234)
    #expect(LilCLI.version(fromOutput: "lil 0") == 0)
    #expect(LilCLI.version(fromOutput: "lil version 3\n") == nil)
    #expect(LilCLI.version(fromOutput: "lal 3\n") == nil)
    #expect(LilCLI.version(fromOutput: "") == nil)
  }
}
