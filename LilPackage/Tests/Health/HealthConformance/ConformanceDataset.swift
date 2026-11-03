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
public struct ConformanceBatch: @unchecked Sendable {
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
    for case let batch as [String: Any] in object?["batches"] as? [Any] ?? [] {
      batches.append(
        ConformanceBatch(
          device: batch["device"] as? String ?? "",
          receivedAt: try Date(batch["receivedAt"] as? String ?? "", strategy: .iso8601),
          lines: batch["lines"] as? [[String: Any]] ?? []))
    }
    return batches
  }
}
