public import ComposableArchitecture
import Foundation
public import HealthAgentAccess

/// The Settings window's Agents pane (851-2840): whether the `lil-health` command and its MCP
/// server may read the Mac's Health data, off until the person turns it on, and the log of what
/// they read, which the command writes. While the pane is open the log is read again every few
/// seconds, so new queries show up.
@Reducer
public struct AgentAccessFeature {
  @ObservableState
  public struct State: Equatable {
    /// The latest queries, newest first.
    public var entries: [AgentAccessEntry]
    /// Why the setting or the log couldn't be read or saved.
    public var failure: String?
    public var isEnabled: Bool
    /// Until the setting has been read.
    public var isLoading: Bool

    public init(
      entries: [AgentAccessEntry] = [], failure: String? = nil, isEnabled: Bool = false,
      isLoading: Bool = true
    ) {
      self.entries = entries
      self.failure = failure
      self.isEnabled = isEnabled
      self.isLoading = isLoading
    }
  }

  public enum Action {
    case accessToggled(Bool)
    case entriesLoaded([AgentAccessEntry])
    case failed(String)
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

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .accessToggled(let isEnabled):
        return setEnabled(isEnabled, state: &state)

      case .entriesLoaded(let entries):
        state.entries = entries
        return .none

      case .failed(let message):
        state.failure = message
        return .none

      case .settingLoaded(let isEnabled):
        state.isEnabled = isEnabled
        state.isLoading = false
        return .none

      case .task:
        // Only the app changes the setting, so it's read once. The command writes the log.
        return .run { [agentAccess, clock] send in
          do {
            await send(.settingLoaded(try await agentAccess.isEnabled()))
          } catch {
            await send(.failed(Self.message(error)))
          }
          while !Task.isCancelled {
            do {
              await send(.entriesLoaded(try await agentAccess.entries(Self.entryLimit)))
            } catch {
              await send(.failed(Self.message(error)))
            }
            try await clock.sleep(for: Self.refreshInterval)
          }
        }

      case .turnOffButtonTapped:
        return setEnabled(false, state: &state)
      }
    }
  }

  private func setEnabled(_ isEnabled: Bool, state: inout State) -> Effect<Action> {
    let wasEnabled = state.isEnabled
    state.isEnabled = isEnabled
    state.failure = nil
    return .run { [agentAccess] send in
      do {
        try await agentAccess.setEnabled(isEnabled)
      } catch {
        await send(.settingLoaded(wasEnabled))
        await send(.failed(Self.message(error)))
      }
    }
  }

  private static func message(_ error: any Error) -> String {
    "lil health couldn't read or save this setting: \(error.localizedDescription)"
  }
}

/// The agent access setting and log (`AgentAccessStore`), for the app.
struct AgentAccessClient: Sendable {
  var isEnabled: @Sendable () async throws -> Bool
  var setEnabled: @Sendable (Bool) async throws -> Void
  /// The latest entries, newest first, at most `limit`.
  var entries: @Sendable (_ limit: Int) async throws -> [AgentAccessEntry]
  /// Turns access off and empties the log, when the account signs out.
  var reset: @Sendable () async throws -> Void
}

extension AgentAccessClient: DependencyKey {
  static var liveValue: Self {
    let store = AgentAccessStore()
    return Self(
      isEnabled: { try store.isEnabled() },
      setEnabled: { try store.setEnabled($0) },
      entries: { try store.entries(limit: $0) },
      reset: { try store.reset() }
    )
  }

  static var testValue: Self {
    Self(
      isEnabled: unimplemented("AgentAccessClient.isEnabled"),
      setEnabled: unimplemented("AgentAccessClient.setEnabled"),
      entries: unimplemented("AgentAccessClient.entries"),
      reset: unimplemented("AgentAccessClient.reset")
    )
  }
}

extension DependencyValues {
  var agentAccess: AgentAccessClient {
    get { self[AgentAccessClient.self] }
    set { self[AgentAccessClient.self] = newValue }
  }
}
