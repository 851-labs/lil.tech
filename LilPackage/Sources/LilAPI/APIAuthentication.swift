public import Dependencies
import Foundation
import HTTPTypes
import LilAPIGenerated
import OpenAPIRuntime

extension DependencyValues {
  /// Where `@Dependency(\.api)` gets access tokens. Signed out by default; `LilAuth` provides a
  /// signed-in one.
  public var apiAuthentication: APIAuthentication {
    get { self[APIAuthentication.self] }
    set { self[APIAuthentication.self] = newValue }
  }
}

/// Access tokens for API requests.
public struct APIAuthentication: Sendable {
  /// A current access token, refreshed first if it's about to expire, or `nil` when signed out.
  public var accessToken: @Sendable () async throws -> String?
  /// The server rejected `token` (a 401). The next `accessToken()` refreshes it.
  public var rejected: @Sendable (_ token: String) async -> Void

  public init(
    accessToken: @escaping @Sendable () async throws -> String?,
    rejected: @escaping @Sendable (_ token: String) async -> Void
  ) {
    self.accessToken = accessToken
    self.rejected = rejected
  }

  public static let signedOut = Self(accessToken: { nil }, rejected: { _ in })
}

extension APIAuthentication: DependencyKey {
  public static let liveValue = Self.signedOut
  public static let testValue = Self.signedOut
}

/// Adds `Authorization: Bearer` to requests, from `@Dependency(\.apiAuthentication)`. A request
/// the server rejects with 401 is sent again once with a refreshed token, if its body can be sent
/// twice.
struct AuthenticationMiddleware: ClientMiddleware {
  /// Operations that don't take an access token.
  static let unauthenticated: Set<String> = [
    Operations.Status.id, Operations.AuthRefresh.id, Operations.AuthApple.id,
    Operations.AuthGoogle.id,
  ]

  @concurrent func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next:
      @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (
        HTTPResponse, HTTPBody?
      )
  ) async throws -> (HTTPResponse, HTTPBody?) {
    guard !Self.unauthenticated.contains(operationID) else {
      return try await next(request, body, baseURL)
    }
    @Dependency(\.apiAuthentication) var authentication
    guard let token = try await authentication.accessToken() else {
      return try await next(request, body, baseURL)
    }
    var authorized = request
    authorized.headerFields[.authorization] = "Bearer \(token)"
    let (response, responseBody) = try await next(authorized, body, baseURL)
    guard response.status == .unauthorized, body?.iterationBehavior ?? .multiple == .multiple
    else { return (response, responseBody) }

    await authentication.rejected(token)
    // If refreshing fails too, the caller gets the 401 it would have.
    guard let fresh = try? await authentication.accessToken(), fresh != token else {
      return (response, responseBody)
    }
    authorized.headerFields[.authorization] = "Bearer \(fresh)"
    return try await next(authorized, body, baseURL)
  }
}
