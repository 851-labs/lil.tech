import CryptoKit
import Foundation
import HealthAgentAccess
import HealthTools
import LilAPI
import LilSync

// Routes' points for the route tools (851-4164). They're blobs the app downloads when a page
// needs them, into its cache (`BlobCache`), which `lil-health` reads: it has no session of its own,
// and reads only what the app has synced. A blob that isn't cached is asked of the app, as a
// card write is (`HealthCLI.askApp`), which downloads it into the cache as its pages do.

extension HealthCLI.Context {
  #if canImport(AppKit)
    /// The app's blob cache: the folder `BlobCache.liveValue` keeps, named after the app's bundle
    /// ID, since this tool has none, and its server's own in a Debug build (`LIL_API_URL`).
    static var liveBlobDirectory: URL? {
      LilSyncEngine.cachesDirectory(
        for: .current(), bundleIdentifier: HealthCLI.AppConnection.bundleIdentifier
      )
      .appending(path: "HealthBlobs", directoryHint: .isDirectory)
    }
  #else
    static var liveBlobDirectory: URL? { nil }
  #endif

  /// The tools, at the context's time and in its time zone, reading blobs from the app's cache
  /// only: one that isn't there is `BlobMissing`, which `HealthCLI.withBlobs` asks the app for.
  func tools() -> HealthTools {
    HealthTools(now: now(), defaultTimeZone: timeZone) { [blobDirectory] sha256 in
      guard let data = HealthCLI.cachedBlob(sha256, in: blobDirectory) else {
        throw BlobMissing(sha256: sha256)
      }
      return data
    }
  }
}

/// A blob the app's cache doesn't have: `HealthCLI.withBlobs` asks the app for it.
struct BlobMissing: Error {
  var sha256: String
}

/// A route's points couldn't be had: the app didn't keep them where this tool reads.
struct BlobUnavailable: LocalizedError {
  var errorDescription: String? {
    "lil health downloaded the route's points, but they aren't where lil-health reads them. "
      + "Try again in a moment."
  }
}

extension HealthCLI {
  /// Runs `query`, and if it needs a blob the cache doesn't have, asks the app to download it,
  /// then runs it once more. The app is asked between the two, outside any read of the
  /// database, so a download, seconds at most, doesn't keep a read open.
  static func withBlobs<T>(context: Context, _ query: () throws -> T) throws -> T {
    do {
      return try query()
    } catch let missing as BlobMissing {
      _ = try askApp(.downloadBlob(sha256: missing.sha256), context: context)
      do { return try query() } catch is BlobMissing { throw BlobUnavailable() }
    }
  }

  /// `withBlobs` for the MCP server, which waits for the app off Swift's own threads.
  static func withBlobs<T>(context: Context, _ query: () async throws -> T) async throws -> T {
    do {
      return try await query()
    } catch let missing as BlobMissing {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        DispatchQueue.global().async {
          continuation.resume(
            with: Result { _ = try askApp(.downloadBlob(sha256: missing.sha256), context: context) }
          )
        }
      }
      do { return try await query() } catch is BlobMissing { throw BlobUnavailable() }
    }
  }

  /// The blob in the cache, if it's there and whole: its bytes hash to its name. Marked used, as
  /// the app's cache marks what it reads, so it isn't the next to go when the cache is full.
  static func cachedBlob(_ sha256: String, in directory: URL?) -> Data? {
    // Exactly the server's form, `[0-9a-f]{64}`, which is also a safe file name.
    guard let directory, sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    let file = directory.appending(path: sha256)
    guard let data = try? Data(contentsOf: file),
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256
    else { return nil }
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: file.path(percentEncoded: false))
    return data
  }
}
