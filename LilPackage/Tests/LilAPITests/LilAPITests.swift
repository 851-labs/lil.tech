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
  func toleratesFieldsAddedLater() async throws {
    let api = Client.mock { _, _ in
      (
        HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
        HTTPBody(#"{"environment":"prod","version":"1","region":"wnam"}"#)
      )
    }
    let status = try await api.status().ok.body.json
    #expect(status.environment == .prod)
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
    let preview = "https://lil-api-api-pr-57-x.851.workers.dev"
    let previewURL = URL(string: preview)!
    #expect(APIEnvironment.current(environment: [:], allowsOverride: true) == .staging)
    #expect(
      APIEnvironment.current(environment: ["LIL_API_URL": preview], allowsOverride: true)
        == .preview(previewURL)
    )
    #expect(
      APIEnvironment.current(
        environment: ["LIL_API_URL": "https://api.lil.tech/"], allowsOverride: true) == .prod
    )
  }

  @Test
  func deviceBuildsIgnoreTheOverride() {
    let env = ["LIL_API_URL": "https://api.staging.lil.tech"]
    #expect(APIEnvironment.current(environment: env, allowsOverride: false) == .prod)
  }

  @Test
  func normalizesPastedURLs() {
    let preview = URL(string: "https://lil-api-api-pr-57-x.851.workers.dev")!
    #expect(
      APIEnvironment(url: "https://lil-api-api-pr-57-x.851.workers.dev/v1/status")
        == .preview(preview))
    #expect(
      APIEnvironment(url: "https://lil-api-api-pr-57-x.851.workers.dev/") == .preview(preview))
    #expect(
      APIEnvironment(url: "http://localhost:8787")?.baseURL.absoluteString
        == "http://localhost:8787")
    #expect(APIEnvironment(url: "api.staging.lil.tech") == nil)
    #expect(APIEnvironment(url: "https://api.staging.lil.tech/v1/status") == .staging)
  }

  @Test
  func eachEnvironmentHasItsMCPServers() {
    #expect(
      APIEnvironment.prod.mcpURL(app: "health").absoluteString == "https://mcp.lil.tech/health")
    #expect(
      APIEnvironment.staging.mcpURL(app: "health").absoluteString
        == "https://mcp.staging.lil.tech/health")
    let preview = URL(string: "https://lil-api-api-pr-57-x.851.workers.dev")!
    #expect(
      APIEnvironment.preview(preview).mcpURL(app: "health").absoluteString
        == "https://lil-api-api-pr-57-x.851.workers.dev/health")
  }

  @Test
  func eachEnvironmentLinksItsAgentsHelpPage() {
    #expect(APIEnvironment.staging.siteURL.absoluteString == "https://staging.lil.tech")
    #expect(APIEnvironment.prod.agentsHelpURL.absoluteString == "https://lil.tech/agents")
    #expect(
      APIEnvironment.staging.agentsHelpURL.absoluteString == "https://staging.lil.tech/agents")
    let preview = URL(string: "https://lil-api-api-pr-57-x.851.workers.dev")!
    #expect(
      APIEnvironment.preview(preview).agentsHelpURL.absoluteString == "https://lil.tech/agents")
  }
}
