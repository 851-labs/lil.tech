import Foundation
import HealthCards
import SwiftUI

/// The zone a record was recorded in (`HKTimeZone`, 851-4179, docs/decisions/health.md › Recorded
/// time zones), as a sample's and a workout's details show it in a Time Zone row, as Health does:
/// the zone's long name, standard or daylight as it was at the record's start ("Japan Standard
/// Time"). The record's times stay on the viewer's clock; the row adds its start on the zone's
/// clock when that reads differently.
struct RecordedTimeZone: Equatable {
  /// The zone's localized long name: "Japan Standard Time", "British Summer Time".
  var name: String
  /// The record's start on the zone's clock, when its offset then isn't the viewer's.
  var localStart: String?

  /// The zone named `name`, from a record starting at `start`, seen in `calendar`'s time zone and
  /// locale. `nil` without a name, or for one the tools' `timeZone` wouldn't take
  /// (`CardTimeZone.named`: `+09:00`, `asia/tokyo`), as the tools leave it out.
  init?(_ name: String?, start: Date, calendar: Calendar) {
    guard let name, let zone = CardTimeZone.named(name) else { return nil }
    let locale = calendar.locale ?? .current
    self.name = Self.longName(of: zone, named: name, at: start, locale: locale)
    if zone.secondsFromGMT(for: start) != calendar.timeZone.secondsFromGMT(for: start) {
      // The style of the details' Start row, on the zone's clock.
      localStart = start.formatted(
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: zone))
    }
  }

  /// The zone's long name at `date`. A name kept as the record wrote it: Foundation reads `UTC`
  /// as `GMT` ("Greenwich Mean Time"), so it's named as `Etc/UTC` is, "Coordinated Universal
  /// Time", as the tools keep `UTC` (851-4177). A zone Foundation has no name for reads as its
  /// offset ("GMT+09:00"), and failing that, its name.
  static func longName(of zone: TimeZone, named name: String, at date: Date, locale: Locale)
    -> String
  {
    let zone = name == "UTC" ? TimeZone(identifier: "Etc/UTC") ?? zone : zone
    let style: NSTimeZone.NameStyle =
      zone.isDaylightSavingTime(for: date) ? .daylightSaving : .standard
    return zone.localizedName(for: style, locale: locale) ?? name
  }
}

/// A Time Zone row: the zone's name, and the record's start on its clock below the title when
/// it differs from the viewer's.
struct RecordedTimeZoneRow: View {
  let zone: RecordedTimeZone

  var body: some View {
    LabeledContent {
      Text(zone.name)
    } label: {
      Text("Time Zone")
      if let localStart = zone.localStart {
        Text("Started \(localStart) local time")
      }
    }
  }
}
