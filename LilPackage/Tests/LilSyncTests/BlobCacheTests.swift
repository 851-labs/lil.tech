import CryptoKit
import Dependencies
import Foundation
import LilAPI
import Testing

@testable import LilSync

/// A fake server: synthetic blobs by SHA-256, and counts of what was asked for.
private final class FakeBlobs: Sendable {
  let blobs: [String: Data]
  let urlRequests = LockIsolated(0)
  let downloads = LockIsolated(0)
  /// URLs that answer as expired, once each.
  let expiring = LockIsolated<Set<URL>>([])
  /// A pause in each download, so concurrent requests overlap.
  let delay: Duration

  init(_ blobs: [Data], delay: Duration = .zero) {
    self.blobs = Dictionary(uniqueKeysWithValues: blobs.map { (LilSyncEngine.sha256Hex($0), $0) })
    self.delay = delay
  }

  func cache(in directory: URL, maxBytes: Int = 1 << 20) -> BlobCache {
    BlobCache(
      directory: directory, maxBytes: maxBytes,
      url: { [self] sha256 in
        let request = urlRequests.withValue {
          $0 += 1
          return $0
        }
        guard blobs[sha256] != nil else { throw BlobCache.NotFound(sha256: sha256) }
        return URL(
          string: "https://api.lil.tech/v1/health/blob-downloads?token=\(sha256)-\(request)")!
      },
      download: SnapshotDownloader { [self] url in
        downloads.withValue { $0 += 1 }
        try await Task.sleep(for: delay)
        if expiring.withValue({ $0.remove(url) != nil }) { throw SnapshotDownloader.Expired() }
        let sha256 = String(url.query!.dropFirst("token=".count).prefix(64))
        return blobs[sha256]!
      })
  }
}

private func temporaryDirectory() -> URL {
  URL.temporaryDirectory.appending(path: "BlobCacheTests-\(UUID().uuidString)")
}

struct BlobCacheTests {
  // Synthetic payloads (AGENTS.md).
  let first = Data(repeating: 1, count: 400)
  let second = Data(repeating: 2, count: 400)

  /// A Release build keeps sync's caches where they always were, `<bundle ID>/LilSync` in
  /// Caches, and a Debug build a folder per server, prod's included (851-2977).
  @Test
  func cachesAreKeptPerServerInDevBuildsOnly() {
    #expect(
      LilSyncEngine.cachesDirectory(
        for: .prod, allowsOverride: false, bundleIdentifier: "tech.lil.health")
        == URL.cachesDirectory.appending(
          path: "tech.lil.health/LilSync", directoryHint: .isDirectory))
    let caches = URL(filePath: "/home/Library/Caches/")
    func path(_ environment: APIEnvironment, allowsOverride: Bool) -> String {
      LilSyncEngine.cachesDirectory(
        for: environment, allowsOverride: allowsOverride, caches: caches,
        bundleIdentifier: "tech.lil.health"
      )
      .path(percentEncoded: false)
    }
    #expect(path(.prod, allowsOverride: false) == "/home/Library/Caches/tech.lil.health/LilSync/")
    #expect(
      path(.prod, allowsOverride: true)
        == "/home/Library/Caches/tech.lil.health/Servers/api.lil.tech/LilSync/")
    #expect(
      path(.staging, allowsOverride: true)
        == "/home/Library/Caches/tech.lil.health/Servers/api.staging.lil.tech/LilSync/")
  }
  let third = Data(repeating: 3, count: 400)

  @Test
  func downloadsOnceThenReadsFromDisk() async throws {
    let server = FakeBlobs([first])
    let directory = temporaryDirectory()
    let cache = server.cache(in: directory)
    let sha256 = LilSyncEngine.sha256Hex(first)

    #expect(try await cache.data(for: sha256) == first)
    #expect(try await cache.data(for: sha256) == first)
    #expect(server.downloads.value == 1)
    // It's kept across launches.
    #expect(try await server.cache(in: directory).data(for: sha256) == first)
    #expect(server.downloads.value == 1)
  }

  @Test
  func concurrentRequestsShareADownload() async throws {
    let server = FakeBlobs([first], delay: .milliseconds(50))
    let cache = server.cache(in: temporaryDirectory())
    let sha256 = LilSyncEngine.sha256Hex(first)

    async let a = cache.data(for: sha256)
    async let b = cache.data(for: sha256)
    #expect(try await [a, b] == [first, first])
    #expect(server.downloads.value == 1)
  }

  @Test
  func evictsTheLeastRecentlyUsedPastItsLimit() async throws {
    let server = FakeBlobs([first, second, third])
    let directory = temporaryDirectory()
    // Room for two.
    let cache = server.cache(in: directory, maxBytes: 800)
    let (a, b, c) = (
      LilSyncEngine.sha256Hex(first), LilSyncEngine.sha256Hex(second),
      LilSyncEngine.sha256Hex(third)
    )

    _ = try await cache.data(for: a)
    _ = try await cache.data(for: b)
    // Using `a` again makes `b` the least recently used.
    try await Task.sleep(for: .milliseconds(20))
    _ = try await cache.data(for: a)
    try await Task.sleep(for: .milliseconds(20))
    _ = try await cache.data(for: c)

    let cached = try FileManager.default.contentsOfDirectory(atPath: directory.path())
    #expect(Set(cached) == [a, c])
    // An evicted blob downloads again when it's needed.
    #expect(try await cache.data(for: b) == second)
    #expect(server.downloads.value == 4)
  }

  @Test
  func anExpiredURLIsAskedForAgainOnce() async throws {
    let server = FakeBlobs([first])
    let cache = server.cache(in: temporaryDirectory())
    let sha256 = LilSyncEngine.sha256Hex(first)
    server.expiring.withValue {
      _ = $0.insert(
        URL(string: "https://api.lil.tech/v1/health/blob-downloads?token=\(sha256)-1")!)
    }

    #expect(try await cache.data(for: sha256) == first)
    #expect(server.urlRequests.value == 2)
  }

  @Test
  func signingOutRemovesEverything() async throws {
    let server = FakeBlobs([first])
    let directory = temporaryDirectory()
    let cache = server.cache(in: directory)
    _ = try await cache.data(for: LilSyncEngine.sha256Hex(first))

    await cache.removeAll()
    #expect(!FileManager.default.fileExists(atPath: directory.path()))
    // Asked for again, it's downloaded again.
    _ = try await cache.data(for: LilSyncEngine.sha256Hex(first))
    #expect(server.downloads.value == 2)
  }

  @Test
  func aFileDamagedOnDiskIsDownloadedAgain() async throws {
    let server = FakeBlobs([first])
    let directory = temporaryDirectory()
    let cache = server.cache(in: directory)
    let sha256 = LilSyncEngine.sha256Hex(first)
    _ = try await cache.data(for: sha256)
    try Data(repeating: 0, count: 10).write(to: directory.appending(path: sha256))

    #expect(try await cache.data(for: sha256) == first)
    #expect(server.downloads.value == 2)
  }

  @Test
  func aBlobWhoseFreshURLExpiresTooIsNotFound() async throws {
    let server = FakeBlobs([first])
    let cache = server.cache(in: temporaryDirectory())
    let sha256 = LilSyncEngine.sha256Hex(first)
    server.expiring.withValue {
      for request in 1...2 {
        _ = $0.insert(
          URL(string: "https://api.lil.tech/v1/health/blob-downloads?token=\(sha256)-\(request)")!)
      }
    }
    await #expect(throws: BlobCache.NotFound(sha256: sha256)) {
      try await cache.data(for: sha256)
    }
  }

  @Test
  func aCancelledRequestStopsWaiting() async throws {
    let server = FakeBlobs([first], delay: .seconds(60))
    let cache = server.cache(in: temporaryDirectory())
    let request = Task { try await cache.data(for: LilSyncEngine.sha256Hex(first)) }
    try await Task.sleep(for: .milliseconds(50))
    let start = ContinuousClock.now
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
    // Not after the minute the download would have taken.
    #expect(ContinuousClock.now - start < .seconds(10))
  }

  @Test
  func refusesMissingAndCorruptBlobs() async throws {
    let directory = temporaryDirectory()
    let missing = String(repeating: "0", count: 64)
    await #expect(throws: BlobCache.NotFound(sha256: missing)) {
      try await FakeBlobs([]).cache(in: directory).data(for: missing)
    }
    await #expect(throws: BlobCache.NotFound(sha256: "not-a-hash")) {
      try await FakeBlobs([]).cache(in: directory).data(for: "not-a-hash")
    }
    // Hex digits outside ASCII, which the server's form doesn't allow either.
    let fullwidth = String(repeating: "\u{FF10}", count: 64)
    await #expect(throws: BlobCache.NotFound(sha256: fullwidth)) {
      try await FakeBlobs([]).cache(in: directory).data(for: fullwidth)
    }
    // A server answering with other bytes: nothing is kept.
    let named = LilSyncEngine.sha256Hex(first)
    let corrupt = BlobCache(
      directory: directory, maxBytes: 1 << 20,
      url: { _ in URL(string: "https://api.lil.tech/v1/health/blob-downloads?token=x")! },
      download: SnapshotDownloader { _ in Data(repeating: 9, count: 10) })
    await #expect(throws: BlobCache.Corrupt(sha256: named)) {
      try await corrupt.data(for: named)
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: named).path()))
  }
}
