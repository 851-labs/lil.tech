public import Dependencies
public import Foundation
import IssueReporting
import LilAPI

/// An agent connected to the account through an app's remote MCP server (851-2852): a grant the
/// person allowed, until they revoke it.
public struct ConnectedAgent: Equatable, Identifiable, Sendable {
  public var id: String
  /// The name it registered with. Nil for an unnamed one.
  public var name: String?
  /// A verified client's domain (its metadata document's). Nil for an unverified one, which
  /// registered itself (DCR) and could be called anything.
  public var domain: String?
  /// Which app's data it reads: "health".
  public var app: String?
  public var connectedAt: Date
  /// When it last read anything: its connection time until it first does, and recorded at most
  /// every few minutes.
  public var lastUsedAt: Date

  public init(
    id: String, name: String?, domain: String?, app: String?, connectedAt: Date, lastUsedAt: Date
  ) {
    self.id = id
    self.name = name
    self.domain = domain
    self.app = app
    self.connectedAt = connectedAt
    self.lastUsedAt = lastUsedAt
  }

  init(_ agent: Components.Schemas.ConnectedAgent) {
    self.init(
      id: agent.id, name: agent.name, domain: agent.domain, app: agent.app,
      connectedAt: Date(unixMilliseconds: agent.connectedAt),
      lastUsedAt: Date(unixMilliseconds: agent.lastUsedAt))
  }

  /// Whether its name is its own claim: no verified domain backs it.
  public var isUnverified: Bool { domain == nil }
}

/// A read a connected agent made, from the account's remote access log.
public struct RemoteAgentAccess: Equatable, Identifiable, Sendable {
  public var id: Int
  public var at: Date
  public var agentID: String
  /// The agent's name when it read, kept after it's revoked. A client ID for an unnamed one.
  public var agentName: String
  /// The MCP tool it called, e.g. `get_metric`.
  public var tool: String
  /// The data types it asked for, if the tool takes any.
  public var types: [String]
  /// The range it asked for (`W`), and the day it ended on, if any.
  public var range: String?
  public var date: String?
  /// How it went (`ok`, or why not), and how many rows it read.
  public var outcome: String
  public var rows: Int

  public init(
    id: Int, at: Date, agentID: String, agentName: String, tool: String, types: [String] = [],
    range: String? = nil, date: String? = nil, outcome: String, rows: Int
  ) {
    self.id = id
    self.at = at
    self.agentID = agentID
    self.agentName = agentName
    self.tool = tool
    self.types = types
    self.range = range
    self.date = date
    self.outcome = outcome
    self.rows = rows
  }

  init(_ entry: Components.Schemas.AgentAccessEntry) {
    self.init(
      id: entry.id, at: Date(unixMilliseconds: entry.at), agentID: entry.agentId,
      agentName: entry.agentName, tool: entry.tool, types: entry.types ?? [], range: entry.range,
      date: entry.date, outcome: entry.outcome, rows: entry.rows)
  }
}

/// A page of the remote access log, newest first, and where the next one starts.
public struct RemoteAgentAccessPage: Equatable, Sendable {
  public var entries: [RemoteAgentAccess]
  /// Pass as `before` for the next page. Nil on the last.
  public var nextBefore: Int?

  public init(entries: [RemoteAgentAccess], nextBefore: Int?) {
    self.entries = entries
    self.nextBefore = nextBefore
  }
}

/// Why something about connected agents didn't work, worded for settings.
public enum ConnectedAgentsError: Error, Equatable, Sendable {
  /// It isn't possible right now; try again later.
  case unavailable
  /// The session ended.
  case signedOut
  case failed(String)

  public var message: String {
    switch self {
    case .unavailable: "That isn't possible right now. Please try again later."
    case .signedOut: "Your session ended. Sign in again."
    case .failed(let reason): "That didn't work: \(reason)"
    }
  }
}

/// The agents connected to the account, what they read, and revoking them
/// (`/v1/me/agents`, `/v1/me/consents/agents/health`).
public struct ConnectedAgentsClient: Sendable {
  /// The connected agents, most recent first, every app's (filter on `app`).
  public var list: @Sendable () async throws(ConnectedAgentsError) -> [ConnectedAgent]
  /// Revokes one: it loses access at once. Revoking one already gone succeeds.
  public var revoke: @Sendable (_ id: String) async throws(ConnectedAgentsError) -> Void
  /// A page of what connected agents read, newest first, before the entry `before`.
  public var accessLog:
    @Sendable (_ before: Int?) async throws(ConnectedAgentsError) -> RemoteAgentAccessPage
  /// Withdraws lil health's agents consent and revokes every lil health agent (Turn Off Agent
  /// Access). Other apps' agents stay.
  public var turnOffHealthAgents: @Sendable () async throws(ConnectedAgentsError) -> Void

  public init(
    list: @escaping @Sendable () async throws(ConnectedAgentsError) -> [ConnectedAgent],
    revoke: @escaping @Sendable (_ id: String) async throws(ConnectedAgentsError) -> Void,
    accessLog:
      @escaping @Sendable (_ before: Int?) async throws(ConnectedAgentsError) ->
      RemoteAgentAccessPage,
    turnOffHealthAgents: @escaping @Sendable () async throws(ConnectedAgentsError) -> Void
  ) {
    self.list = list
    self.revoke = revoke
    self.accessLog = accessLog
    self.turnOffHealthAgents = turnOffHealthAgents
  }
}

extension ConnectedAgentsClient: DependencyKey {
  public static var liveValue: Self {
    @Dependency(\.api) var api
    /// Calls an endpoint, turning a failed request into ``ConnectedAgentsError``.
    @Sendable func call<Output>(
      _ request: @Sendable () async throws -> Output
    ) async throws(ConnectedAgentsError) -> Output {
      do {
        return try await request()
      } catch {
        throw .failed(error.localizedDescription)
      }
    }
    return Self(
      list: { () throws(ConnectedAgentsError) in
        switch try await call({ try await api.connectedAgents() }) {
        case .ok(let ok):
          guard let body = try? ok.body.json else { throw .failed("Unexpected response") }
          return body.agents.map(ConnectedAgent.init)
        case .unauthorized: throw .signedOut
        case .tooManyRequests: throw .unavailable
        case .undocumented(let statusCode, _): throw .failed("HTTP \(statusCode)")
        }
      },
      revoke: { id throws(ConnectedAgentsError) in
        switch try await call({ try await api.revokeAgent(path: .init(id: id)) }) {
        case .noContent: return
        case .unauthorized: throw .signedOut
        case .tooManyRequests: throw .unavailable
        case .undocumented(let statusCode, _): throw .failed("HTTP \(statusCode)")
        }
      },
      accessLog: { before throws(ConnectedAgentsError) in
        switch try await call({ try await api.agentAccessLog(query: .init(before: before)) }) {
        case .ok(let ok):
          guard let body = try? ok.body.json else { throw .failed("Unexpected response") }
          return RemoteAgentAccessPage(
            entries: body.entries.map(RemoteAgentAccess.init), nextBefore: body.nextBefore)
        case .unauthorized: throw .signedOut
        case .tooManyRequests, .serviceUnavailable: throw .unavailable
        case .undocumented(let statusCode, _): throw .failed("HTTP \(statusCode)")
        }
      },
      turnOffHealthAgents: { () throws(ConnectedAgentsError) in
        switch try await call({ try await api.withdrawHealthAgentsConsent() }) {
        case .noContent: return
        case .unauthorized: throw .signedOut
        case .tooManyRequests: throw .unavailable
        case .undocumented(let statusCode, _): throw .failed("HTTP \(statusCode)")
        }
      }
    )
  }

  public static var testValue: Self {
    Self(
      list: { () throws(ConnectedAgentsError) in
        reportIssue("Unimplemented: @Dependency(\\.connectedAgents).list")
        return []
      },
      revoke: { _ throws(ConnectedAgentsError) in
        reportIssue("Unimplemented: @Dependency(\\.connectedAgents).revoke")
      },
      accessLog: { _ throws(ConnectedAgentsError) in
        reportIssue("Unimplemented: @Dependency(\\.connectedAgents).accessLog")
        return RemoteAgentAccessPage(entries: [], nextBefore: nil)
      },
      turnOffHealthAgents: { () throws(ConnectedAgentsError) in
        reportIssue("Unimplemented: @Dependency(\\.connectedAgents).turnOffHealthAgents")
      }
    )
  }
}

extension DependencyValues {
  public var connectedAgents: ConnectedAgentsClient {
    get { self[ConnectedAgentsClient.self] }
    set { self[ConnectedAgentsClient.self] = newValue }
  }
}

extension Date {
  fileprivate init(unixMilliseconds: Int) {
    self.init(timeIntervalSince1970: TimeInterval(unixMilliseconds) / 1000)
  }
}
