import CryptoKit
public import Foundation
import LilGzip

/// Collects mutations into gzip NDJSON batch files (`docs/SYNC.md`). Files are cut by
/// uncompressed size: at most 15 MB, under the server's 16 MB compressed and 64 MB decompressed
/// limits whatever the data (DEFLATE expands incompressible data by well under 1%). They can also
/// be cut by count (`maxRecords`), so a page makes a couple of files that upload at once.
///
/// A record's source revision and device, which nearly all of a user's samples share, go once per
/// file as a `health_provenance` record, and the record refers to it by `provenance` (851-2674).
public struct HealthBatchWriter {
  /// The entities whose records have a source revision and device (`HealthEncoder.provenance(of:)`).
  static let provenanceEntities: Set<String> = [
    HealthEncoder.sampleEntity, HealthEncoder.correlationEntity, HealthEncoder.workoutEntity,
    HealthEncoder.stateOfMindEntity, HealthEncoder.scoredAssessmentEntity,
    HealthEncoder.audiogramEntity, HealthEncoder.electrocardiogramEntity,
    HealthEncoder.heartbeatSeriesEntity, HealthEncoder.workoutRouteEntity,
    HealthEncoder.visionPrescriptionEntity, HealthEncoder.medicationDoseEntity,
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
  /// The last source revision and device separated, with its record's ID and line: consecutive
  /// records nearly always share them.
  private var lastProvenance: (pair: [String: JSONValue], provenance: Provenance)?
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// A `health_provenance` record: its ID and its line.
  struct Provenance {
    let id: String
    let line: Data
  }

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
    let (separated, provenance) = try separatingProvenance(mutation)
    let line = try Self.encoded(separated, as: mutation)
    // The provenance record goes in only if the file doesn't have it yet.
    var provenanceLine = provenance.flatMap { provenances.contains($0.id) ? nil : $0.line }
    var finished: Data?
    let size = lines.count + (provenanceLine.map { $0.count + 1 } ?? 0) + 1 + line.count
    if count >= maxRecords || (count > 0 && size > maxFileBytes) {
      finished = try finish()
      provenanceLine = provenance?.line
    }
    if let provenance, let provenanceLine {
      write(provenanceLine)
      provenances.insert(provenance.id)
    }
    write(line)
    count += 1
    return finished
  }

  private mutating func write(_ line: Data) {
    if !lines.isEmpty { lines.append(0x0a) }
    lines.append(line)
  }

  /// `mutation` as a line, too long if it's over the server's limit. `original` is the mutation
  /// it came from, named in the error.
  private static func encoded(_ mutation: HealthMutation, as original: HealthMutation) throws
    -> Data
  {
    let line = try encoder.encode(mutation)
    guard line.count <= maxLineBytes else {
      throw LineTooLong(entity: original.entity, id: original.id)
    }
    return line
  }

  /// An upsert with its source revision and device replaced by a reference to the
  /// `health_provenance` record holding them, and that record. Its ID is a hash of the two, so
  /// the same pair is always the same record. A record that sets neither is left as it is,
  /// since an upsert keeps the fields it doesn't set.
  private mutating func separatingProvenance(
    _ mutation: HealthMutation
  ) throws -> (HealthMutation, Provenance?) {
    guard mutation.op == .upsert, Self.provenanceEntities.contains(mutation.entity),
      var row = mutation.row, row["sourceRevision"] != nil || row["device"] != nil
    else { return (mutation, nil) }
    let pair: [String: JSONValue] = [
      "sourceRevision": row["sourceRevision"] ?? .null, "device": row["device"] ?? .null,
    ]
    let provenance: Provenance
    if let last = lastProvenance, last.pair == pair {
      provenance = last.provenance
    } else {
      let digest = SHA256.hash(data: try Self.encoder.encode(pair))
      let id = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
      let record = HealthMutation.upsert("health_provenance", id: id, row: pair)
      provenance = Provenance(id: id, line: try Self.encoded(record, as: mutation))
      lastProvenance = (pair, provenance)
    }
    // Null rather than missing, since an upsert keeps the fields it doesn't set.
    row["sourceRevision"] = .null
    row["device"] = .null
    row["provenance"] = .string(provenance.id)
    var separated = mutation
    separated.row = row
    return (separated, provenance)
  }

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
