import Foundation
import HealthCards
import HealthCatalog
import HealthDatabase

/// A record's recorded times (851-4177, docs/decisions/health.md › Recorded time zones): every
/// time a tool gives is in the call's `timeZone`, so times compare across records, and a record
/// with a zone (`HKTimeZone`, a name `CardTimeZone.named` takes) adds that zone's name and the
/// same instants on its clock, as the server's tools do (`RecordedTimes.ts`). Each is `nil`
/// without a zone.
struct RecordedTimes: Equatable {
  var timeZone: String?
  var start: String?
  var end: String?
}

/// A record of one time's recorded zone and that time on its clock, `nil` without a zone.
struct RecordedTime: Equatable {
  var timeZone: String?
  var time: String?
}

/// The zones records were recorded in, each name looked up once a call: a page's records share a
/// few names. A class, so a call's closures share it.
final class RecordedZones {
  private var clocks: [String: ToolTime?] = [:]

  /// The clock of the zone named `name`, if it's one the tools' `timeZone` takes.
  func clock(_ name: String) -> ToolTime? {
    if let clock = clocks[name] { return clock }
    let clock = CardTimeZone.named(name).map { ToolTime(zone: $0, name: name) }
    clocks[name] = clock
    return clock
  }

  /// The zone named `name`, as is, with `start` and `end` on its clock; empty if it isn't one.
  func named(_ name: String?, start: Date, end: Date) -> RecordedTimes {
    guard let name, let clock = clock(name) else { return RecordedTimes() }
    return RecordedTimes(
      timeZone: name, start: clock.localTime(start), end: clock.localTime(end))
  }

  /// The zone named `name`, as is, with `start` and `end` (Unix milliseconds) on its clock.
  func named(_ name: String?, start: Int, end: Int) -> RecordedTimes {
    named(name, start: Date(unixMilliseconds: start), end: Date(unixMilliseconds: end))
  }

  /// The recorded times of a record from `start` to `end` (Unix milliseconds) whose metadata is
  /// `metadata`: its `HKTimeZone`, read as `HealthMetadataValues` reads text.
  func times(_ metadata: [String: Any]?, start: Int, end: Int) -> RecordedTimes {
    named(Self.zoneName(metadata), start: start, end: end)
  }

  /// The recorded times of a record whose metadata is the JSON `metadata`; metadata that isn't
  /// JSON loses only the zone, as on the server (`recordedZoneSql`).
  func times(json metadata: String?, start: Int, end: Int) -> RecordedTimes {
    times(SampleDetails.object(metadata), start: start, end: end)
  }

  /// The recorded time of a record at `time` (Unix milliseconds) whose metadata is the JSON
  /// `metadata`.
  func time(json metadata: String?, at time: Int) -> RecordedTime {
    guard let name = Self.zoneName(SampleDetails.object(metadata)), let clock = clock(name)
    else { return RecordedTime() }
    return RecordedTime(timeZone: name, time: clock.localTime(Date(unixMilliseconds: time)))
  }

  /// A record's `HKTimeZone`, if it's text.
  static func zoneName(_ metadata: [String: Any]?) -> String? {
    HealthMetadataValues.value(.timeZone, in: metadata)?.string
  }
}
