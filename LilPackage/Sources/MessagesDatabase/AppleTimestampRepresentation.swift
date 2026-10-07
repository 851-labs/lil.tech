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
