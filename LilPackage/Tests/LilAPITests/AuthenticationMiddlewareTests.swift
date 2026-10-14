import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import LilAPI
import OpenAPIRuntime
import Testing

struct AuthenticationMiddlewareTests {
  @Test
  func addsTheAccessToken() async throws {
    let api = Client.authenticatedMock { request, _ in
      #expect(request.headerFields[.authorization] == "Bearer a1")
      return me
    }
    let output = try await withDependencies {
      $0.apiAuthentication = APIAuthentication(
        accessToken: { "a1" }, rejected: { _ in Issue.record("Unexpected rejection") })
    } operation: {
      try await api.me()
    }
    #expect(try output.ok.body.json.id == "u1")
  }

  @Test
  func signedOutSendsNoToken() async throws {
    let api = Client.authenticatedMock { request, _ in
      #expect(request.headerFields[.authorization] == nil)
      return unauthorized
    }
    let output = try await api.me()
    #expect(throws: Never.self) { try output.unauthorized }
  }

  @Test
  func signingInAndRefreshingDontAskForAToken() async throws {
    let api = Client.authenticatedMock { request, _ in
      #expect(request.headerFields[.authorization] == nil)
      return (HTTPResponse(status: .internalServerError), nil)
    }
    try await withDependencies {
      $0.apiAuthentication = APIAuthentication(
        accessToken: {
          Issue.record("Unexpected token request")
          return "a1"
        },
        rejected: { _ in })
    } operation: {
      _ = try await api.authRefresh(body: .json(.init(refreshToken: "r1")))
      _ = try await api.status()
    }
  }

  @Test
  func retriesOnceWithARefreshedToken() async throws {
    let token = LockIsolated("a1")
    let sent = LockIsolated<[String?]>([])
    let api = Client.authenticatedMock { request, _ in
      sent.withValue { $0.append(request.headerFields[.authorization]) }
      return request.headerFields[.authorization] == "Bearer a2" ? me : unauthorized
    }
    let output = try await withDependencies {
      $0.apiAuthentication = APIAuthentication(
        accessToken: { token.value },
        rejected: { rejected in
          #expect(rejected == "a1")
          token.setValue("a2")
        })
    } operation: {
      try await api.me()
    }
    #expect(try output.ok.body.json.id == "u1")
    #expect(sent.value == ["Bearer a1", "Bearer a2"])
  }

  @Test
  func aFailedRefreshAnswersWithThe401() async throws {
    struct Offline: Error {}
    let tokens = LockIsolated(0)
    let api = Client.authenticatedMock { _, _ in unauthorized }
    let output = try await withDependencies {
      $0.apiAuthentication = APIAuthentication(
        accessToken: {
          tokens.withValue { $0 += 1 }
          if tokens.value > 1 { throw Offline() }
          return "a1"
        },
        rejected: { _ in })
    } operation: {
      try await api.me()
    }
    #expect(throws: Never.self) { try output.unauthorized }
  }

  @Test
  func givesUpWhenTheTokenDoesntChange() async throws {
    let requests = LockIsolated(0)
    let api = Client.authenticatedMock { _, _ in
      requests.withValue { $0 += 1 }
      return unauthorized
    }
    let output = try await withDependencies {
      $0.apiAuthentication = APIAuthentication(accessToken: { "a1" }, rejected: { _ in })
    } operation: {
      try await api.me()
    }
    #expect(throws: Never.self) { try output.unauthorized }
    #expect(requests.value == 1)
  }
}

private let me = (
  HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
  HTTPBody(#"{"id":"u1","identities":[]}"#) as HTTPBody?
)

private let unauthorized = (
  HTTPResponse(status: .unauthorized, headerFields: [.contentType: "application/json"]),
  HTTPBody(#"{"_tag":"Unauthorized","message":"Sign in again"}"#) as HTTPBody?
)
