public import Foundation

/// Time zone names: the tools' `timeZone` and the zone a record was recorded in
/// (`HKMetadataKeyTimeZone`, kept as `HKTimeZone`), one check for both (851-4174,
/// docs/decisions/health.md › Recorded time zones). The server checks names the same way
/// (`ToolTime.ts`).
public enum CardTimeZone {
  /// The zone named `name`: an IANA name in its proper case, which Foundation knows, its old
  /// aliases included (`Asia/Calcutta`, `Europe/Kiev`, `US/Pacific`), as Apple writes
  /// `TimeZone.current.identifier`. `nil` for anything else, though `TimeZone(identifier:)` takes
  /// some of it: a UTC offset (`+09:00`), `GMT+9`, or a name in the wrong case.
  public static func named(_ name: String) -> TimeZone? {
    guard isIANAName(name), let zone = TimeZone(identifier: name) else { return nil }
    return zone
  }

  /// An IANA name's shape: not a UTC offset such as `+01:00`, nor `GMT+0100`, which `TimeZone`
  /// also accepts. The same pattern as the server's.
  static func isIANAName(_ name: String) -> Bool {
    name.wholeMatch(of: /[A-Za-z][A-Za-z0-9_+-]*(?:\/[A-Za-z0-9_+-]+)*/) != nil
      && !name.hasPrefix("GMT+") && !name.hasPrefix("GMT-")
  }
}
