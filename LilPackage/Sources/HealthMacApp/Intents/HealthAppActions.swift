public import Dependencies
public import Foundation
import Synchronization

/// What lil health for Mac's app actions ask the running app to do (851-2892): its intents now,
/// and the command line's requests later (851-2895). `AppFeature` performs each one with the
/// same reducer actions as the UI.
public enum HealthAppAction: Equatable, Sendable {
  /// Brings the main window forward and shows a page.
  case open(HealthPage)

  /// The action as the access log shows it, e.g. `open Steps`.
  public var command: String {
    switch self {
    case .open(let page): "open \(page.name)"
    }
  }
}

/// What the app answers once it has performed an action.
public enum HealthAppActionResult: Equatable, Sendable {
  /// Done, with nothing to say: the page is open.
  case done
}

/// Why the app couldn't perform an action.
public enum HealthAppActionError: Error, Equatable, LocalizedError,
  CustomLocalizedStringResourceConvertible
{
  /// Signed out, or not signed in within `HealthAppActions.signInWait` of launch.
  case signedOut

  public var errorDescription: String? {
    switch self {
    case .signedOut: "Sign in to lil health first."
    }
  }

  public var localizedStringResource: LocalizedStringResource {
    "\(errorDescription ?? "")"
  }
}

/// An action for the app to perform, with how to answer whoever asked.
public struct HealthAppActionRequest: Sendable {
  public let action: HealthAppAction
  private let reply: @Sendable (Result<HealthAppActionResult, any Error>) -> Void

  public init(
    action: HealthAppAction,
    reply: @escaping @Sendable (Result<HealthAppActionResult, any Error>) -> Void
  ) {
    self.action = action
    self.reply = reply
  }

  /// Answers whoever asked. Only the first answer counts.
  public func finish(_ result: Result<HealthAppActionResult, any Error>) {
    reply(result)
  }
}

/// How app actions reach the running app's store (851-2892). Whoever asks (an intent) calls
/// `perform`; `AppFeature` reads `requests` while signed in and answers each one.
public struct HealthAppActions: Sendable {
  /// Asks the app to perform an action, and waits for its answer. Fails with
  /// `HealthAppActionError.signedOut` when the app is signed out, or isn't signed in within
  /// `signInWait` of launch (an intent may launch it).
  public var perform: @Sendable (_ action: HealthAppAction) async throws -> HealthAppActionResult
  /// The actions asked for, for the app to perform while signed in. When the stream ends (on
  /// signing out), what it hadn't answered fails.
  public var requests: @Sendable () -> AsyncStream<HealthAppActionRequest>

  public init(
    perform: @escaping @Sendable (_ action: HealthAppAction) async throws -> HealthAppActionResult,
    requests: @escaping @Sendable () -> AsyncStream<HealthAppActionRequest>
  ) {
    self.perform = perform
    self.requests = requests
  }

  /// How long after launch an action waits for the app to be signed in: an intent that launches
  /// the app arrives before the stored session has been checked.
  public static let signInWait: Duration = .seconds(10)

  /// The app's: created when the app launches (`LilHealthApp` prepares it), which starts
  /// `signInWait`.
  public static let live = Self(channel: HealthAppActionChannel(signInWait: signInWait))

  init(channel: HealthAppActionChannel) {
    self.init(perform: { try await channel.perform($0) }, requests: { channel.requests() })
  }
}

extension HealthAppActions: DependencyKey {
  public static var liveValue: Self { live }

  /// Nothing asks unless a test does: an empty stream, so a signed-in store serves nothing.
  public static var testValue: Self {
    Self(
      perform: unimplemented("HealthAppActions.perform", placeholder: .done),
      requests: { AsyncStream { $0.finish() } }
    )
  }
}

extension DependencyValues {
  public var healthAppActions: HealthAppActions {
    get { self[HealthAppActions.self] }
    set { self[HealthAppActions.self] = newValue }
  }
}

/// Hands actions to the store that serves them, and their answers back. One server at a time:
/// the app has one store.
final class HealthAppActionChannel: Sendable {
  private typealias Reply = CheckedContinuation<HealthAppActionResult?, any Error>

  private struct State {
    var server: (id: UUID, continuation: AsyncStream<HealthAppActionRequest>.Continuation)?
    /// Asked and not answered yet, with the server each went to.
    var pending: [UUID: (server: UUID, reply: Reply)] = [:]
  }

  private let state = Mutex(State())
  /// Until when an action waits for a server, rather than failing at once.
  private let deadline: ContinuousClock.Instant
  /// How often a waiting action looks for a server.
  private let pollInterval: Duration

  init(signInWait: Duration, pollInterval: Duration = .milliseconds(100)) {
    deadline = .now + signInWait
    self.pollInterval = pollInterval
  }

  func requests() -> AsyncStream<HealthAppActionRequest> {
    let (stream, continuation) = AsyncStream<HealthAppActionRequest>.makeStream()
    let id = UUID()
    let replaced = state.withLock { state in
      defer { state.server = (id, continuation) }
      return state.server?.continuation
    }
    replaced?.finish()
    continuation.onTermination = { [self] _ in serverEnded(id) }
    return stream
  }

  func perform(_ action: HealthAppAction) async throws -> HealthAppActionResult {
    while true {
      if let result = try await send(action) { return result }
      guard ContinuousClock.now < deadline else { throw HealthAppActionError.signedOut }
      try await Task.sleep(for: pollInterval)
    }
  }

  /// Hands the action to the server and waits for its answer. `nil` if there's no server.
  private func send(_ action: HealthAppAction) async throws -> HealthAppActionResult? {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (reply: Reply) in
        let server = state.withLock {
          state -> AsyncStream<HealthAppActionRequest>.Continuation? in
          guard let server = state.server else { return nil }
          state.pending[id] = (server.id, reply)
          return server.continuation
        }
        guard let server else { return reply.resume(returning: nil) }
        let request = HealthAppActionRequest(action: action) { [self] result in
          finish(id, result.map { $0 })
        }
        if case .terminated = server.yield(request) {
          finish(id, .failure(HealthAppActionError.signedOut))
        }
        // Cancelled before the reply was registered, so the handler found nothing to cancel.
        if Task.isCancelled { finish(id, .failure(CancellationError())) }
      }
    } onCancel: {
      finish(id, .failure(CancellationError()))
    }
  }

  private func finish(_ id: UUID, _ result: Result<HealthAppActionResult?, any Error>) {
    state.withLock { $0.pending.removeValue(forKey: id) }?.reply.resume(with: result)
  }

  /// The store stopped serving (signed out): what it hadn't answered fails.
  private func serverEnded(_ id: UUID) {
    let unanswered = state.withLock { state in
      if state.server?.id == id { state.server = nil }
      let unanswered = state.pending.filter { $0.value.server == id }
      for key in unanswered.keys { state.pending[key] = nil }
      return unanswered.values.map(\.reply)
    }
    for reply in unanswered { reply.resume(throwing: HealthAppActionError.signedOut) }
  }
}
