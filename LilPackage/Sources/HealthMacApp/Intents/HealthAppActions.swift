public import Dependencies
public import Foundation
import Synchronization

/// What lil health for Mac's app actions ask the running app to do (851-2892): its intents now,
/// and the command line's requests later (851-2895). `AppFeature` performs each one with the
/// same reducer actions as the UI.
public enum HealthAppAction: Equatable, Sendable {
  /// Brings the main window forward and shows a page.
  case open(HealthPage)
  /// Pulls the account's changes from the server now, as Try Again does (or lets a pull already
  /// running finish), and waits for the pull to end, at most `HealthAppActions.syncWait`
  /// (851-2893). The Mac never uploads: the iPhone does.
  case sync
  /// Exports the account's data into a folder, without the save panel (851-2894): the archive
  /// the server prepares, under the name the panel would suggest, numbered if it's taken. One
  /// export at a time, from Settings or an action.
  case export(to: URL)

  /// The action as the access log shows it, e.g. `open Steps` or `export ~/Downloads`.
  public var command: String {
    switch self {
    case .open(let page): "open \(page.name)"
    case .sync: "sync"
    case .export(let folder): "export \(Self.displayPath(folder))"
    }
  }

  /// A folder's path as people write it, with `~` for the home folder.
  static func displayPath(_ url: URL) -> String {
    (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }
}

/// How an action the app is performing is going, for whoever asked to show.
public enum HealthAppActionProgress: Equatable, Sendable {
  /// The server is preparing the export.
  case preparing
  /// The share of the archive downloaded, from 0 to 1.
  case downloading(Double)
}

/// What the app answers once it has performed an action.
public enum HealthAppActionResult: Equatable, Sendable {
  /// Done, with nothing to say: the page is open.
  case done
  /// Caught up with the server, as of the end of the pull.
  case synced(at: Date)
  /// Still pulling after `HealthAppActions.syncWait`: the app finishes in the background.
  case stillSyncing
  /// The archive, saved in the folder asked for.
  case exported(URL)
}

/// Why the app couldn't perform an action.
public enum HealthAppActionError: Error, Equatable, LocalizedError,
  CustomLocalizedStringResourceConvertible
{
  /// Signed out, or not signed in within `HealthAppActions.signInWait` of launch.
  case signedOut
  /// The pull failed, with the sync's error message (`SyncStatus.failed`).
  case syncFailed(String)
  /// The pull failed because the Mac has no connection (`SyncStatus.offline`).
  case offline
  /// An export is running already, from Settings or another action.
  case exportRunning
  /// The export failed, with what Settings says (`DataExportError.message`).
  case exportFailed(String)
  /// Cancelled in Settings while it ran.
  case exportCancelled
  /// The intent ended (the system stopped waiting) while the app kept exporting, into the
  /// folder of this name.
  case stillExporting(folderName: String)
  /// There's no folder at this path (written with `~`).
  case folderNotFound(String)
  /// The folder at this path (written with `~`) can't be written to.
  case folderNotWritable(String)

  public var errorDescription: String? {
    switch self {
    case .signedOut: "Sign in to lil health first."
    case .syncFailed(let message): "Couldn't sync: \(message)"
    case .offline: "Couldn't sync: this Mac is offline."
    case .exportRunning: "An export is already running."
    case .exportFailed(let message): message
    case .exportCancelled: "The export was cancelled in lil health."
    case .stillExporting(let folderName):
      "lil health is still exporting. It'll be saved to \(folderName)."
    case .folderNotFound(let path): "There's no folder at \(path)."
    case .folderNotWritable(let path):
      "lil health can't save to \(path). Check that the folder can be written to, and that lil health may use it, in System Settings › Privacy & Security › Files & Folders."
    }
  }

  public var localizedStringResource: LocalizedStringResource {
    "\(errorDescription ?? "")"
  }
}

/// An action for the app to perform, with how to answer whoever asked.
public struct HealthAppActionRequest: Sendable {
  public let action: HealthAppAction
  private let progress: @Sendable (HealthAppActionProgress) -> Void
  private let reply: @Sendable (Result<HealthAppActionResult, any Error>) -> Void

  public init(
    action: HealthAppAction,
    progress: @escaping @Sendable (HealthAppActionProgress) -> Void = { _ in },
    reply: @escaping @Sendable (Result<HealthAppActionResult, any Error>) -> Void
  ) {
    self.action = action
    self.progress = progress
    self.reply = reply
  }

  /// Tells whoever asked how it's going, until it's answered.
  public func report(_ progress: HealthAppActionProgress) {
    self.progress(progress)
  }

  /// Answers whoever asked. Only the first answer counts.
  public func finish(_ result: Result<HealthAppActionResult, any Error>) {
    reply(result)
  }
}

/// How app actions reach the running app's store (851-2892). Whoever asks (an intent) calls
/// `perform`; `AppFeature` reads `requests` while signed in and answers each one.
public struct HealthAppActions: Sendable {
  public typealias Progress = @Sendable (HealthAppActionProgress) -> Void

  /// Asks the app to perform an action, and waits for its answer, hearing how it's going
  /// (`progress`) meanwhile. Fails with `HealthAppActionError.signedOut` when the app is signed
  /// out, or isn't signed in within `signInWait` of launch (an intent may launch it).
  public var perform:
    @Sendable (_ action: HealthAppAction, _ progress: @escaping Progress) async throws ->
      HealthAppActionResult
  /// The actions asked for, for the app to perform while signed in. When the stream ends (on
  /// signing out), what it hadn't answered fails.
  public var requests: @Sendable () -> AsyncStream<HealthAppActionRequest>

  public init(
    perform:
      @escaping @Sendable (_ action: HealthAppAction, _ progress: @escaping Progress) async throws
      ->
      HealthAppActionResult,
    requests: @escaping @Sendable () -> AsyncStream<HealthAppActionRequest>
  ) {
    self.perform = perform
    self.requests = requests
  }

  /// How long after launch an action waits for the app to be signed in: an intent that launches
  /// the app arrives before the stored session has been checked.
  public static let signInWait: Duration = .seconds(10)

  /// How long Sync waits for its pull to end before answering that it's still syncing.
  public static let syncWait: Duration = .seconds(60)

  /// The app's: created when the app launches (`LilHealthApp` prepares it), which starts
  /// `signInWait`.
  public static let live = Self(channel: HealthAppActionChannel(signInWait: signInWait))

  init(channel: HealthAppActionChannel) {
    self.init(
      perform: { try await channel.perform($0, progress: $1) }, requests: { channel.requests() })
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
    // A previous server's stream isn't finished here: what it has buffered, it still performs and
    // answers. Once its reader stops, what it didn't answer fails (`serverEnded`).
    state.withLock { $0.server = (id, continuation) }
    continuation.onTermination = { [self] _ in serverEnded(id) }
    return stream
  }

  /// How many actions are waiting for an answer.
  var pendingCount: Int { state.withLock { $0.pending.count } }

  func perform(
    _ action: HealthAppAction, progress: @escaping HealthAppActions.Progress = { _ in }
  ) async throws -> HealthAppActionResult {
    while true {
      if let result = try await send(action, progress: progress) { return result }
      guard ContinuousClock.now < deadline else { throw HealthAppActionError.signedOut }
      try await Task.sleep(for: pollInterval)
    }
  }

  /// Hands the action to the server and waits for its answer. `nil` if there's no server.
  private func send(
    _ action: HealthAppAction, progress: @escaping HealthAppActions.Progress
  ) async throws -> HealthAppActionResult? {
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
        let request = HealthAppActionRequest(action: action) { [self] update in
          // Only while it's waiting: not once it's answered or cancelled.
          if state.withLock({ $0.pending[id] != nil }) { progress(update) }
        } reply: { [self] result in
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
