import CryptoKit
public import Dependencies
public import Foundation
import LilAPI

extension DependencyValues {
  /// Health blobs (ECG voltages, workout routes' locations), downloaded when a view needs them.
  public var blobCache: BlobCache {
    get { self[BlobCache.self] }
    set { self[BlobCache.self] = newValue }
  }
}

/// Synced records refer to health blobs by SHA-256 (`docs/SYNC.md`). The cache downloads one the
/// first time it's asked for, through a short-lived signed URL, and keeps it on disk. Past
/// `maxBytes`, the least recently used go.
public actor BlobCache {
  /// A signed download URL for a blob (`GET /v1/health/blobs/{sha256}`).
  public typealias URLForBlob = @Sendable (_ sha256: String) async throws -> URL

  /// The blob isn't on the server: the record referring to it was written without it, or the
  /// account is gone.
  public struct NotFound: Error, Equatable {
    public let sha256: String
  }

  /// The downloaded bytes don't hash to the blob's name.
  public struct Corrupt: Error, Equatable {
    public let sha256: String
  }

  public struct Failed: Error, Equatable {
    public let statusCode: Int
  }

  private let directory: URL
  private let maxBytes: Int
  private let url: URLForBlob
  private let download: SnapshotDownloader
  /// Downloads in flight, so concurrent requests for the same blob share one.
  private var downloading: [String: Task<Data, any Error>] = [:]

  public init(
    directory: URL, maxBytes: Int, url: @escaping URLForBlob,
    download: SnapshotDownloader
  ) {
    self.directory = directory
    self.maxBytes = maxBytes
    self.url = url
    self.download = download
  }

  /// The blob's bytes: from disk if it's cached, otherwise downloaded and cached.
  public func data(for sha256: String) async throws -> Data {
    guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit), sha256 == sha256.lowercased()
    else { throw NotFound(sha256: sha256) }
    let file = directory.appending(path: sha256)
    if let data = try? Data(contentsOf: file) {
      // Used now, for least-recently-used eviction.
      try? FileManager.default.setAttributes(
        [.modificationDate: Date()], ofItemAtPath: file.path(percentEncoded: false))
      return data
    }
    if let running = downloading[sha256] { return try await running.value }
    let task = Task { try await fetch(sha256, to: file) }
    downloading[sha256] = task
    defer { downloading[sha256] = nil }
    return try await task.value
  }

  private func fetch(_ sha256: String, to file: URL) async throws -> Data {
    var data: Data
    do {
      data = try await download.download(try await url(sha256))
    } catch is SnapshotDownloader.Expired {
      // A URL can expire before it's used (e.g. the Mac slept): one more, fresh.
      data = try await download.download(try await url(sha256))
    }
    guard Self.sha256(data) == sha256 else { throw Corrupt(sha256: sha256) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
    evict(keeping: sha256)
    return data
  }

  /// Removes the least recently used blobs until the cache fits in `maxBytes`, never `keeping`.
  private func evict(keeping: String) {
    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys))
    else { return }
    var entries = files.compactMap { file -> (url: URL, size: Int, used: Date)? in
      guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
      return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
    }
    var total = entries.reduce(0) { $0 + $1.size }
    entries.sort { $0.used < $1.used }
    for entry in entries where total > maxBytes && entry.url.lastPathComponent != keeping {
      try? FileManager.default.removeItem(at: entry.url)
      total -= entry.size
    }
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension BlobCache: DependencyKey {
  /// In the app's caches directory, up to 1 GB, through the API client.
  public static var liveValue: BlobCache {
    @Dependency(\.api) var api
    @Dependency(\.snapshotDownloader) var downloader
    return BlobCache(
      directory: URL.cachesDirectory.appending(path: "HealthBlobs"), maxBytes: 1 << 30,
      url: { sha256 in
        switch try await api.healthBlob(path: .init(sha256: sha256)) {
        case .ok(let ok):
          guard let url = URL(string: try ok.body.json.url) else { throw Failed(statusCode: 200) }
          return url
        case .notFound: throw NotFound(sha256: sha256)
        case .unauthorized: throw Failed(statusCode: 401)
        case .tooManyRequests: throw Failed(statusCode: 429)
        case .serviceUnavailable: throw Failed(statusCode: 503)
        case .undocumented(let statusCode, _): throw Failed(statusCode: statusCode)
        }
      }, download: downloader)
  }

  public static var testValue: BlobCache {
    BlobCache(
      directory: URL.temporaryDirectory.appending(path: "BlobCache-\(UUID().uuidString)"),
      maxBytes: 1 << 20,
      url: { sha256 in
        reportIssue("Unimplemented: @Dependency(\\.blobCache) for \(sha256)")
        throw NotFound(sha256: sha256)
      }, download: .testValue)
  }
}
