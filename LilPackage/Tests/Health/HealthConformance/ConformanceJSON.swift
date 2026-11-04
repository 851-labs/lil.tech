/// A JSON value, to compare outputs as the server's conformance harnesses do.
public enum ConformanceJSON: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([ConformanceJSON])
  case object([String: ConformanceJSON])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([ConformanceJSON].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: ConformanceJSON].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let values): try container.encode(values)
    case .object(let values): try container.encode(values)
    }
  }

  /// Whether `self` matches `expected` as the server's harnesses have it: the same JSON, with
  /// numbers within a relative 1e-9, since sums may be added in another order.
  public func matches(_ expected: ConformanceJSON) -> Bool {
    switch (self, expected) {
    case (.number(let actual), .number(let expected)):
      return abs(actual - expected) <= 1e-9 * max(1, abs(expected))
    case (.array(let actual), .array(let expected)):
      return actual.count == expected.count
        && zip(actual, expected).allSatisfy { $0.matches($1) }
    case (.object(let actual), .object(let expected)):
      return actual.count == expected.count
        && expected.allSatisfy { key, value in actual[key]?.matches(value) == true }
    default:
      return self == expected
    }
  }
}
