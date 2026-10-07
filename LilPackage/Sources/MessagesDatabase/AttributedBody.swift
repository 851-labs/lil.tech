public import Foundation

/// Extracts the plain text from a `message.attributedBody` blob.
///
/// Messages archives an `NSAttributedString` into `attributedBody` using the legacy `typedstream`
/// format (`NSArchiver`). Rather than unarchiving arbitrary objects with the deprecated, non-secure
/// `NSUnarchiver`, this reads just the string payload: the first `NSString` object, whose contents
/// follow a `+` (string) type marker as a length-prefixed UTF-8 byte sequence.
public enum AttributedBody {
  public static func text(from data: Data) -> String? {
    let bytes = [UInt8](data)
    guard
      let classNameEnd = bytes.endIndex(of: nsStringClassName),
      let stringMarker = bytes[classNameEnd..<min(classNameEnd + 8, bytes.endIndex)]
        .firstIndex(of: stringTypeMarker)
    else { return nil }

    var index = stringMarker + 1
    guard let length = readLength(bytes, at: &index), index + length <= bytes.endIndex
    else { return nil }
    return String(validating: bytes[index..<index + length], as: UTF8.self)
  }

  private static let nsStringClassName = Array("NSString".utf8)
  private static let stringTypeMarker = UInt8(ascii: "+")

  private static func readLength(_ bytes: [UInt8], at index: inout Int) -> Int? {
    guard index < bytes.endIndex else { return nil }
    let tag = bytes[index]
    index += 1
    switch tag {
    case 0x00..<0x80:
      return Int(tag)
    case 0x81:
      guard index + 2 <= bytes.endIndex else { return nil }
      defer { index += 2 }
      return Int(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
    case 0x82:
      guard index + 4 <= bytes.endIndex else { return nil }
      defer { index += 4 }
      return Int(
        UInt32(bytes[index])
          | UInt32(bytes[index + 1]) << 8
          | UInt32(bytes[index + 2]) << 16
          | UInt32(bytes[index + 3]) << 24
      )
    default:
      return nil
    }
  }
}

extension [UInt8] {
  fileprivate func endIndex(of pattern: [UInt8]) -> Int? {
    guard !pattern.isEmpty, count >= pattern.count else { return nil }
    for start in 0...(count - pattern.count)
    where self[start..<start + pattern.count].elementsEqual(pattern) {
      return start + pattern.count
    }
    return nil
  }
}
