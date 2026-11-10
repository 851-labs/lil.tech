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

  /// The tools, at the context's time and in its time zone, reading blobs through the app.
  func tools() -> HealthTools {
    HealthTools(now: now(), defaultTimeZone: timeZone) { [self] sha256 in
      try HealthCLI.blob(sha256, context: self)
    }
  }
}

/// A route's points couldn't be had: the app didn't keep them where this tool reads.
struct BlobUnavailable: LocalizedError {
  var errorDescription: String? {
    "lil health downloaded the route's points, but they aren't where lil-health reads them. "
      + "Try again in a moment."
  }
}

extension HealthCLI {
  /// A blob, from the app's cache, or else asked of the app, which downloads it there.
  static func blob(_ sha256: String, context: Context) throws -> Data {
    if let data = cachedBlob(sha256, in: context.blobDirectory) { return data }
    _ = try askApp(.downloadBlob(sha256: sha256), context: context)
    guard let data = cachedBlob(sha256, in: context.blobDirectory) else {
      throw BlobUnavailable()
    }
    return data
  }

  /// The blob in the cache, if it's there and whole: its bytes hash to its name.
  static func cachedBlob(_ sha256: String, in directory: URL?) -> Data? {
    // Exactly the server's form, `[0-9a-f]{64}`, which is also a safe file name.
    guard let directory, sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let data = try? Data(contentsOf: directory.appending(path: sha256)),
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256
    else { return nil }
    return data
  }
}
