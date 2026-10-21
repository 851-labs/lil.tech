public import Foundation

/// Which deployment of `api.lil.tech` the apps talk to.
public enum APIEnvironment: Hashable, Sendable {
  case prod
  case staging
  /// A pull request's preview deployment, e.g. `https://lil-api-api-pr-57-….851.workers.dev`.
  case preview(URL)

  public var baseURL: URL {
    switch self {
    case .prod: URL(string: "https://api.lil.tech")!
    case .staging: URL(string: "https://api.staging.lil.tech")!
    case .preview(let url): url
    }
  }

  /// An app's remote MCP server, the URL people paste into an agent: `https://mcp.lil.tech/health`
  /// (`mcp.staging.lil.tech` on staging, the deployment's own host on a preview).
  public func mcpURL(app: String) -> URL {
    switch self {
    case .prod: URL(string: "https://mcp.lil.tech")!.appending(path: app)
    case .staging: URL(string: "https://mcp.staging.lil.tech")!.appending(path: app)
    case .preview(let url): url.appending(path: app)
    }
  }

  /// Whether its MCP servers and OAuth routes are up, so agents can connect: staging and previews
  /// now, prod at launch (851-2855).
  public var servesAgents: Bool {
    switch self {
    case .prod: false
    case .staging, .preview: true
    }
  }

  /// Whether this build may talk to a deployment other than its default. Device builds carry
  /// real Health data, which must only go to prod, so only simulator and Debug Mac builds may.
  #if targetEnvironment(simulator) || (os(macOS) && DEBUG)
    public static let allowsOverride = true
  #else
    public static let allowsOverride = false
  #endif

  /// The environment for this build.
  ///
  /// - Simulator builds and Debug Mac builds use staging, which only ever holds synthetic data.
  ///   `LIL_API_URL` in the environment (e.g. a scheme's environment variables) points them at
  ///   another deployment, such as a PR preview.
  /// - Everything else uses prod, and ignores `LIL_API_URL`.
  public static func current(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    allowsOverride: Bool = allowsOverride
  ) -> Self {
    guard allowsOverride else { return .prod }
    guard let override = environment["LIL_API_URL"] else { return .staging }
    return Self(url: override) ?? .staging
  }

  /// Parses a deployment URL, keeping only its scheme, host and port, so pasted links with a path
  /// or trailing slash (e.g. `https://…workers.dev/v1/status`) still work.
  public init?(url string: String) {
    guard
      let components = URLComponents(string: string),
      let scheme = components.scheme, scheme == "https" || scheme == "http",
      let host = components.host, !host.isEmpty
    else { return nil }
    var base = URLComponents()
    base.scheme = scheme
    base.host = host
    base.port = components.port
    guard let url = base.url else { return nil }
    switch url {
    case Self.prod.baseURL: self = .prod
    case Self.staging.baseURL: self = .staging
    default: self = .preview(url)
    }
  }
}
