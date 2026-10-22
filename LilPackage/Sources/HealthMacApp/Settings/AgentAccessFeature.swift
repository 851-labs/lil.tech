public import ComposableArchitecture
public import Foundation
public import HealthAgentAccess
import HealthDatabase
import LilCLIInstaller

/// The Settings window's Agents pane (851-2840): whether the `lil-health` command and its MCP
/// server may read the Mac's Health data, off until the person turns it on, and the log of what
/// they read, which the command writes. While the pane is open the log is read again every few
/// seconds, so new queries show up.
@Reducer
public struct AgentAccessFeature {
  @ObservableState
  public struct State: Equatable {
    /// Where `lil` is installed, for how to connect an agent. Nil if it isn't (or not yet known).
    public var commandLineTool: URL?
    /// The latest queries, newest first.
    public var entries: [AgentAccessEntry]
    /// Why the setting couldn't be read or saved.
    public var failure: String?
    public var isEnabled: Bool
    /// Until the setting has been read, or couldn't be.
    public var isLoading: Bool
    /// Why the log couldn't be read, until it can be again.
    public var logFailure: String?

    public init(
      commandLineTool: URL? = nil, entries: [AgentAccessEntry] = [], failure: String? = nil,
      isEnabled: Bool = false,
      isLoading: Bool = true, logFailure: String? = nil
    ) {
      self.commandLineTool = commandLineTool
      self.entries = entries
      self.failure = failure
      self.isEnabled = isEnabled
      self.isLoading = isLoading
      self.logFailure = logFailure
    }
  }

  public enum Action {
    case accessToggled(Bool)
    case commandLineToolLocated(URL?)
    case entriesLoaded([AgentAccessEntry])
    case logFailed(String)
    case settingFailed(String)
    case settingLoaded(Bool)
    case task
    case turnOffButtonTapped
  }

  /// How often an open pane reads the log again.
  static let refreshInterval: Duration = .seconds(2)
  /// How many of the log's entries the pane shows.
  static let entryLimit = 100

  @Dependency(\.agentAccess) var agentAccess
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .accessToggled(let isEnabled):
        return setEnabled(isEnabled, state: &state)

      case .commandLineToolLocated(let url):
        state.commandLineTool = url
        return .none

      case .entriesLoaded(let entries):
        state.entries = entries
        state.logFailure = nil
        return .none

      case .logFailed(let message):
        state.logFailure = message
        return .none

      case .settingFailed(let message):
        state.failure = message
        // The toggle works again: saving may well succeed.
        state.isLoading = false
        return .none

      case .settingLoaded(let isEnabled):
        state.isEnabled = isEnabled
        state.isLoading = false
        return .none

      case .task:
        // Only the app changes the setting, so it's read once. The command writes the log, and
        // `lil` may be installed while the pane is open, so both are read again.
        return .run { [agentAccess, clock] send in
          do {
            await send(.settingLoaded(try await agentAccess.isEnabled()))
          } catch {
            await send(.settingFailed(Self.settingMessage(error)))
          }
          var located: URL??
          while !Task.isCancelled {
            let tool = await agentAccess.commandLineTool()
            if located != .some(tool) {
              located = tool
              await send(.commandLineToolLocated(tool))
            }
            do {
              await send(.entriesLoaded(try await agentAccess.entries(Self.entryLimit)))
            } catch {
              await send(
                .logFailed(
                  "lil health couldn't read the access log: \(error.localizedDescription)"))
            }
            try await clock.sleep(for: Self.refreshInterval)
          }
        }

      case .turnOffButtonTapped:
        return setEnabled(false, state: &state)
      }
    }
  }

  /// Saves the setting, dated now: saves that finish out of order end as the person left it
  /// (`AgentAccessStore.setEnabled(_:at:)`). One that fails shows what's saved instead.
  private func setEnabled(_ isEnabled: Bool, state: inout State) -> Effect<Action> {
    state.isEnabled = isEnabled
    state.failure = nil
    return .run { [agentAccess, now] send in
      do {
        try await agentAccess.setEnabled(isEnabled, now)
      } catch {
        await send(.settingFailed(Self.settingMessage(error)))
        if let saved = try? await agentAccess.isEnabled() {
          await send(.settingLoaded(saved))
        }
      }
    }
  }

  private static func settingMessage(_ error: any Error) -> String {
    "lil health couldn't read or save this setting: \(error.localizedDescription)"
  }
}

/// The agent access setting and log (`AgentAccessStore`), for the app.
struct AgentAccessClient: Sendable {
  var isEnabled: @Sendable () async throws -> Bool
  /// Saves the setting as the person changed it at `date`.
  var setEnabled: @Sendable (_ isEnabled: Bool, _ date: Date) async throws -> Void
  /// The latest entries, newest first, at most `limit`.
  var entries: @Sendable (_ limit: Int) async throws -> [AgentAccessEntry]
  /// Turns access off and empties the log, when the account signs out.
  var reset: @Sendable () async throws -> Void
  /// Before each app action (851-2892): throws `AgentAccessError.off` while access is off,
  /// otherwise logs the action, as the command does before each query.
  var authorize: @Sendable (_ command: String, _ process: String) async throws -> Void
  /// Where `lil` is installed, for how to connect an agent.
  var commandLineTool: @Sendable () async -> URL?
  /// When to look for the command line's requests (851-2895): at once, then each time a command
  /// signals (`AgentActionSignal`).
  var actionsRequested: @Sendable () -> AsyncStream<Void>
  /// Claims the command line's requests waiting for an app (`AgentAccessStore.claimActions`).
  var claimActions: @Sendable () async throws -> [AgentActionRequest]
  /// Writes how the app answered a request.
  var finishAction:
    @Sendable (_ id: AgentActionRequest.ID, _ outcome: AgentActionOutcome) async throws -> Void
}

extension AgentAccessClient: DependencyKey {
  static var liveValue: Self {
    live(AgentAccessStore(directory: HealthDatabase.macDirectory))
  }

  /// The setting and log in `store`'s file: the app's, or a test's temporary one.
  static func live(_ store: AgentAccessStore) -> Self {
    Self(
      isEnabled: { try store.isEnabled() },
      setEnabled: { try store.setEnabled($0, at: $1) },
      entries: { try store.entries(limit: $0) },
      reset: { try store.reset() },
      authorize: { try store.authorize(command: $0, process: $1) },
      commandLineTool: { CommandLineToolInstaller.installedLocation() },
      actionsRequested: { AgentActionSignal.signals() },
      claimActions: { try store.claimActions() },
      finishAction: { try store.finish(id: $0, outcome: $1) }
    )
  }

  static var testValue: Self {
    Self(
      isEnabled: unimplemented("AgentAccessClient.isEnabled"),
      setEnabled: unimplemented("AgentAccessClient.setEnabled"),
      entries: unimplemented("AgentAccessClient.entries"),
      reset: unimplemented("AgentAccessClient.reset"),
      authorize: unimplemented("AgentAccessClient.authorize"),
      commandLineTool: unimplemented("AgentAccessClient.commandLineTool", placeholder: nil),
      // Nothing asks unless a test does, as with `HealthAppActions.requests`.
      actionsRequested: { AsyncStream { $0.finish() } },
      claimActions: unimplemented("AgentAccessClient.claimActions", placeholder: []),
      finishAction: unimplemented("AgentAccessClient.finishAction")
    )
  }
}

extension DependencyValues {
  var agentAccess: AgentAccessClient {
    get { self[AgentAccessClient.self] }
    set { self[AgentAccessClient.self] = newValue }
  }
}
