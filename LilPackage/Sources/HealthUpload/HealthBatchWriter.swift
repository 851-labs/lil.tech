import CryptoKit
public import Foundation
import GzipFiles

/// Collects mutations into gzip NDJSON batch files (`docs/SYNC.md`). Files are cut by
/// uncompressed size: at most 15 MB, under the server's 16 MB compressed and 64 MB decompressed
/// limits whatever the data (DEFLATE expands incompressible data by well under 1%). They can also
/// be cut by count (`maxRecords`), so a page makes a couple of files that upload at once.
///
/// A record's source revision and device, which nearly all of a user's samples share, go once per
/// file as a `health_provenance` record, and the record refers to it by `provenance` (851-2674).
public struct HealthBatchWriter {
  /// The entities whose records have a source revision and device.
  static let provenanceEntities: Set<String> = [
    "health_sample", "health_correlation", "health_workout", "health_state_of_mind",
    "health_scored_assessment", "health_audiogram", "health_electrocardiogram",
    "health_heartbeat_series", "health_workout_route",
  ]

  public static let maxFileBytes = 15 * 1024 * 1024
  /// The server rejects longer lines.
  public static let maxLineBytes = 1024 * 1024

  public struct LineTooLong: Error, Equatable {
    public let entity: String
    public let id: String
  }

  public let maxFileBytes: Int
  /// Mutations per file at most.
  public let maxRecords: Int
  private var lines = Data()
  private var count = 0
  /// The `health_provenance` records in the current file.
  private var provenances: Set<String> = []
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  public init(maxFileBytes: Int = Self.maxFileBytes, maxRecords: Int = .max) {
    self.maxFileBytes = maxFileBytes
    self.maxRecords = maxRecords
    // Most files are far smaller than the limit (characteristics, a chunk of sums).
    lines.reserveCapacity(min(maxFileBytes, 1024 * 1024))
  }

  /// Mutations waiting for the next file.
  public var pendingCount: Int { count }

  /// Adds a mutation. Returns a finished file when this one wouldn't fit in the current file, or
  /// it already holds `maxRecords`. A `health_provenance` record it refers to doesn't count
  /// towards `maxRecords`.
  public mutating func append(_ mutation: HealthMutation) throws -> Data? {
    let (mutation, provenance) = try Self.separatingProvenance(mutation)
    let line = try encoded(mutation)
    var provenanceLine = try provenance.map(encoded)
    if count >= maxRecords
      || (count > 0 && lines.count + 2 + (provenanceLine?.count ?? 0) + line.count > maxFileBytes)
    {
      return try finish(adding: line, provenance: provenance, provenanceLine)
    }
    if let id = provenance?.id, provenances.contains(id) { provenanceLine = nil }
    write(provenanceLine, provenance, line)
    return nil
  }

  private mutating func finish(
    adding line: Data, provenance: HealthMutation?, _ provenanceLine: Data?
  ) throws -> Data? {
    let finished = try finish()
    write(provenanceLine, provenance, line)
    return finished
  }

  private mutating func write(_ provenanceLine: Data?, _ provenance: HealthMutation?, _ line: Data)
  {
    if let provenanceLine, let provenance {
      if !lines.isEmpty { lines.append(0x0a) }
      lines.append(provenanceLine)
      provenances.insert(provenance.id)
    }
    if !lines.isEmpty { lines.append(0x0a) }
    lines.append(line)
    count += 1
  }

  private func encoded(_ mutation: HealthMutation) throws -> Data {
    let line = try encoder.encode(mutation)
    guard line.count <= Self.maxLineBytes else {
      throw LineTooLong(entity: mutation.entity, id: mutation.id)
    }
    return line
  }

  /// An upsert with its source revision and device replaced by a reference to the
  /// `health_provenance` record holding them, and that record. Its ID is a hash of the two, so
  /// the same pair is always the same record.
  static func separatingProvenance(
    _ mutation: HealthMutation
  ) throws -> (HealthMutation, provenance: HealthMutation?) {
    guard mutation.op == .upsert, provenanceEntities.contains(mutation.entity),
      var row = mutation.row
    else { return (mutation, nil) }
    let pair: [String: JSONValue] = [
      "sourceRevision": row["sourceRevision"] ?? .null, "device": row["device"] ?? .null,
    ]
    let digest = SHA256.hash(data: try provenanceEncoder.encode(pair))
    let id = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    // Null rather than missing, since an upsert keeps the fields it doesn't set.
    row["sourceRevision"] = .null
    row["device"] = .null
    row["provenance"] = .string(id)
    var separated = mutation
    separated.row = row
    return (separated, .upsert("health_provenance", id: id, row: pair))
  }

  private static let provenanceEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// The current file, gzip-compressed, or `nil` if it's empty. Starts a new file. If
  /// compressing fails, the mutations stay for the next try.
  public mutating func finish() throws -> Data? {
    guard count > 0 else { return nil }
    let file = try Gzip.compress(lines)
    lines.removeAll(keepingCapacity: true)
    count = 0
    provenances.removeAll()
    return file
  }
}
