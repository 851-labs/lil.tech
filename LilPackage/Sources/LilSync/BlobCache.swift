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
/// `maxBytes`, the least recently used go. Signing out must call ``removeAll()``: the blobs are
/// the account's health data.
public actor BlobCache {
  /// A signed download URL for a blob (`GET /v1/health/blobs/{sha256}`).
  public typealias URLForBlob = @Sendable (_ sha256: String) async throws -> URL

  /// The blob isn't on the server: the record referring to it was written without it, it was
  /// swept, or the account is gone.
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

  /// The server answered with a download URL that isn't one.
  public struct InvalidURL: Error, Equatable {
    public let url: String
  }

  private let directory: URL
  private let maxBytes: Int
  private let url: URLForBlob
  private let download: SnapshotDownloader
  /// Downloads in flight, so concurrent requests for the same blob share one, with how many
  /// requests are waiting for each: the last to be cancelled cancels the download.
  private var downloading: [String: (task: Task<Data, any Error>, waiting: Int)] = [:]
  /// The cache's size, once it's been measured.
  private var cachedBytes: Int?

  public init(
    directory: URL, maxBytes: Int, url: @escaping URLForBlob, download: SnapshotDownloader
  ) {
    self.directory = directory
    self.maxBytes = maxBytes
    self.url = url
    self.download = download
  }

  /// The blob's bytes: from disk if it's cached, otherwise downloaded and cached.
  public func data(for sha256: String) async throws -> Data {
    // Exactly the server's form, `[0-9a-f]{64}`, which is also a safe file name.
    guard sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw NotFound(sha256: sha256) }
    let file = directory.appending(path: sha256)
    if let data = try? Data(contentsOf: file) {
      if LilSyncEngine.sha256Hex(data) == sha256 {
        // Used now, for least-recently-used eviction.
        try? FileManager.default.setAttributes(
          [.modificationDate: Date()], ofItemAtPath: file.path(percentEncoded: false))
        return data
      }
      // Damaged on disk: downloaded again.
      try? FileManager.default.removeItem(at: file)
      cachedBytes = nil
    }
    let task =
      downloading[sha256]?.task
      ?? Task { [url, download] in
        try await Self.fetch(sha256, url: url, download: download)
      }
    downloading[sha256] = (task, (downloading[sha256]?.waiting ?? 0) + 1)
    let data = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      Task { await self.stopWaiting(for: sha256) }
    }
    if downloading[sha256]?.task == task {
      downloading[sha256] = nil
      try store(data, as: file)
    }
    return data
  }

  /// Removes every cached blob, e.g. when the account signs out.
  public func removeAll() {
    for (_, download) in downloading { download.task.cancel() }
    downloading = [:]
    try? FileManager.default.removeItem(at: directory)
    cachedBytes = 0
  }

  private func stopWaiting(for sha256: String) {
    guard var download = downloading[sha256] else { return }
    download.waiting -= 1
    if download.waiting > 0 {
      downloading[sha256] = download
    } else {
      download.task.cancel()
      downloading[sha256] = nil
    }
  }

  private static func fetch(
    _ sha256: String, url: URLForBlob, download: SnapshotDownloader
  ) async throws -> Data {
    var data: Data
    do {
      data = try await download.download(try await url(sha256))
    } catch is SnapshotDownloader.Expired {
      // A URL can expire before it's used (e.g. the Mac slept): one more, fresh. If that's
      // gone too, so is the blob.
      do {
        data = try await download.download(try await url(sha256))
      } catch is SnapshotDownloader.Expired {
        throw NotFound(sha256: sha256)
      }
    }
    guard LilSyncEngine.sha256Hex(data) == sha256 else { throw Corrupt(sha256: sha256) }
    return data
  }

  private func store(_ data: Data, as file: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
    if let bytes = cachedBytes { cachedBytes = bytes + data.count }
    evict(keeping: file.lastPathComponent)
  }

  /// Removes the least recently used blobs until the cache fits in `maxBytes`, never `keeping`.
  /// The directory is only listed when the cache may be over.
  private func evict(keeping: String) {
    if let bytes = cachedBytes, bytes <= maxBytes { return }
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
    cachedBytes = total
  }
}

extension BlobCache: DependencyKey {
  /// In the app's own caches folder (not shared, since the Mac app isn't sandboxed), up to
  /// 1 GB, through the API client.
  public static var liveValue: BlobCache {
    @Dependency(\.api) var api
    @Dependency(\.snapshotDownloader) var downloader
    return BlobCache(
      directory: URL.cachesDirectory.appending(
        path: "\(Bundle.main.bundleIdentifier ?? "lil")/LilSync/HealthBlobs"),
      maxBytes: 1 << 30,
      url: { sha256 in
        switch try await api.healthBlob(path: .init(sha256: sha256)) {
        case .ok(let ok):
          let string = try ok.body.json.url
          guard let url = URL(string: string) else { throw InvalidURL(url: string) }
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
