import ConcurrencyExtras
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
/// access token is no longer good (code 4001: it expired, or the account was deleted), and another
/// error for anything else.
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
  /// How long to wait for the `pong` before treating the connection as dead.
  static let pongTimeout = Duration.seconds(10)

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
        let lastHeard = LockIsolated(ContinuousClock.now)
        let receiving = Task {
          do {
            while true {
              let message = try await task.receive()
              lastHeard.setValue(ContinuousClock.now)
              if case .string(let text) = message, text != "pong" { continuation.yield(text) }
            }
          } catch {
            // The close code can be recorded just after `receive` fails.
            for _ in 0..<20 where task.closeCode == .invalid {
              try? await Task.sleep(for: .milliseconds(50))
            }
            switch task.closeCode.rawValue {
            case 4001: continuation.finish(throwing: TokenExpired())
            case 0: continuation.finish(throwing: error)
            case let code: continuation.finish(throwing: Closed(code: code))
            }
          }
        }
        // A connection that silently died (e.g. a network switch) answers no pings; give up on it.
        let pinging = Task {
          while !Task.isCancelled {
            try await Task.sleep(for: pingInterval)
            let sentAt = ContinuousClock.now
            try await task.send(.string("ping"))
            try await Task.sleep(for: pongTimeout)
            if lastHeard.value < sentAt {
              task.cancel(with: .goingAway, reason: nil)
              continuation.finish(throwing: URLError(.timedOut))
              return
            }
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
