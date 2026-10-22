import Dependencies
import Foundation
import HTTPTypes
import LilAPI
import OpenAPIRuntime
import Testing

@testable import LilAuth

// Synthetic data only (AGENTS.md).
struct DataExportClientTests {
  private func client(_ status: HTTPResponse.Status, _ json: String?) -> DataExportClient {
    withDependencies {
      $0.api = Client.mock { _, _ in
        (
          HTTPResponse(status: status, headerFields: [.contentType: "application/json"]),
          json.map { HTTPBody($0) }
        )
      }
    } operation: {
      DataExportClient.liveValue
    }
  }

  @Test
  func aReadyExportHasItsURL() async throws {
    let exports = client(
      .ok,
      #"{"requestedAt":1000,"ready":true,"url":"https://api.lil.tech/v1/exports/download?token=t","urlExpiresAt":2000}"#
    )
    #expect(
      try await exports.request()
        == DataExport(
          requestedAt: Date(timeIntervalSince1970: 1),
          url: URL(string: "https://api.lil.tech/v1/exports/download?token=t")))
  }

  @Test
  func anExportBeingPreparedHasNone() async throws {
    let exports = client(.ok, #"{"requestedAt":1000,"ready":false,"url":null,"urlExpiresAt":null}"#)
    #expect(try await exports.latest()?.url == nil)
  }

  @Test
  func noExportYet() async throws {
    let exports = client(.notFound, #"{"_tag":"DataExportNotFound","message":"none"}"#)
    #expect(try await exports.latest() == nil)
  }

  @Test
  func anUnavailableStoreIsUnavailable() async {
    let exports = client(.serviceUnavailable, #"{"_tag":"UserStoreUnavailable","message":"x"}"#)
    await #expect(throws: DataExportError.unavailable) {
      try await exports.request()
    }
  }
}
