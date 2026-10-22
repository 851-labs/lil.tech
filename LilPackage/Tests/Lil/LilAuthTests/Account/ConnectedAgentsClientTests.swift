import Dependencies
import Foundation
import HTTPTypes
import LilAPI
import OpenAPIRuntime
import Testing

@testable import LilAuth

// Synthetic data only (AGENTS.md).
struct ConnectedAgentsClientTests {
  @Test
  func readsWhenEachAgentFirstReadAndItsApps() async throws {
    // One that read a second after connecting, and one that hasn't read anything.
    let agents = """
      {"agents":[
        {"id":"agr_1","name":"Claude","domain":"claude.ai","redirectHost":"claude.ai",
         "resource":"https://mcp.lil.tech/health","app":"health","apps":["health"],
         "connectedAt":1760900000000,"lastUsedAt":1760900001000,"firstUsedAt":1760900001000},
        {"id":"agr_2","name":null,"domain":null,"redirectHost":"localhost",
         "resource":"https://mcp.lil.tech/health","app":"health","apps":["health"],
         "connectedAt":1760800000000,"lastUsedAt":1760800000000,"firstUsedAt":null},
        {"id":"agr_3","name":"ChatGPT","domain":"chatgpt.com","redirectHost":"chatgpt.com",
         "resource":"https://mcp.lil.tech","app":null,"apps":["health","mail"],
         "connectedAt":1760700000000,"lastUsedAt":1760700000000,"firstUsedAt":null}
      ]}
      """
    let client = withDependencies {
      $0.api = Client.mock { request, _ in
        #expect(request.path == "/v1/me/agents")
        return (
          HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
          HTTPBody(agents)
        )
      }
    } operation: {
      ConnectedAgentsClient.liveValue
    }
    let listed = try await client.list()
    #expect(
      listed.map(\.firstUsedAt) == [Date(timeIntervalSince1970: 1_760_900_001), nil, nil])
    #expect(listed.map(\.isUnused) == [false, true, true])
    // A combined agent (851-2902) names every app it reads.
    #expect(listed.map(\.apps) == [["health"], ["health"], ["health", "mail"]])
    #expect(listed.map(\.isCombined) == [false, false, true])
  }
}
