import Foundation
import LilAPI
import OpenAPIRuntime
import Testing

struct OfflineTests {
  private func wrapped(_ error: any Error) -> ClientError {
    ClientError(
      operationID: "me", operationInput: (), causeDescription: "Transport threw an error.",
      underlyingError: error)
  }

  @Test
  func noConnectionIsOffline() {
    #expect(isOfflineError(URLError(.notConnectedToInternet)))
    #expect(isOfflineError(URLError(.networkConnectionLost)))
    // As the API client throws it, and twice wrapped when the token's refresh failed.
    #expect(isOfflineError(wrapped(URLError(.cannotFindHost))))
    #expect(isOfflineError(wrapped(wrapped(URLError(.notConnectedToInternet)))))
  }

  @Test
  func aSlowOrFailingServerIsntOffline() {
    #expect(!isOfflineError(URLError(.timedOut)))
    #expect(!isOfflineError(wrapped(URLError(.timedOut))))
    #expect(!isOfflineError(URLError(.badServerResponse)))
    #expect(!isOfflineError(CancellationError()))
  }
}
