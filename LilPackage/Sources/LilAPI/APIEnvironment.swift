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

  /// The environment for this build.
  ///
  /// - `LIL_API_URL` in the environment (e.g. a scheme's environment variables) points the app at
  ///   any deployment, such as a PR preview.
  /// - Otherwise simulator builds and Debug Mac builds use staging, which only ever holds
  ///   synthetic data, and everything else uses prod.
  public static func current(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    if let override = environment["LIL_API_URL"], let url = URL(string: override) {
      return url == prod.baseURL ? .prod : url == staging.baseURL ? .staging : .preview(url)
    }
    #if targetEnvironment(simulator) || (os(macOS) && DEBUG)
      return .staging
    #else
      return .prod
    #endif
  }
}
