/// What `lil` was asked to do, from its arguments (without the program's name).
public enum Command: Equatable, Sendable {
  /// `lil`, `lil help`: the usage, and the installed apps with a command line tool.
  case listApps
  /// `lil help <app>`: the app's own help (`lil-<app> --help`).
  case help(app: String)
  /// `lil --version`.
  case version
  /// `lil mcp`: one MCP server with every app's tools (851-2897).
  case mcp
  /// `lil <app> <arguments…>`: runs `lil-<app> <arguments…>`.
  case run(app: String, arguments: [String])
  /// Arguments `lil` doesn't understand, with what's wrong.
  case usageError(String)

  public init(arguments: [String]) {
    guard let first = arguments.first else {
      self = .listApps
      return
    }
    let rest = Array(arguments.dropFirst())
    switch first {
    case "help", "--help", "-h":
      switch rest.count {
      case 0:
        self = .listApps
      case 1 where isAppName(rest[0]):
        self = .help(app: rest[0])
      case 1:
        self = .usageError("'\(rest[0])' isn't the name of a lil app")
      default:
        self = .usageError("help takes one app, e.g. 'lil help health'")
      }
    case "--version":
      self = rest.isEmpty ? .version : .usageError("--version takes no arguments")
    case "mcp":
      self = rest.isEmpty ? .mcp : .usageError("mcp takes no arguments")
    case _ where first.hasPrefix("-"):
      self = .usageError("unknown option: \(first)")
    case _ where isAppName(first):
      // Everything after the app's name is the app's, options included.
      self = .run(app: first, arguments: rest)
    default:
      self = .usageError("'\(first)' isn't the name of a lil app")
    }
  }
}

/// Words `lil` keeps for its own commands, so no app can be called them: `lil help` and `lil mcp`
/// never run a `lil-help` or `lil-mcp`.
let reservedWords: Set<String> = ["help", "mcp"]

/// Whether `name` can name a lil app: lowercase letters, digits and inner hyphens, like `health`,
/// and not a reserved word. It becomes part of a bundle ID (`tech.lil.<app>`), an executable's
/// name (`lil-<app>`) and, before a dot, the names of its MCP tools (`health.summary`).
func isAppName(_ name: some StringProtocol) -> Bool {
  !name.isEmpty
    && !reservedWords.contains(String(name))
    && !name.hasPrefix("-")
    && !name.hasSuffix("-")
    && name.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
    }
}
