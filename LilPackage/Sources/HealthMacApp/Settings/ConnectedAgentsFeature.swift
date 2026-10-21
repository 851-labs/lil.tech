public import ComposableArchitecture
import Foundation
public import LilAuth

/// The Agents pane's remote agents (851-2853): those the person allowed to read lil health's data
/// through its MCP server (`mcp.lil.tech/health`), with when each connected and last read, revoking
/// one or all of them, and the log of what they read. Kept in the app's store, like the Account
/// pane's state, and read again each time the pane opens.
@Reducer
public struct ConnectedAgentsFeature {
  @ObservableState
  public struct State: Equatable {
    @Presents public var alert: AlertState<Action.Alert>?
    public var agents: Agents
    /// Why revoking or turning off didn't work.
    public var failure: String?
    /// The remote access log, newest first, as far as it's been read.
    public var log: [RemoteAgentAccess]
    /// Why the log couldn't be read.
    public var logFailure: String?
    public var isLoadingLog: Bool
    /// Where the log's next page starts. Nil once it's all read.
    public var logNextBefore: Int?
    /// Agents being revoked, which show progress until it's done.
    public var revoking: Set<String>
    public var isTurningOff: Bool

    public init(
      agents: Agents = .loading, failure: String? = nil, log: [RemoteAgentAccess] = [],
      logFailure: String? = nil, isLoadingLog: Bool = false, logNextBefore: Int? = nil,
      revoking: Set<String> = [], isTurningOff: Bool = false
    ) {
      self.agents = agents
      self.failure = failure
      self.log = log
      self.logFailure = logFailure
      self.isLoadingLog = isLoadingLog
      self.logNextBefore = logNextBefore
      self.revoking = revoking
      self.isTurningOff = isTurningOff
    }

    public enum Agents: Equatable {
      case loading
      case loaded([ConnectedAgent])
      case failed(String)
    }

    /// The agents listed, once loaded.
    var loadedAgents: [ConnectedAgent] {
      if case .loaded(let agents) = agents { agents } else { [] }
    }
  }

  public enum Action {
    case agentsLoaded(Result<[ConnectedAgent], ConnectedAgentsError>)
    case alert(PresentationAction<Alert>)
    case appeared
    case loadMoreLogButtonTapped
    case logLoaded(Result<RemoteAgentAccessPage, ConnectedAgentsError>, isFirstPage: Bool)
    case retryButtonTapped
    case revokeButtonTapped(ConnectedAgent)
    case revoked(id: String, Result<Void, ConnectedAgentsError>)
    case turnOffButtonTapped
    case turnedOff(Result<Void, ConnectedAgentsError>)

    @CasePathable
    public enum Alert: Equatable {
      case confirmRevoke(id: String)
      case confirmTurnOff
    }
  }

  enum CancelID {
    /// Revoking and turning off, which signing out stops.
    case account
    /// Reading the list: a newer read, a revoke or turning off replaces it.
    case list
    /// Reading the log: reading its first page again replaces any page being read.
    case log
  }

  /// lil health's agents: the API lists every app's.
  static let app = "health"

  @Dependency(\.connectedAgents) var connectedAgents

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .agentsLoaded(.success(let agents)):
        state.agents = .loaded(agents.filter { $0.app == Self.app })
        return .none

      case .agentsLoaded(.failure(let error)):
        // A list already shown stays: this was a reload.
        if case .loaded = state.agents {
          state.failure = error.message
        } else {
          state.agents = .failed(error.message)
        }
        return .none

      case .alert(.presented(.confirmRevoke(let id))):
        state.revoking.insert(id)
        state.failure = nil
        return .run { [connectedAgents] send in
          await send(
            .revoked(
              id: id,
              await Self.result { () throws(ConnectedAgentsError) in
                try await connectedAgents.revoke(id)
              }))
        }
        .cancellable(id: CancelID.account)

      case .alert(.presented(.confirmTurnOff)):
        state.isTurningOff = true
        state.failure = nil
        return .run { [connectedAgents] send in
          await send(
            .turnedOff(
              await Self.result { () throws(ConnectedAgentsError) in
                try await connectedAgents.turnOffHealthAgents()
              }))
        }
        .cancellable(id: CancelID.account)

      case .alert:
        return .none

      case .appeared:
        // Past results go, and both are read again: an agent may have connected or read since.
        state.failure = nil
        state.logFailure = nil
        state.isLoadingLog = true
        return .merge(loadAgents(), loadLog(before: nil, isFirstPage: true))

      case .retryButtonTapped:
        state.agents = .loading
        return loadAgents()

      case .loadMoreLogButtonTapped:
        guard let before = state.logNextBefore, !state.isLoadingLog else { return .none }
        state.isLoadingLog = true
        state.logFailure = nil
        return loadLog(before: before, isFirstPage: false)

      case .logLoaded(.success(let page), let isFirstPage):
        state.isLoadingLog = false
        state.log = isFirstPage ? page.entries : state.log + page.entries
        state.logNextBefore = page.nextBefore
        return .none

      case .logLoaded(.failure(let error), _):
        state.isLoadingLog = false
        state.logFailure = error.message
        return .none

      case .revokeButtonTapped(let agent):
        state.alert = AlertState {
          TextState("Revoke \(Self.name(agent))?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmRevoke(id: agent.id)) {
            TextState("Revoke")
          }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState(
            "It loses access to your Health data at once. To use it again, connect it again.")
        }
        return .none

      case .revoked(let id, .success):
        state.revoking.remove(id)
        state.agents = .loaded(state.loadedAgents.filter { $0.id != id })
        // A list read before it would bring the agent back.
        return .cancel(id: CancelID.list)

      case .revoked(let id, .failure(let error)):
        state.revoking.remove(id)
        state.failure = error.message
        return .none

      case .turnOffButtonTapped:
        state.alert = AlertState {
          TextState("Turn Off Agent Access?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmTurnOff) {
            TextState("Turn Off")
          }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState(
            "Every agent connected to lil health loses access at once, and agents can't connect again until you allow one."
          )
        }
        return .none

      case .turnedOff(.success):
        state.isTurningOff = false
        state.agents = .loaded([])
        return .cancel(id: CancelID.list)

      case .turnedOff(.failure(let error)):
        state.isTurningOff = false
        state.failure = error.message
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  private func loadAgents() -> Effect<Action> {
    .run { [connectedAgents] send in
      await send(
        .agentsLoaded(
          await Self.result { () throws(ConnectedAgentsError) in
            try await connectedAgents.list()
          }))
    }
    .cancellable(id: CancelID.list, cancelInFlight: true)
  }

  private func loadLog(before: Int?, isFirstPage: Bool) -> Effect<Action> {
    .run { [connectedAgents] send in
      await send(
        .logLoaded(
          await Self.result { () throws(ConnectedAgentsError) in
            try await connectedAgents.accessLog(before)
          },
          isFirstPage: isFirstPage))
    }
    .cancellable(id: CancelID.log, cancelInFlight: true)
  }

  /// `body`'s value or its error.
  private static func result<Value>(
    _ body: () async throws(ConnectedAgentsError) -> Value
  ) async -> Result<Value, ConnectedAgentsError> {
    do {
      return .success(try await body())
    } catch {
      return .failure(error)
    }
  }

  /// What the pane calls an agent: its name, or "An unnamed agent".
  static func name(_ agent: ConnectedAgent) -> String {
    agent.name ?? "An unnamed agent"
  }

  /// Stops everything the pane started, when the account signs out.
  static func cancel<Other>() -> Effect<Other> {
    .merge(
      .cancel(id: CancelID.account), .cancel(id: CancelID.list), .cancel(id: CancelID.log))
  }
}
