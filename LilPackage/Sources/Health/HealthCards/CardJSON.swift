public import Foundation

/// A JSON value, as card specs arrive (from agents, the editor, a pull) and are written. Objects
/// made in code keep their keys' order, so the canonical form's keys come in the design's order
/// (`docs/decisions/cards.md`, Versioning and the canonical form). Parsed ones come with their keys
/// sorted, since a decoder's keys have no order: an app that writes back a spec it can't read
/// keeps the text it pulled.
///
/// Two values are equal when they mean the same JSON: objects compare by their members, ignoring
/// key order, and numbers as doubles, as the store compares a spec with its canonical form.
public enum CardJSON: Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([CardJSON])
  case object([(key: String, value: CardJSON)])

  /// Parses JSON text. Throws `CardSpecValidationError` (`invalidJSON`) when it isn't JSON.
  public init(parsing data: Data) throws(CardSpecValidationError) {
    do {
      self = try JSONDecoder().decode(CardJSON.self, from: data)
    } catch {
      throw CardSpecValidationError([
        CardSpecError(path: "", code: .invalidJSON, message: "The spec isn't valid JSON.")
      ])
    }
  }

  /// The member named `key`, if this is an object that has it.
  public subscript(key: String) -> CardJSON? {
    guard case .object(let members) = self else { return nil }
    return members.first { $0.key == key }?.value
  }

  /// The text, compact (as `JSON.stringify` writes it, and as a spec's size is measured) or
  /// indented by two spaces, with keys in their order.
  public func text(pretty: Bool = false) -> String {
    var output = ""
    write(to: &output, indent: pretty ? "" : nil)
    return output
  }

  private func write(to output: inout String, indent: String?) {
    switch self {
    case .null: output += "null"
    case .bool(let value): output += value ? "true" : "false"
    case .number(let value): output += Self.text(of: value)
    case .string(let value): output += Self.quoted(value)
    case .array(let values):
      writeContainer(
        to: &output, indent: indent, open: "[", close: "]", count: values.count
      ) { output, index, inner in
        values[index].write(to: &output, indent: inner)
      }
    case .object(let members):
      writeContainer(
        to: &output, indent: indent, open: "{", close: "}", count: members.count
      ) { output, index, inner in
        output += Self.quoted(members[index].key)
        output += inner == nil ? ":" : ": "
        members[index].value.write(to: &output, indent: inner)
      }
    }
  }

  private func writeContainer(
    to output: inout String, indent: String?, open: String, close: String, count: Int,
    element: (inout String, Int, String?) -> Void
  ) {
    output += open
    guard count > 0 else {
      output += close
      return
    }
    let inner = indent.map { $0 + "  " }
    for index in 0..<count {
      if index > 0 { output += "," }
      if let inner { output += "\n" + inner }
      element(&output, index, inner)
    }
    if let indent { output += "\n" + indent }
    output += close
  }

  /// A number as JavaScript writes it (`Number.prototype.toString`): the shortest digits that
  /// read back the same, Swift's and JavaScript's alike, in decimal notation from 1e-6 up to 1e21
  /// (`10000`, `0.00001`) and in exponent notation outside it (`1e-7`, `1e+21`).
  static func text(of value: Double) -> String {
    guard value != 0 else { return "0" }
    guard value.isFinite else { return "null" }
    // Swift's shortest digits, and where the decimal point goes: `n` digits before it.
    let swift = abs(value).description
    let parts = swift.split(separator: "e")
    let mantissa = parts[0]
    let exponent = parts.count > 1 ? Int(parts[1])! : 0
    let point =
      mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) }
      ?? mantissa.count
    var digits = Array(mantissa.filter { $0 != "." })
    var n = point + exponent
    while digits.first == "0" {
      digits.removeFirst()
      n -= 1
    }
    while digits.last == "0" { digits.removeLast() }
    let k = digits.count
    let text: String
    if k <= n && n <= 21 {
      text = String(digits) + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
      text = String(digits[..<n]) + "." + String(digits[n...])
    } else if -6 < n && n <= 0 {
      text = "0." + String(repeating: "0", count: -n) + String(digits)
    } else {
      let e = n - 1
      let sign = e < 0 ? "-" : "+"
      text =
        (k == 1 ? String(digits) : "\(digits[0]).\(String(digits[1...]))") + "e\(sign)\(abs(e))"
    }
    return (value < 0 ? "-" : "") + text
  }

  /// A string as JSON, escaped as `JSON.stringify` escapes it.
  static func quoted(_ string: String) -> String {
    var output = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\u{8}": output += "\\b"
      case "\u{C}": output += "\\f"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case "\u{0}"..."\u{1F}":
        output += "\\u" + String(format: "%04x", scalar.value)
      default: output.unicodeScalars.append(scalar)
      }
    }
    return output + "\""
  }
}

extension CardJSON: Hashable {
  public static func == (lhs: CardJSON, rhs: CardJSON) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): true
    case (.bool(let a), .bool(let b)): a == b
    case (.number(let a), .number(let b)): a == b
    case (.string(let a), .string(let b)): a == b
    case (.array(let a), .array(let b)): a == b
    case (.object(let a), .object(let b)):
      a.count == b.count
        && a.allSatisfy { member in b.first { $0.key == member.key }?.value == member.value }
    default: false
    }
  }

  public func hash(into hasher: inout Hasher) {
    switch self {
    case .null: hasher.combine(0)
    case .bool(let value): hasher.combine(value)
    case .number(let value): hasher.combine(value)
    case .string(let value): hasher.combine(value)
    case .array(let values): hasher.combine(values)
    case .object(let members):
      // Order-independent, as equality is.
      hasher.combine(members.count)
      hasher.combine(Set(members.map(\.key)))
    }
  }
}

extension CardJSON: Codable {
  public init(from decoder: any Decoder) throws {
    if let container = try? decoder.container(keyedBy: MemberKey.self) {
      // A decoder's keys have no order: sorted, so parsing is deterministic.
      let keys = container.allKeys.sorted {
        $0.stringValue.utf16.lexicographicallyPrecedes($1.stringValue.utf16)
      }
      self = .object(
        try keys.map { ($0.stringValue, try container.decode(CardJSON.self, forKey: $0)) })
    } else if var container = try? decoder.unkeyedContainer() {
      var values: [CardJSON] = []
      while !container.isAtEnd {
        values.append(try container.decode(CardJSON.self))
      }
      self = .array(values)
    } else {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        self = .null
      } else if let value = try? container.decode(Bool.self) {
        self = .bool(value)
      } else if let value = try? container.decode(Double.self) {
        self = .number(value)
      } else {
        self = .string(try container.decode(String.self))
      }
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .object(let members):
      var container = encoder.container(keyedBy: MemberKey.self)
      for (key, value) in members {
        try container.encode(value, forKey: MemberKey(stringValue: key))
      }
    case .array(let values):
      var container = encoder.unkeyedContainer()
      for value in values { try container.encode(value) }
    case .null:
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    case .bool(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .number(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .string(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    }
  }

  private struct MemberKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }
}

extension CardJSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
  ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: CardJSON...) { self = .array(elements) }
  public typealias Key = String
  public typealias Value = CardJSON

  public init(dictionaryLiteral elements: (String, CardJSON)...) {
    self = .object(elements.map { (key: $0.0, value: $0.1) })
  }
}
