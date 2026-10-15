import Dependencies
import Foundation
import LilAPI
import Testing

@testable import HealthUpload

struct BackgroundUploadsTests {
  let base = URL(string: "https://api.example.test")!
  let id = "6f1c2a40-0000-4000-8000-0000000000b1"

  /// Tokens handed out, and the ones rejected.
  final class Tokens: Sendable {
    let current = LockIsolated<String?>("a1")
    let rejected = LockIsolated<[String]>([])
    var authentication: APIAuthentication {
      APIAuthentication(
        accessToken: { self.current.value },
        rejected: { token in
          self.rejected.withValue { $0.append(token) }
          self.current.setValue("a2")
        })
    }
  }

  @Test
  func sendsTheFileWithTheToken() async throws {
    let tokens = Tokens()
    let uploader = HealthBatchUploader.uploading(to: base) { [id] request, file in
      #expect(request.url?.absoluteString == "https://api.example.test/v1/health/batches/\(id)")
      #expect(request.httpMethod == "PUT")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a1")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/gzip")
      let body = try Data(contentsOf: file)
      #expect(body == Data([1, 2, 3]))
      return 202
    }
    try await withDependencies {
      $0.apiAuthentication = tokens.authentication
    } operation: {
      try await uploader.upload(id, Data([1, 2, 3]))
    }
    #expect(tokens.rejected.value.isEmpty)
  }

  @Test
  func anExpiredTokenIsRefreshedOnce() async throws {
    let tokens = Tokens()
    let sent = LockIsolated<[String?]>([])
    let uploader = HealthBatchUploader.uploading(to: base) { request, _ in
      sent.withValue { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
      return request.value(forHTTPHeaderField: "Authorization") == "Bearer a2" ? 202 : 401
    }
    try await withDependencies {
      $0.apiAuthentication = tokens.authentication
    } operation: {
      try await uploader.upload(id, Data([1]))
    }
    #expect(sent.value == ["Bearer a1", "Bearer a2"])
    #expect(tokens.rejected.value == ["a1"])
  }

  @Test
  func otherAnswersFail() async throws {
    for (statuses, expected) in [([401, 401], 401), ([503], 503)] {
      let answers = LockIsolated(statuses)
      let uploader = HealthBatchUploader.uploading(to: base) { _, _ in
        answers.withValue { $0.removeFirst() }
      }
      await withDependencies {
        $0.apiAuthentication = Tokens().authentication
      } operation: {
        await #expect(throws: HealthBatchUploader.Rejected(statusCode: expected)) {
          try await uploader.upload(id, Data([1]))
        }
      }
    }
  }

  @Test
  func signedOutDoesntUpload() async {
    let uploader = HealthBatchUploader.uploading(to: base) { _, _ in
      Issue.record("Unexpected upload")
      return 202
    }
    await withDependencies {
      $0.apiAuthentication = .signedOut
    } operation: {
      await #expect(throws: HealthBatchUploader.Rejected(statusCode: 401)) {
        try await uploader.upload(id, Data([1]))
      }
    }
  }
}
