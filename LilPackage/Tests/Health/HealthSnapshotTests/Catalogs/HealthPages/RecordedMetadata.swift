import Foundation

/// A record's JSON `metadata`, recorded in the zone named `zone` (`HKTimeZone`, 851-4179), with
/// the rest of it kept: for catalog states of records from another zone.
func metadata(_ metadata: String?, recordedIn zone: String) -> String {
  var object =
    metadata.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    ?? [:]
  object["HKTimeZone"] = zone
  return String(
    decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
    as: UTF8.self)
}
