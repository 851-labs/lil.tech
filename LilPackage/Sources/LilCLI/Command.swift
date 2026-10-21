/// What `lil` was asked to do, from its arguments (without the program's name).
public enum Command: Equatable, Sendable {
  /// `lil`, `lil help`: the usage, and the installed apps with a command line tool.
  case listApps
  /// `lil help <app>`: the app's own help (`lil-<app> --help`).
  case help(app: String)
  /// `lil --version`.
  case version
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

/// Whether `name` can name a lil app: lowercase letters, digits and inner hyphens, like `health`.
/// It becomes part of a bundle ID (`tech.lil.<app>`) and an executable's name (`lil-<app>`).
func isAppName(_ name: some StringProtocol) -> Bool {
  !name.isEmpty
    && !name.hasPrefix("-")
    && !name.hasSuffix("-")
    && name.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
    }
}
