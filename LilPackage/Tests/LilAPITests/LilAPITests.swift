import Dependencies
import DependenciesTestSupport
import Foundation
import HTTPTypes
import LilAPI
import OpenAPIRuntime
import Testing

struct LilAPITests {
  @Test
  func decodesStatus() async throws {
    let api = Client.mock { request, _ in
      #expect(request.method == .get)
      #expect(request.path == "/v1/status")
      return (
        HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
        HTTPBody(#"{"environment":"staging","version":"9a585fc"}"#)
      )
    }

    let status = try await api.status().ok.body.json
    #expect(status.environment == .staging)
    #expect(status.version == "9a585fc")
  }

  @Test
  func unexpectedResponsesSurfaceAsUndocumented() async throws {
    let api = Client.mock { _, _ in (HTTPResponse(status: .serviceUnavailable), nil) }
    let output = try await api.status()
    guard case .undocumented(let statusCode, _) = output else {
      Issue.record("Expected an undocumented response, got \(output)")
      return
    }
    #expect(statusCode == 503)
  }

  @Test
  func testDependencyFailsRequests() async {
    @Dependency(\.api) var api
    await withKnownIssue {
      _ = try await api.status()
    }
  }

  @Test
  func environmentOverride() {
    let preview = URL(string: "https://lil-api-api-pr-57-x.851.workers.dev")!
    #expect(
      APIEnvironment.current(environment: ["LIL_API_URL": preview.absoluteString])
        == .preview(preview))
    #expect(APIEnvironment.current(environment: ["LIL_API_URL": "https://api.lil.tech"]) == .prod)
    #expect(APIEnvironment.prod.baseURL.absoluteString == "https://api.lil.tech")
  }
}
