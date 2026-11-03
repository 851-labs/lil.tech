public import Foundation

// The conformance datasets (851-2841, 851-3198), shared with the server's harnesses: a synthetic
// account in upload form, each iPhone's batches. The Mac syncs them into a database with its sync
// engine (`HealthCLITests`' `Conformance.sync`); the iPhone (851-3201) writes them into HealthKit.

public enum ConformanceFiles {
  /// The API's tests, where the conformance files are.
  static let tests = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "../../../../Services/api/test/health")
    .standardized

  /// The Health tools' (`tools/conformance`).
  public static let tools = tests.appending(path: "tools/conformance")
  /// The cards' (`cards/conformance`).
  public static let cards = tests.appending(path: "cards/conformance")
}

/// One iPhone's upload, as the server received it.
public struct ConformanceBatch {
  /// The iPhone's device ID.
  public var device: String
  /// When the server received it.
  public var receivedAt: Date
  /// Its lines: `entity`, `op`, `id` and `row`, as JSON objects.
  public var lines: [[String: Any]]

  /// The batches of the dataset at `url`, those of the one it `extends` (relative to it) first.
  public static func read(_ url: URL) throws -> [ConformanceBatch] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    var batches: [ConformanceBatch] = []
    if let base = object?["extends"] as? String {
      batches = try read(url.deletingLastPathComponent().appending(path: base).standardized)
    }
    guard let list = object?["batches"] as? [Any] else {
      throw ConformanceError("\(url.lastPathComponent) has no batches")
    }
    for item in list {
      // A malformed batch or line is an error, rather than data the Mac quietly skips.
      guard let batch = item as? [String: Any], let device = batch["device"] as? String,
        let receivedAt = batch["receivedAt"] as? String,
        let lines = batch["lines"] as? [[String: Any]]
      else { throw ConformanceError("\(url.lastPathComponent): a malformed batch") }
      batches.append(
        ConformanceBatch(
          device: device, receivedAt: try Date(receivedAt, strategy: .iso8601), lines: lines))
    }
    return batches
  }
}
