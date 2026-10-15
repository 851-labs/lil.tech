public import Foundation

/// Reads and writes single-member gzip files, the format of snapshot parts and health batches
/// (`docs/SYNC.md`). Foundation's `.zlib` algorithm is raw DEFLATE, so the gzip header and trailer
/// are handled here.
public enum Gzip {
  public struct InvalidData: Error, Equatable {
    public let reason: String
  }

  /// Decompresses `data`, checking the size in its trailer. Its CRC isn't checked: parts are
  /// checked with SHA-256 when they're downloaded.
  public static func decompress(_ data: Data) throws -> Data {
    let start = data.startIndex
    guard data.count >= 18, data[start] == 0x1f, data[start + 1] == 0x8b, data[start + 2] == 8
    else { throw InvalidData(reason: "Not a gzip file") }
    let flags = data[start + 3]
    var offset = start + 10
    if flags & 0x04 != 0 {  // FEXTRA
      guard offset + 2 <= data.endIndex else { throw InvalidData(reason: "Truncated header") }
      offset += 2 + Int(data[offset]) + Int(data[offset + 1]) << 8
    }
    for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT
      while offset < data.endIndex, data[offset] != 0 { offset += 1 }
      offset += 1
    }
    if flags & 0x02 != 0 { offset += 2 }  // FHCRC
    let trailer = data.endIndex - 8
    guard offset <= trailer else { throw InvalidData(reason: "Truncated file") }

    let inflated = try (data[offset..<trailer] as NSData).decompressed(using: .zlib) as Data
    let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[trailer + 4 + $1]) << (8 * $1) }
    guard size == UInt32(truncatingIfNeeded: inflated.count) else {
      throw InvalidData(reason: "Size mismatch")
    }
    return inflated
  }

  public static func compress(_ data: Data) throws -> Data {
    var output = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
    output.append(try (data as NSData).compressed(using: .zlib) as Data)
    for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
      output.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
    return output
  }

  private static let crcTable: [UInt32] = (0..<256).map { index in
    (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xedb8_8320 ^ (crc >> 1) : crc >> 1 }
  }

  static func crc32(_ data: Data) -> UInt32 {
    ~data.reduce(~UInt32(0)) { crc, byte in
      crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
    }
  }
}
