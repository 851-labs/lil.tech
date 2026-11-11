public import Foundation

// The conformance datasets (851-2841, 851-3198), shared with the server's harnesses: a synthetic
// account in upload form, each iPhone's batches. The Mac syncs them into a database with its sync
// engine (`HealthCLITests`' `Conformance.sync`); the iPhone (851-3201) writes them into HealthKit
// (`ConformanceSamples`). Foundation only: the iPhone's HealthKit test host builds this file and
// `ConformanceSamples.swift` by reference (`PhoneHealthKit.xcodeproj`).

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

  /// The batches of the dataset at `url`, those of the one it `extends` (relative to it) first,
  /// each record under one key (`checkRecordKeys`).
  public static func read(_ url: URL) throws -> [ConformanceBatch] {
    let batches = try readBatches(url)
    try checkRecordKeys(batches.flatMap(\.lines))
    return batches
  }

  static func readBatches(_ url: URL) throws -> [ConformanceBatch] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    var batches: [ConformanceBatch] = []
    if let base = object?["extends"] as? String {
      batches = try readBatches(
        url.deletingLastPathComponent().appending(path: base).standardized)
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

  /// The entities stored by key fields as well as ID, and their fields, as the server's
  /// `Entity.key` has them (`Services/api/src/health/HealthEntities.ts`, which
  /// `HealthConformance.test.ts` pins).
  static let keyFields = ["health_sample": ["type", "startDate"]]

  /// Throws if one of `lines` sends a record under other key fields' values than an earlier line
  /// with its ID (851-4181), as the server's harnesses do (`checkRecordKeys`). A record's key
  /// fields never change: the server would keep a second record, and the Mac, keyed by ID,
  /// replaces the first, so the two sides' answers would differ.
  public static func checkRecordKeys(_ lines: [[String: Any]]) throws {
    var keys: [String: String] = [:]
    for line in lines {
      guard let entity = line["entity"] as? String, let fields = keyFields[entity],
        line["op"] as? String == "upsert", let id = line["id"] as? String
      else { continue }
      let row = line["row"] as? [String: Any] ?? [:]
      // As JSON, as the server compares them: a missing field is null, and `1` isn't `"1"`.
      let key = String(
        decoding: try JSONSerialization.data(
          withJSONObject: fields.map { row[$0] ?? NSNull() }, options: [.sortedKeys]),
        as: UTF8.self)
      if let earlier = keys["\(entity) \(id)"], earlier != key {
        throw ConformanceError(
          "\(entity) \(id) is sent under two keys, \(earlier) and \(key): give it another ID")
      }
      keys["\(entity) \(id)"] = key
    }
  }
}

public struct ConformanceError: Error, CustomStringConvertible {
  public var description: String
  init(_ description: String) { self.description = description }
}
