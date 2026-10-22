public import Foundation
public import SQLiteData

extension Date {
  /// A query representation of the timestamps stored in `chat.db`.
  ///
  /// Messages stores dates as an integer offset from 2001-01-01 (the Apple reference date). Current
  /// versions of macOS use nanoseconds, older versions used seconds.
  public struct AppleTimestampRepresentation: QueryRepresentable {
    public var queryOutput: Date

    public init(queryOutput: Date) {
      self.queryOutput = queryOutput
    }

    public init(rawValue: Int64) {
      let seconds =
        Swift.abs(rawValue) >= Self.nanosecondsThreshold
        ? Double(rawValue) / 1_000_000_000
        : Double(rawValue)
      self.init(queryOutput: Date(timeIntervalSinceReferenceDate: seconds))
    }

    public var rawValue: Int64 {
      Int64((queryOutput.timeIntervalSinceReferenceDate * 1_000_000_000).rounded())
    }

    private static let nanosecondsThreshold: Int64 = 100_000_000_000
  }
}

extension Date.AppleTimestampRepresentation: QueryBindable {
  public var queryBinding: QueryBinding {
    .int(rawValue)
  }
}

extension Date.AppleTimestampRepresentation: QueryDecodable {
  public init(decoder: inout some QueryDecoder) throws {
    try self.init(rawValue: Int64(decoder: &decoder))
  }
}

extension Date.AppleTimestampRepresentation: SQLiteType {
  public static var typeAffinity: SQLiteTypeAffinity {
    Int64.typeAffinity
  }
}

extension Date {
  /// A query representation of optional `chat.db` timestamps, such as `date_read`, which Messages
  /// stores as 0 when unset.
  public struct OptionalAppleTimestampRepresentation: QueryRepresentable {
    public var queryOutput: Date?

    public init(queryOutput: Date?) {
      self.queryOutput = queryOutput
    }
  }
}

extension Date.OptionalAppleTimestampRepresentation: QueryBindable {
  public var queryBinding: QueryBinding {
    queryOutput.map { Date.AppleTimestampRepresentation(queryOutput: $0).queryBinding } ?? .int(0)
  }
}

extension Date.OptionalAppleTimestampRepresentation: QueryDecodable {
  public init(decoder: inout some QueryDecoder) throws {
    let rawValue = try decoder.decode(Int64.self) ?? 0
    self.init(
      queryOutput: rawValue == 0
        ? nil : Date.AppleTimestampRepresentation(rawValue: rawValue).queryOutput
    )
  }
}

extension Date.OptionalAppleTimestampRepresentation: SQLiteType {
  public static var typeAffinity: SQLiteTypeAffinity {
    Int64.typeAffinity
  }
}
