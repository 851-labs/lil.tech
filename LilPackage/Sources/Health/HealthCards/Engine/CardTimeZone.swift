public import Foundation

/// Time zone names: the tools' `timeZone` and the zone a record was recorded in
/// (`HKMetadataKeyTimeZone`, kept as `HKTimeZone`), one check for both (851-4174,
/// docs/decisions/health.md › Recorded time zones). The server checks names against the same list
/// (`time-zones.json`, generated from `names`, in `ToolTime.ts`), so the two take the same names
/// (851-4184, 851-4185).
public enum CardTimeZone {
  /// The zone named `name`, when it's one of `names`, exactly, and Foundation knows it. `nil` for
  /// anything else, though `TimeZone(identifier:)` takes some of it: an abbreviation (`PST`,
  /// `BST`), a UTC offset (`+09:00`), `GMT+9`, or ICU's old IDs (`AET`, `SystemV/AST4`).
  public static func named(_ name: String) -> TimeZone? {
    guard names.contains(name) else { return nil }
    return TimeZone(identifier: name)
  }

  /// The name `name` should have, when it's one of `names` in another case (`europe/kyiv` for
  /// `Europe/Kyiv`), for the tools' error. `nil` for a name in its proper case, or none of them.
  public static func properName(of name: String) -> String? {
    guard let properName = namesByLowercase[name.lowercased()], properName != name else {
      return nil
    }
    return properName
  }

  private static let namesByLowercase = Dictionary(
    uniqueKeysWithValues: names.map { ($0.lowercased(), $0) })
}
