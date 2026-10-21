import Foundation

/// One line of a health batch file: a mutation of a health entity, in the push format
/// (`docs/SYNC.md`). Upserts carry whole records.
public struct HealthMutation: Encodable, Equatable, Sendable {
  public enum Operation: String, Encodable, Sendable {
    case upsert, delete
  }

  public var entity: String
  public var op: Operation
  public var id: String
  public var row: [String: JSONValue]?

  public static func upsert(_ entity: String, id: String, row: [String: JSONValue]) -> Self {
    Self(entity: entity, op: .upsert, id: id, row: row)
  }

  public static func delete(_ entity: String, id: String) -> Self {
    Self(entity: entity, op: .delete, id: id, row: nil)
  }
}

/// A JSON value.
public enum JSONValue: Encodable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value):
      // JSON has no NaN or infinity.
      if !value.isFinite {
        try container.encodeNil()
      } else if value.rounded() == value, abs(value) < 9e15 {
        // Whole numbers as integers, so millisecond times don't become `1.76e12`.
        try container.encode(Int64(value))
      } else {
        try container.encode(value)
      }
    case .string(let value): try container.encode(value)
    case .array(let values): try container.encode(values)
    case .object(let members): try container.encode(members)
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(nilLiteral: ()) { self = .null }

  public init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
  public init(_ value: Double?) { self = value.map(JSONValue.number) ?? .null }
  public init(_ value: Int?) { self = value.map { .number(Double($0)) } ?? .null }
  public init(_ value: Bool?) { self = value.map(JSONValue.bool) ?? .null }
}
