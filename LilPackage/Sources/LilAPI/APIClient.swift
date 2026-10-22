public import Dependencies
import Foundation
public import HTTPTypes
import IssueReporting
@_exported public import LilAPIGenerated
public import OpenAPIRuntime
import OpenAPIURLSession

extension DependencyValues {
  /// The `api.lil.tech` client, generated from `Services/api/openapi.json`.
  ///
  /// Tests get a client whose every request fails and reports an issue. Override it with
  /// ``Client/mock(_:)`` to answer requests.
  public var api: any APIProtocol {
    get { self[APIKey.self] }
    set { self[APIKey.self] = newValue }
  }
}

private enum APIKey: DependencyKey {
  static var liveValue: any APIProtocol {
    Client(
      serverURL: APIEnvironment.current().baseURL,
      transport: URLSessionTransport(),
      middlewares: [AuthenticationMiddleware()]
    )
  }
  static var testValue: any APIProtocol {
    Client(serverURL: APIEnvironment.staging.baseURL, transport: UnimplementedTransport())
  }
}

extension Client {
  /// A client whose requests are answered by `respond` instead of the network.
  public static func mock(
    _ respond:
      @escaping @Sendable (HTTPRequest, HTTPBody?) async throws -> (HTTPResponse, HTTPBody?)
  ) -> Self {
    Client(serverURL: APIEnvironment.staging.baseURL, transport: MockTransport(respond: respond))
  }

  /// Like ``mock(_:)``, but authenticated the way the live client is, from
  /// `@Dependency(\.apiAuthentication)`.
  public static func authenticatedMock(
    _ respond:
      @escaping @Sendable (HTTPRequest, HTTPBody?) async throws -> (HTTPResponse, HTTPBody?)
  ) -> Self {
    Client(
      serverURL: APIEnvironment.staging.baseURL,
      transport: MockTransport(respond: respond),
      middlewares: [AuthenticationMiddleware()]
    )
  }
}

struct MockTransport: ClientTransport {
  let respond: @Sendable (HTTPRequest, HTTPBody?) async throws -> (HTTPResponse, HTTPBody?)

  func send(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    try await respond(request, body)
  }
}

/// Fails every request and reports an issue, so tests must say which requests they expect.
struct UnimplementedTransport: ClientTransport {
  func send(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    reportIssue("Unimplemented: @Dependency(\\.api) received \(operationID)")
    throw UnimplementedRequest(operationID: operationID)
  }
}

struct UnimplementedRequest: Error {
  let operationID: String
}
