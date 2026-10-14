public import Dependencies
import Foundation
import LilAPI

extension DependencyValues {
  /// Opens live notice connections for ``LilSyncEngine/listen(accessToken:)``.
  public var liveConnection: LiveConnection {
    get { self[LiveConnection.self] }
    set { self[LiveConnection.self] = newValue }
  }
}

/// A WebSocket to `GET /v1/sync/live` (`docs/SYNC.md`): the server's text messages until it
/// closes. The stream ends by throwing ``TokenExpired`` when the server closes it because the
/// access token expired (code 4001), and another error for anything else.
public struct LiveConnection: Sendable {
  public var connect:
    @Sendable (_ accessToken: String) async throws -> AsyncThrowingStream<String, any Error>

  public init(
    connect:
      @escaping @Sendable (_ accessToken: String) async throws -> AsyncThrowingStream<
        String, any Error
      >
  ) {
    self.connect = connect
  }

  /// The server closed the connection because its access token expired.
  public struct TokenExpired: Error, Equatable {
    public init() {}
  }

  /// The server closed the connection.
  public struct Closed: Error, Equatable {
    public let code: Int
    public init(code: Int) { self.code = code }
  }
}

extension LiveConnection: DependencyKey {
  /// How often the live value sends `ping`, which the server answers with `pong` without waking
  /// the user's store, to keep the connection from idling out.
  static let pingInterval = Duration.seconds(30)

  public static var liveValue: Self {
    Self { accessToken in
      var components = URLComponents(
        url: APIEnvironment.current().baseURL.appending(path: "v1/sync/live"),
        resolvingAgainstBaseURL: false)
      let scheme = components?.scheme == "http" ? "ws" : "wss"
      components?.scheme = scheme
      guard let url = components?.url else { throw URLError(.badURL) }
      var request = URLRequest(url: url)
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
      let task = URLSession.shared.webSocketTask(with: request)
      task.resume()

      return AsyncThrowingStream { continuation in
        let receiving = Task {
          do {
            while true {
              if case .string(let text) = try await task.receive(), text != "pong" {
                continuation.yield(text)
              }
            }
          } catch {
            switch task.closeCode.rawValue {
            case 4001: continuation.finish(throwing: TokenExpired())
            case 0: continuation.finish(throwing: error)
            case let code: continuation.finish(throwing: Closed(code: code))
            }
          }
        }
        let pinging = Task {
          while !Task.isCancelled {
            try await Task.sleep(for: pingInterval)
            try await task.send(.string("ping"))
          }
        }
        continuation.onTermination = { _ in
          receiving.cancel()
          pinging.cancel()
          task.cancel(with: .goingAway, reason: nil)
        }
      }
    }
  }

  public static var testValue: Self {
    Self { _ in
      reportIssue("Unimplemented: @Dependency(\\.liveConnection)")
      return AsyncThrowingStream { $0.finish() }
    }
  }
}
