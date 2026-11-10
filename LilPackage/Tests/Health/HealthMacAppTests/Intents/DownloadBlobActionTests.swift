import ComposableArchitecture
import CryptoKit
import DependenciesTestSupport
import Foundation
import HealthDatabase
import LilSync
import SQLiteData
import Testing

@testable import HealthMacApp

// The route tools' downloads (851-4164): `lil-health` asks the app for a route's points it hasn't
// downloaded, and reads them from the app's blob cache. Synthetic data only.
@Suite(.dependencies { $0.defaultDatabase = try! HealthDatabase.make() })
@MainActor
struct DownloadBlobActionTests {
  let directory = URL.temporaryDirectory.appending(
    path: "DownloadBlob-\(UUID().uuidString)", directoryHint: .isDirectory)
  let bytes = Data("synthetic route points".utf8)
  var sha256: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

  @Test(.timeLimit(.minutes(1)))
  func downloadsIntoTheCacheThenAnswers() async throws {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: { [bytes, directory] in
      $0.blobCache = BlobCache(
        directory: directory, maxBytes: 1 << 20,
        url: { URL(string: "https://blobs.lil.test/\($0)")! },
        download: SnapshotDownloader { _ in bytes })
    }
    let (request, answer) = makeRequest(.downloadBlob(sha256: sha256))
    await store.send(.appActionRequested(request))
    #expect(try await answer() == .done)
    #expect(try Data(contentsOf: directory.appending(path: sha256)) == bytes)
    await store.finish()
  }

  @Test(.timeLimit(.minutes(1)))
  func saysWhenItCantDownload() async throws {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: { [directory] in
      $0.blobCache = BlobCache(
        directory: directory, maxBytes: 1 << 20,
        url: { _ in throw URLError(.notConnectedToInternet) },
        download: .testValue)
    }
    let (request, answer) = makeRequest(.downloadBlob(sha256: sha256))
    await store.send(.appActionRequested(request))
    await #expect(throws: HealthAppActionError.downloadFailed) { try await answer() }
    await store.finish()
  }

  /// Not uploaded yet, or gone: said as the remote server says it.
  @Test(.timeLimit(.minutes(1)))
  func saysWhenThePointsArentOnTheServer() async throws {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: { [directory] in
      $0.blobCache = BlobCache(
        directory: directory, maxBytes: 1 << 20,
        url: { URL(string: "https://blobs.lil.test/\($0)")! },
        // Expired twice: the server has no such blob (`BlobCache.NotFound`).
        download: SnapshotDownloader { _ in throw SnapshotDownloader.Expired() })
    }
    let (request, answer) = makeRequest(.downloadBlob(sha256: sha256))
    await store.send(.appActionRequested(request))
    await #expect(throws: HealthAppActionError.blobNotFound) { try await answer() }
    await store.finish()
  }
}

private func makeRequest(
  _ action: HealthAppAction
) -> (HealthAppActionRequest, () async throws -> HealthAppActionResult) {
  let (answers, answer) = AsyncStream<Result<HealthAppActionResult, any Error>>.makeStream()
  let request = HealthAppActionRequest(action: action) { answer.yield($0) }
  return (
    request,
    {
      for await result in answers { return try result.get() }
      throw CancellationError()
    }
  )
}
