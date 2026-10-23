/// Summary's order of cards: fractional indexing, David Greenspan's "Implementing Fractional
/// Indexing" as the `fractional-indexing` package (3.4) implements it, with its base-62 digits
/// (docs/decisions/cards.md, The `health_card` sync entity › Order).
///
/// A position is a string ordered by its bytes, and there's always one between two others, so a
/// move writes the moved card alone. The server runs the same algorithm, checked by the shared
/// cases in `validation-cases.json`.
public enum CardPosition {
  /// The base-62 digits, in byte order.
  static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
  static let zero = digits[0]

  /// The longest position the store keeps.
  public static let maxLength = 200

  public struct InvalidPosition: Error, Hashable, Sendable {
    public let message: String
  }

  /// A position between `a` and `b`, either of which may be `nil` for the start or the end:
  /// `between(nil, nil)` is `a0`, the first card's; `between(last, nil)` the end. `a` and `b` are
  /// swapped if they're in the wrong order, as the package does. Throws if either isn't a valid
  /// position, or they're equal.
  public static func between(_ a: String?, _ b: String?) throws(InvalidPosition) -> String {
    var a = a.map { Array($0.utf8) }
    var b = b.map { Array($0.utf8) }
    for key in [a, b].compactMap(\.self) {
      // The package doesn't check digits, and would compute with an unknown one as -1.
      guard key.allSatisfy(digits.contains) else { throw fail("invalid order key: \(text(key))") }
      try validate(key)
    }
    if let lower = a, let upper = b, lower.lexicographicallyPrecedes(upper) == false,
      lower != upper
    {
      (a, b) = (upper, lower)
    }
    return String(decoding: try keyBetween(a, b), as: UTF8.self)
  }

  /// `count` positions between `a` and `b`, ascending, as `generateNKeysBetween` makes them. `a`
  /// and `b` are swapped if they're in the wrong order, so the positions always ascend.
  public static func between(
    _ a: String?, _ b: String?, count: Int
  ) throws(InvalidPosition) -> [String] {
    if let lower = a, let upper = b, upper < lower {
      return try between(upper, lower, count: count)
    }
    if count <= 0 { return [] }
    if count == 1 { return [try between(a, b)] }
    if b == nil {
      var key = try between(a, b)
      var keys = [key]
      for _ in 1..<count {
        key = try between(key, b)
        keys.append(key)
      }
      return keys
    }
    if a == nil {
      var key = try between(a, b)
      var keys = [key]
      for _ in 1..<count {
        key = try between(a, key)
        keys.append(key)
      }
      return keys.reversed()
    }
    let middle = count / 2
    let key = try between(a, b)
    return try between(a, key, count: middle) + [key]
      + between(key, b, count: count - middle - 1)
  }

  /// Why a stored position is wrong, or `nil` when it's fine: 1 to 200 characters, base-62 digits,
  /// and a key the algorithm can place others around.
  public static func error(_ position: String) -> CardSpecError? {
    let bytes = Array(position.utf8)
    guard (1...maxLength).contains(position.unicodeScalars.count) else {
      return CardSpecError(
        path: "position", code: .positionLength, message: "position must be 1 to 200 characters.")
    }
    do {
      guard bytes.allSatisfy(digits.contains) else {
        throw InvalidPosition(message: "")
      }
      try validate(bytes)
      return nil
    } catch {
      return CardSpecError(
        path: "position", code: .invalidPosition,
        message: "position \(CardJSON.quoted(position)) isn't a fractional index: base-62 digits, "
          + "starting with a letter that gives the length of its integer part.")
    }
  }

  // MARK: - The algorithm

  private static func fail(_ message: String) -> InvalidPosition {
    InvalidPosition(message: message)
  }

  private static func index(_ digit: UInt8) -> Int {
    digits.firstIndex(of: digit) ?? 0
  }

  private static func keyBetween(_ a: [UInt8]?, _ b: [UInt8]?) throws(InvalidPosition) -> [UInt8] {
    guard let a else {
      guard let b else { return Array("a".utf8) + [zero] }
      let ib = try integerPart(b)
      let fb = Array(b[ib.count...])
      if ib == smallestInteger {
        return ib + (try midpoint([], fb))
      }
      if ib.count < b.count { return ib }
      guard let result = try decrementInteger(ib) else { throw fail("cannot decrement any more") }
      return result
    }
    guard let b else {
      let ia = try integerPart(a)
      let fa = Array(a[ia.count...])
      guard let next = try incrementInteger(ia) else { return ia + (try midpoint(fa, nil)) }
      return next
    }
    let ia = try integerPart(a)
    let fa = Array(a[ia.count...])
    let ib = try integerPart(b)
    let fb = Array(b[ib.count...])
    if ia == ib { return ia + (try midpoint(fa, fb)) }
    guard let next = try incrementInteger(ia) else { throw fail("cannot increment any more") }
    if next.lexicographicallyPrecedes(b) { return next }
    return ia + (try midpoint(fa, nil))
  }

  private static func midpoint(_ a: [UInt8], _ b: [UInt8]?) throws(InvalidPosition) -> [UInt8] {
    if let b, !a.lexicographicallyPrecedes(b) { throw fail("\(text(a)) >= \(text(b))") }
    if a.last == zero || (b?.last == zero) { throw fail("trailing zero") }
    if let b, !b.isEmpty {
      var n = 0
      while n < b.count, (n < a.count ? a[n] : zero) == b[n] { n += 1 }
      if n > 0 {
        return Array(b[..<n]) + (try midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n))))
      }
    }
    let digitA = a.first.map(index) ?? 0
    let digitB = b.map { $0.first.map(index) ?? 0 } ?? digits.count
    if digitB - digitA > 1 {
      // JavaScript's Math.round(0.5 * (digitA + digitB)), which rounds halves up.
      return [digits[(digitA + digitB + 1) / 2]]
    }
    if let b, b.count > 1 { return [b[0]] }
    return [digits[digitA]] + (try midpoint(Array(a.dropFirst()), nil))
  }

  private static func integerLength(_ head: UInt8) throws(InvalidPosition) -> Int {
    switch head {
    case UInt8(ascii: "a")...UInt8(ascii: "z"): Int(head - UInt8(ascii: "a")) + 2
    case UInt8(ascii: "A")...UInt8(ascii: "Z"): Int(UInt8(ascii: "Z") - head) + 2
    default: throw fail("invalid order key head")
    }
  }

  private static func integerPart(_ key: [UInt8]) throws(InvalidPosition) -> [UInt8] {
    guard let head = key.first else { throw fail("invalid order key") }
    let length = try integerLength(head)
    guard length <= key.count else { throw fail("invalid order key: \(text(key))") }
    return Array(key[..<length])
  }

  private static let smallestInteger = Array("A".utf8) + Array(repeating: zero, count: 26)

  private static func validate(_ key: [UInt8]) throws(InvalidPosition) {
    if key == smallestInteger { throw fail("invalid order key: \(text(key))") }
    let integer = try integerPart(key)
    if key.count > integer.count, key.last == zero {
      throw fail("invalid order key: \(text(key))")
    }
  }

  private static func validateInteger(_ integer: [UInt8]) throws(InvalidPosition) {
    guard let head = integer.first, integer.count == (try integerLength(head)) else {
      throw fail("invalid integer part of order key: \(text(integer))")
    }
  }

  private static func incrementInteger(_ x: [UInt8]) throws(InvalidPosition) -> [UInt8]? {
    try validateInteger(x)
    let head = x[0]
    var trailing: [UInt8] = []
    for i in stride(from: x.count - 1, through: 1, by: -1) {
      let d = index(x[i]) + 1
      if d == digits.count {
        trailing.insert(zero, at: 0)
      } else {
        return [head] + x[1..<i] + [digits[d]] + trailing
      }
    }
    if head == UInt8(ascii: "Z") { return Array("a".utf8) + [zero] }
    if head == UInt8(ascii: "z") { return nil }
    let h = head + 1
    return [h] + (h > UInt8(ascii: "a") ? trailing + [zero] : Array(trailing.dropFirst()))
  }

  private static func decrementInteger(_ x: [UInt8]) throws(InvalidPosition) -> [UInt8]? {
    try validateInteger(x)
    let head = x[0]
    let last = digits[digits.count - 1]
    var trailing: [UInt8] = []
    for i in stride(from: x.count - 1, through: 1, by: -1) {
      let d = index(x[i]) - 1
      if d == -1 {
        trailing.insert(last, at: 0)
      } else {
        return [head] + x[1..<i] + [digits[d]] + trailing
      }
    }
    if head == UInt8(ascii: "a") { return Array("Z".utf8) + [last] }
    if head == UInt8(ascii: "A") { return nil }
    let h = head - 1
    return [h] + (h < UInt8(ascii: "Z") ? trailing + [last] : Array(trailing.dropFirst()))
  }

  private static func text(_ bytes: [UInt8]) -> String {
    String(decoding: bytes, as: UTF8.self)
  }
}
