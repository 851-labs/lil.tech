import Foundation

/// Reads (and, for tests, writes) single-member gzip files, the format of snapshot parts
/// (`docs/SYNC.md`). Foundation's `.zlib` algorithm is raw DEFLATE, so the gzip header and trailer
/// are handled here.
enum Gzip {
  struct InvalidData: Error, Equatable {
    let reason: String
  }

  static func decompress(_ data: Data) throws -> Data {
    let bytes = [UInt8](data)
    guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
      throw InvalidData(reason: "Not a gzip file")
    }
    let flags = bytes[3]
    var offset = 10
    if flags & 0x04 != 0 {  // FEXTRA
      guard offset + 2 <= bytes.count else { throw InvalidData(reason: "Truncated header") }
      offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
    }
    for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT
      while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
      offset += 1
    }
    if flags & 0x02 != 0 { offset += 2 }  // FHCRC
    guard offset <= bytes.count - 8 else { throw InvalidData(reason: "Truncated file") }

    let deflated = Data(bytes[offset..<(bytes.count - 8)])
    let inflated = try (deflated as NSData).decompressed(using: .zlib) as Data
    let trailer = Array(bytes[(bytes.count - 8)...])
    let crc = trailer[0..<4].enumerated().reduce(UInt32(0)) {
      $0 | UInt32($1.element) << (8 * $1.offset)
    }
    let size = trailer[4..<8].enumerated().reduce(UInt32(0)) {
      $0 | UInt32($1.element) << (8 * $1.offset)
    }
    guard crc == crc32(inflated), size == UInt32(truncatingIfNeeded: inflated.count) else {
      throw InvalidData(reason: "Checksum mismatch")
    }
    return inflated
  }

  static func compress(_ data: Data) throws -> Data {
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
