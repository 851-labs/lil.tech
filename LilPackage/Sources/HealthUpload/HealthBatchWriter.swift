public import Foundation
import GzipFiles

/// Collects mutations into gzip NDJSON batch files (`docs/SYNC.md`). Files are cut by
/// uncompressed size: at most 4 MB, well under the server's 16 MB compressed and 64 MB
/// decompressed limits whatever the data (DEFLATE barely expands anything), and small enough for
/// the iPhone's memory limits in the background.
public struct HealthBatchWriter {
  public static let maxFileBytes = 4 * 1024 * 1024
  /// The server rejects longer lines.
  public static let maxLineBytes = 1024 * 1024

  public struct LineTooLong: Error, Equatable {
    public let entity: String
    public let id: String
  }

  public let maxFileBytes: Int
  private var lines = Data()
  private var count = 0
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  public init(maxFileBytes: Int = Self.maxFileBytes) {
    self.maxFileBytes = maxFileBytes
    lines.reserveCapacity(maxFileBytes)
  }

  /// Mutations waiting for the next file.
  public var pendingCount: Int { count }

  /// Adds a mutation. Returns a finished file when this one wouldn't fit in the current file.
  public mutating func append(_ mutation: HealthMutation) throws -> Data? {
    let line = try encoder.encode(mutation)
    guard line.count <= Self.maxLineBytes else {
      throw LineTooLong(entity: mutation.entity, id: mutation.id)
    }
    var finished: Data?
    if count > 0, lines.count + 1 + line.count > maxFileBytes {
      finished = try finish()
    }
    if count > 0 { lines.append(0x0a) }
    lines.append(line)
    count += 1
    return finished
  }

  /// The current file, gzip-compressed, or `nil` if it's empty. Starts a new file. If
  /// compressing fails, the mutations stay for the next try.
  public mutating func finish() throws -> Data? {
    guard count > 0 else { return nil }
    let file = try Gzip.compress(lines)
    lines.removeAll(keepingCapacity: true)
    count = 0
    return file
  }
}
